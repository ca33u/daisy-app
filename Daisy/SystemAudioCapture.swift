//
//  SystemAudioCapture.swift
//  Daisy
//
//  Loopback capture of system audio (the "other side" of the meeting)
//  via ScreenCaptureKit. We exclude our own process so we don't loop
//  Daisy back onto itself.
//

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreAudio
import CoreMedia
import os

/// Intentionally NOT @Observable — UI does not bind to this class directly,
/// and the @Observable macro's auto-applied @ObservationTracked conflicts
/// with the `nonisolated` storage we need for the audio render callback.
@MainActor
final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    enum CaptureState: Equatable {
        case idle
        case starting
        case capturing
        /// Stream torn down but bufferContinuation is preserved so
        /// upstream consumers (Transcriber) keep their for-await
        /// loops alive across pause/resume.
        case paused
        case stopped
    }

    private(set) var state: CaptureState = .idle
    private(set) var lastError: String?

    /// Peak amplitude of the most recent system-audio buffer, in dB
    /// (where 0 dB == full scale, -160 dB == silence). Updated from
    /// the SCStream output queue at ~10 Hz (rate-limited so we don't
    /// pound MainActor every 20 ms). Surfaces in the widget so the
    /// user can see, mid-meeting, whether system audio capture is
    /// actually receiving the remote side. -160 dB persistently
    /// while `state == .capturing` means trouble (BT output, no
    /// permission to capture the foreground app, etc.).
    private(set) var peakLevelDB: Float = -160

    /// Wall-clock time the last audio sample buffer arrived from
    /// SCStream. nil between sessions or before the FIRST sample
    /// has ever arrived. Used by `checkForSilentCapture()` to fire
    /// a "we're getting no audio" warning toast when the stream is
    /// nominally `.capturing` but no buffers are flowing — the
    /// classic ScreenCaptureKit-on-Bluetooth-output failure mode.
    private(set) var lastSampleAt: Date?

    /// True after the FIRST sample buffer of this session has been
    /// processed. Drives the difference between
    ///   "capture started, no audio yet — give it 30 s"
    /// and
    ///   "capture has been delivering audio, then went silent".
    /// Reset to false on each `start()` from idle/stopped (not on
    /// resume — running totals carry across pause/resume).
    private(set) var hasReceivedAudio: Bool = false

    /// Wall-clock time the last AUDIBLE buffer (peak above
    /// `audibleFloorDB`) arrived. Distinct from `lastSampleAt`: buffers
    /// can flow at full cadence while every sample is silence/zero —
    /// the signature of DRM-protected playback or the macOS Tahoe
    /// all-zero-buffer capture glitch. nil until the first audible buffer.
    private(set) var lastAudibleSampleAt: Date?

    /// Latches `true` the first time an audible buffer is seen this
    /// session. If it stays `false` for a whole session while buffers
    /// ARE arriving, the remote side isn't really being captured (silent
    /// content) — surfaced both as a live warning and an honest archive
    /// status (`.empty`, not `.captured`, even though silence writes
    /// non-zero bytes). Reset on fresh start (not resume).
    private(set) var receivedAudibleAudio: Bool = false

    /// One-shot latch for the silent-CONTENT warning, separate from
    /// `silenceWarningFired` (the no-buffers-at-all warning).
    private var silentContentWarningFired: Bool = false

    /// Settings-meter mode: suppress every toast/notification this class
    /// emits (silence monitor, route-change info, restart-failure
    /// warnings) — the diagnostics UI reads the published state itself
    /// and renders verdicts inline. Set per `start()`.
    private var quietDiagnostics: Bool = false

    /// Called once when the restart budget is spent and the stream is
    /// declared dead for the rest of the capture.
    ///
    /// This class already TELLS the user (toast + notification, below);
    /// what it can't do is make the fact outlive the session, because it
    /// knows nothing about sessions, transcripts or frontmatter. The
    /// owner hooks this to record the mic-only degradation, so a meeting
    /// that captured the other side for ten minutes and then lost it
    /// doesn't read, a week later, exactly like one that worked.
    ///
    /// Not gated on `quietDiagnostics`: the Settings meter runs its own
    /// instance and never installs a handler.
    var onCaptureGaveUp: (@MainActor () -> Void)?

    /// Wall-clock time `start()` flipped state to `.capturing`,
    /// used to compute the "never received any audio" timeout.
    private var captureStartedAt: Date?

    /// Latches `true` the first time `checkForSilentCapture()` fires
    /// its warning toast, so users see the message once per session
    /// instead of every 5 s. Reset on `start()`.
    private var silenceWarningFired: Bool = false

    /// True once the silence monitor has decided the system stream isn't
    /// delivering usable audio — either NO buffers at all (path 1) or
    /// buffers that are all-silence (path 2). Drives `systemAudioStatus`
    /// so the UI (status banner + widget core) can surface "the other side
    /// isn't being recorded" instead of a falsely-reassuring "capturing".
    var isSilentCaptureDetected: Bool {
        silenceWarningFired || silentContentWarningFired
    }

    /// MainActor timer that polls `lastSampleAt` while `state ==
    /// .capturing`. Cheap (5 s cadence, no audio touched). Killed
    /// in `pause()`/`stop()`.
    private var silenceMonitorTimer: Timer?

    /// CoreAudio property-listener block for the default-output-
    /// device change. Held so we can remove it on stop()/pause()
    /// without retain-cycling. SCStream itself has no notion of
    /// "output device changed" — when the user plugs in AirPods or
    /// flips Sound output in Control Centre mid-meeting, the
    /// already-bound SCStream goes silent without notice. This
    /// listener lets us tear it down + restart against the new
    /// default output so audio keeps flowing.
    private var outputDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    /// True after the property listener has been successfully
    /// installed. Drives idempotency in install/remove pairs.
    private var outputDeviceListenerInstalled: Bool = false

    /// Latches `true` while a route-change-induced restart is in
    /// progress. `handleOutputDeviceChange` is `@MainActor`-isolated
    /// (whole class is) so this property is only ever read/written
    /// from MainActor — pre-1.0.3 had a misleading
    /// `nonisolated(unsafe)` annotation.
    ///
    /// Paired with `lastRestartAt` for a 2 s cooldown: CoreAudio
    /// fires the property listener multiple times for a single
    /// user-perceived change (sleep/wake re-emits hours later, mode
    /// switches re-emit ~200ms apart). The bool alone leaks the
    /// race window between the `defer { …InFlight = false }` and
    /// the next listener invocation.
    private var outputRestartInFlight: Bool = false
    private var lastOutputRestartAt: Date?

    /// Auto-restarts spent on `didStopWithError` recovery during THIS
    /// capture. Bounded by `maxAutoRestarts` so a stream that macOS
    /// keeps killing (revoked permission, disconnected display) ends in
    /// one honest message instead of a restart storm. Deliberately NOT
    /// refunded when a rebuilt stream starts delivering: a flapping
    /// source (delivers a buffer, dies, repeats) would then restart
    /// forever. A recording is bounded, and 3 recoveries inside one is
    /// already the generous reading.
    private var autoRestartCount: Int = 0
    private static let maxAutoRestarts = 3

    /// Bumped by every capture-lifetime edge (start / pause / stop).
    /// `rebuildStream` snapshots it before its awaits and drops the
    /// freshly built stream if the generation moved meanwhile —
    /// otherwise a rebuild racing Stop resumes AFTER teardown, assigns
    /// `self.stream`, and leaks a live capture that nobody holds: the
    /// screen-recording indicator stays lit and its buffers land in the
    /// NEXT recording's continuation and `.caf`.
    private var captureGeneration: Int = 0

    /// Rate-limit gate for SCStream → MainActor UI updates. The
    /// audio output queue can fire ~50 callbacks/sec at 48 kHz
    /// with typical CMSampleBuffer sizes; we only need ~10 Hz to
    /// drive a level meter. Stored as a raw Double seconds-since-
    /// reference-date because nonisolated(unsafe) Date access is
    /// awkward and Double atomic-ish reads are fine for a gate.
    nonisolated(unsafe) private var lastUIUpdateRefTime: Double = 0

    /// Fire the silent-capture warning after this many seconds of
    /// `.capturing` state with no buffers received. 30 s is a
    /// compromise — short enough that users learn quickly,
    /// long enough not to fire on transient stream-startup delays.
    private static let silentCaptureTimeoutSec: TimeInterval = 30

    /// Peak-dB floor above which a buffer counts as "audible". Clean
    /// speech peaks well above this; digital silence / all-zero buffers
    /// sit at -160. -55 dB cleanly separates real remote audio from
    /// silence without tripping on quiet passages.
    private static let audibleFloorDB: Float = -55

    /// Fire the silent-CONTENT warning after this many seconds of
    /// `.capturing` with buffers arriving but NONE ever audible. Longer
    /// than `silentCaptureTimeoutSec` because a real meeting can open
    /// with the remote side quiet for a bit; 120 s of buffers-but-no-
    /// sound is the DRM / Tahoe-glitch signature, not a quiet room.
    private static let silentContentTimeoutSec: TimeInterval = 120

    private var stream: SCStream?
    /// nonisolated(unsafe) so the audio render callback can yield without
    /// hopping to main. AsyncStream.Continuation.yield is documented as
    /// thread-safe.
    nonisolated(unsafe) private var bufferContinuation: AsyncStream<AudioChunk>.Continuation?

    /// File URL to archive the captured system audio into. Set in
    /// `start(archiveURL:)`; the audio render callback lazily opens
    /// an `AVAudioFile` on the FIRST sample so the writer's format
    /// matches what SCStream actually delivers (we don't have to
    /// hand-roll a settings dict that might disagree). nil disables
    /// archiving — transcription path still works either way.
    ///
    /// `nonisolated(unsafe)` because the audio callback writes from
    /// the `outputQueue`, not main. **All MainActor-side mutations**
    /// (start/stop/pause and the output-device-change recovery)
    /// **MUST go through `outputQueue.sync { ... }`** to fence behind
    /// any in-flight sample-buffer callback. Pre-1.0.3 the MainActor
    /// did `archiveWriter = nil` directly after `stopCapture()`, and
    /// in-flight callbacks could still call `archiveWriter?.write(...)`
    /// → race against the nil write, occasional torn ExtAudioFile
    /// state, very-occasional truncated tail of system_audio.caf.
    nonisolated(unsafe) private var archiveURL: URL?
    nonisolated(unsafe) private var archiveWriter: AVAudioFile?

    // 2026-05-25 — counters for the silent-write-death detector
    // surfaced in the Billions test: SCKit was delivering buffers
    // (hasReceivedAudio=true, transcriber got 44 min of audio) but
    // the on-disk system_audio.caf landed as 0 bytes. Two failure
    // modes the existing log-only path missed:
    //   • AVAudioFile open succeeded but write threw on EVERY frame
    //   • Open succeeded, first write succeeded, later writes threw
    //     (route change / device reset / disk pressure) and we only
    //     emitted a log.error per frame — no surfaced counter
    // These counters give RecordingSession.stop() an authoritative
    // "did anything actually persist?" answer so frontmatter status
    // and the post-stop toast can tell truth, not just hasReceivedAudio.
    // All access happens on `outputQueue` (single-threaded) so the
    // nonisolated(unsafe) attribution matches archiveURL/Writer.
    nonisolated(unsafe) private var archiveFramesWritten: UInt64 = 0
    nonisolated(unsafe) private var archiveWriteErrorCount: Int = 0
    nonisolated(unsafe) private var firstArchiveWriteError: String?

    private let outputQueue = DispatchQueue(
        label: "app.essazanov.Daisy.SystemAudioOutput",
        qos: .userInitiated
    )
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "SystemAudio")

    /// PCM stream of system audio. Read this **before** `start()`.
    ///
    /// Both the assignment and the `onTermination` nil-out happen
    /// inside `outputQueue.sync` so the in-flight `sampleBufferCallback`
    /// (which reads `bufferContinuation` via `bufferContinuation?.yield`)
    /// never observes a half-mutated state. The other
    /// `nonisolated(unsafe)` fields (`archiveWriter`, `archiveURL`)
    /// already serialize through the same queue — this one was an
    /// oversight that the macOS audit caught (build 40 fix).
    var buffers: AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            self.outputQueue.sync {
                self.bufferContinuation = continuation
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.outputQueue.sync {
                    self?.bufferContinuation = nil
                }
            }
        }
    }

    /// `quietDiagnostics: true` — the Settings live meter. No silence-
    /// monitor toasts, no BT/speakers nudges: at meter cadence "nothing
    /// audible for 30 s" just means nothing is playing, and the settings
    /// UI already shows the Bluetooth caveat inline. The caller reads
    /// `peakLevelDB` / `hasReceivedAudio` / `receivedAudibleAudio` itself.
    func start(archiveURL: URL? = nil, quietDiagnostics: Bool = false) async throws {
        guard state == .idle || state == .stopped || state == .paused else { return }
        // Distinguish a fresh start from a resume: on resume
        // (state == .paused) we KEEP the already-open archive writer +
        // running counters so the recording stays one contiguous file
        // across pause/resume; on a fresh start we adopt the new
        // archiveURL and zero everything. (No zero-byte placeholder file
        // is created any more — see the note where it used to be, below.)
        let isFreshStart = (state == .idle || state == .stopped)
        // Only adopt a new archive URL on a fresh start. Resume
        // (state == .paused) keeps the writer that was opened
        // during the original start, so the file accumulates one
        // contiguous recording across pause/resume cycles instead
        // of clobbering itself.
        if isFreshStart {
            self.archiveURL = archiveURL
            self.archiveWriter = nil
            // Reset level-meter and silence-monitor state on fresh
            // start. Resume keeps them so a brief pause/resume cycle
            // doesn't re-trigger the silent-capture warning.
            peakLevelDB = -160
            lastSampleAt = nil
            hasReceivedAudio = false
            autoRestartCount = 0
            silenceWarningFired = false
            lastAudibleSampleAt = nil
            receivedAudibleAudio = false
            silentContentWarningFired = false
            // Truncation-detector counters — fresh start zeros them.
            // Resume keeps them so a mid-session pause/resume doesn't
            // erase the evidence of an earlier write failure cluster.
            outputQueue.sync {
                archiveFramesWritten = 0
                archiveWriteErrorCount = 0
                firstArchiveWriteError = nil
            }
        }
        state = .starting
        lastError = nil
        self.quietDiagnostics = quietDiagnostics
        captureGeneration &+= 1

        let newStream: SCStream
        do {
            newStream = try await buildAndStartSystemAudioStream()
        } catch {
            state = .idle
            lastError = error.localizedDescription
            throw error
        }

        self.stream = newStream
        state = .capturing
        captureStartedAt = Date()
        if !quietDiagnostics {
            startSilenceMonitor()
        }
        installOutputDeviceListener()

        // NO eager placeholder file. (Removed 2026-05-31 — root cause of
        // the recurring 0-byte system_audio.caf.) We used to stamp a
        // zero-byte file here via `FileManager.createFile` so "armed but
        // received nothing" was diagnosable from the artifact. But that
        // placeholder was the bug: on a fresh start it created an inode
        // that the first-buffer `AVAudioFile(forWriting:)` then opened
        // over, and writes streamed into a descriptor whose directory
        // entry stayed at 0 bytes — millions of frames "written", 0 write
        // errors, 0 bytes on disk (audit 2026-05-31: 562M frames / 0 B,
        // and the earlier build-37 case). The WORKING microphone path
        // (AudioRecorder) creates no placeholder — it just opens the
        // AVAudioFile and writes. We now match it: the lazy-open in
        // `stream(_:didOutputSampleBuffer:_:)` creates the file fresh on
        // the first delivered buffer. "Armed but nothing landed" stays
        // fully diagnosable without a husk file — `hasReceivedAudio`,
        // `archiveFramesWritten` and the on-disk byte count drive
        // `RecordingSession.systemAudioArchiveStatus` (.empty / .truncated).

        // Bluetooth output detection — known to break SCStream's
        // audio loopback on multiple macOS Tahoe builds. SCK binds
        // to the default output, but the BT stack lives outside the
        // CoreAudio loopback path, so SCStream reports `.capturing`
        // and delivers zero buffers. Surface a heads-up at session
        // start so the user can switch outputs BEFORE the meeting,
        // not discover the silent failure post-meeting.
        //
        // The silence-monitor toast (`checkForSilentCapture`) is
        // the safety net for cases where output changes mid-session
        // or this initial BT check misses (e.g. transport type
        // reported as "unknown" for some BT devices).
        if quietDiagnostics {
            // Settings meter — the diagnostics UI shows route caveats
            // inline; toasts here would nag on every section visit.
        } else if Self.currentOutputDeviceIsBluetooth() {
            log.warning("Default output is Bluetooth — SCStream loopback may not deliver frames")
            ToastCenter.shared.show(
                String(localized: "Bluetooth headphones detected — Daisy may not capture the remote side. Use built-in speakers, wired headphones, or install BlackHole for reliable system-audio capture."),
                style: .warning
            )
        } else if Self.currentOutputDeviceIsInternalSpeakers() {
            // Internal speakers → the mic acoustically re-captures the
            // remote side. Echo dedup scrubs the duplicate lines, but
            // speaker attribution is fundamentally unreliable in this
            // setup (product call 2026-07-25: don't out-smart physics —
            // recommend a headset instead). Nudge at most once per day
            // so a deliberate speakers user isn't nagged every meeting.
            let nudgeKey = "daisy.speakersNudgeLastShown"
            let lastShown = UserDefaults.standard.object(forKey: nudgeKey) as? Date
            if lastShown == nil || !Calendar.current.isDateInToday(lastShown!) {
                UserDefaults.standard.set(Date(), forKey: nudgeKey)
                log.info("Default output is internal speakers — showing headphones nudge")
                ToastCenter.shared.show(
                    String(localized: "Playing through the Mac's speakers — your mic will also hear the other side. Headphones keep the two sides cleanly separated."),
                    style: .info
                )
            }
        }

        log.info("SystemAudio capturing")
    }

    /// Query CoreAudio for the default output device's transport
    /// type and return `true` if it's any flavour of Bluetooth.
    /// Used at `start()` time to surface the BT loopback caveat
    /// before the meeting begins. Returns `false` on any property
    /// query error — never block the start path on a diagnostic.
    nonisolated private static func currentOutputDeviceIsBluetooth() -> Bool {
        // 1. Resolve default output device ID.
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultOutAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let idStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutAddress,
            0, nil,
            &size, &deviceID
        )
        guard idStatus == noErr, deviceID != kAudioObjectUnknown else { return false }

        // 2. Read its transport type. If the device IS a BT device,
        //    done. If it's an aggregate (kAudioDeviceTransportTypeAggregate)
        //    we drill into its sub-devices to see if any of them is
        //    BT — that's the "BlackHole + AirPods" multi-output
        //    configuration which still hits the BT loopback bug.
        return isBluetoothTransport(deviceID: deviceID)
    }

    /// True when the default output device is the Mac's INTERNAL
    /// speakers: transport is built-in AND the data source reports
    /// the internal speaker ('ispk'), not the headphone jack
    /// ('hdpn'). Drives the once-a-day headphones recommendation at
    /// meeting start — with speakers the mic re-captures the remote
    /// side and speaker attribution can't be trusted. Conservative:
    /// any property-query failure returns false; a missed nudge is
    /// cheaper than a false one.
    nonisolated private static func currentOutputDeviceIsInternalSpeakers() -> Bool {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultOutAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let idStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutAddress,
            0, nil,
            &size, &deviceID
        )
        guard idStatus == noErr, deviceID != kAudioObjectUnknown else { return false }

        // Transport must be built-in. (External interfaces — USB
        // DACs, displays — can't be told speaker-vs-headphone apart,
        // so they never nudge.)
        var transportType: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &tSize, &transportType) == noErr,
              transportType == kAudioDeviceTransportTypeBuiltIn else { return false }

        // Data source on the OUTPUT scope: 'ispk' = internal
        // speaker, 'hdpn' = headphone jack.
        var dataSource: UInt32 = 0
        var dsSize = UInt32(MemoryLayout<UInt32>.size)
        var dsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &dsAddress, 0, nil, &dsSize, &dataSource) == noErr else {
            return false
        }
        return dataSource == 0x6973_706B  // FourCC 'ispk'
    }

    /// Recursively check whether `deviceID` (or any of its active
    /// sub-devices, if it's an aggregate) reports a Bluetooth
    /// transport. Catches the edge case where the user has set up
    /// an aggregate device (Audio MIDI Setup → Create Aggregate
    /// Device) that includes their AirPods as one of the members.
    /// The aggregate itself reports
    /// `kAudioDeviceTransportTypeAggregate`, but SCK's loopback
    /// still fails the same way as plain BT because the audio path
    /// goes through the BT stack at some point.
    nonisolated private static func isBluetoothTransport(deviceID: AudioDeviceID) -> Bool {
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let tStatus = AudioObjectGetPropertyData(
            deviceID, &transportAddress, 0, nil, &size, &transportType
        )
        guard tStatus == noErr else { return false }

        if transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE {
            return true
        }

        // Aggregate? Drill into sub-devices.
        guard transportType == kAudioDeviceTransportTypeAggregate else {
            return false
        }
        var subDevicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var subDevicesSize: UInt32 = 0
        let szStatus = AudioObjectGetPropertyDataSize(
            deviceID, &subDevicesAddress, 0, nil, &subDevicesSize
        )
        guard szStatus == noErr, subDevicesSize > 0 else { return false }

        let count = Int(subDevicesSize) / MemoryLayout<AudioObjectID>.size
        var subDevices = [AudioObjectID](repeating: 0, count: count)
        let listStatus = subDevices.withUnsafeMutableBufferPointer { buf -> OSStatus in
            var sz = subDevicesSize
            return AudioObjectGetPropertyData(
                deviceID, &subDevicesAddress, 0, nil, &sz, buf.baseAddress!
            )
        }
        guard listStatus == noErr else { return false }

        for sub in subDevices where sub != kAudioObjectUnknown {
            // Don't recurse infinitely if some absurd aggregate
            // contains an aggregate — direct transport check on
            // each sub is enough for the real-world configs we
            // care about (AirPods inside a multi-output aggregate).
            var subTransport: UInt32 = 0
            var subSize = UInt32(MemoryLayout<UInt32>.size)
            var subAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let s = AudioObjectGetPropertyData(
                sub, &subAddress, 0, nil, &subSize, &subTransport
            )
            if s == noErr,
               subTransport == kAudioDeviceTransportTypeBluetooth
                || subTransport == kAudioDeviceTransportTypeBluetoothLE {
                return true
            }
        }
        return false
    }

    /// Build + start a fresh SCStream against the current default
    /// output. Extracted from `start()` so the route-change handler
    /// (`handleOutputDeviceChange`) can rebuild against the new
    /// device without copying the dance. Throws `DaisyError.
    /// audioEngineFailed` on any failure; caller is responsible for
    /// resetting state.
    private func buildAndStartSystemAudioStream() async throws -> SCStream {
        // 1. Discover shareable content + the display we'll attach to.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            throw DaisyError.audioEngineFailed("Could not enumerate displays: \(error.localizedDescription)")
        }

        guard let display = content.displays.first else {
            throw DaisyError.audioEngineFailed("No displays available for screen capture.")
        }

        // Exclude our own app from the audio loopback.
        let ourApps = content.applications.filter {
            Bundle.main.bundleIdentifier == $0.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ourApps,
            exceptingWindows: []
        )

        // 2. Audio-only config (we still capture a 2×2 video frame because
        //    SCStream requires *some* video output to function).
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        // macOS 26.0.x (early Tahoe) regressed ScreenCaptureKit
        // loopback for the default config — SCStream attaches without
        // an exception but never delivers a single audio buffer, even
        // on built-in speakers with no Bluetooth in the picture
        // (tester 2026-05-23, frontmatter daisy_system_audio_status:
        // empty, log "Silent SCStream detected after 30s"). The most
        // commonly-reported workaround for Tahoe SCStream audio bugs
        // is single-channel mono + dropping `excludesCurrentProcessAudio`.
        // We apply both behind `#available(macOS 26, *)` so 14 / 15
        // keep the year-validated 2-channel + self-exclusion path,
        // and 26+ gets the conservative variant that has the best
        // chance of delivering frames. Track: business/projects/daisy
        // → "Известные баги macOS 26.0.1 Tahoe".
        if #available(macOS 26.0, *) {
            config.channelCount = 1
            // Leave excludesCurrentProcessAudio at default (false) on
            // macOS 26+ — we don't need it (Daisy doesn't play system
            // audio during a meeting recording, just brief sound
            // effects at start/pause/resume/stop), and on Tahoe early
            // builds this knob is suspected of suppressing the whole
            // loopback delivery.
        } else {
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        // 3. Build + start stream.
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
            // Build 41 — also subscribe to `.screen` even though we
            // never use the video frames. SCStream cannot run "audio-
            // only" (it always generates at least one video frame per
            // `minimumFrameInterval`). Without a `.screen` output
            // registered, every produced video frame triggered a 1 Hz
            // "stream output NOT found. Dropping frame" error in the
            // log (caught in the 2026-05-28 pause-hang investigation —
            // ~3000 spurious error lines per 50-min session). With a
            // registered output our `stream(_:didOutputSampleBuffer:_:)`
            // sees `outputType == .screen`, fails the `.audio` guard
            // on the first line, and returns — zero meaningful work,
            // but the SCStream side stops erroring. Dedicated queue so
            // discarded video traffic doesn't share the audio output
            // queue's serial slot.
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenDiscardQueue)
            try await stream.startCapture()
        } catch {
            throw DaisyError.audioEngineFailed("Could not start system audio: \(error.localizedDescription)")
        }
        return stream
    }

    /// Throwaway queue for the `.screen` output we register only to
    /// silence SCStream's "stream output NOT found" error spam. See
    /// the call site in `buildAndStartSystemAudioStream()` for the
    /// full rationale. `.utility` qos because frames are immediately
    /// discarded; no urgency.
    private let screenDiscardQueue = DispatchQueue(
        label: "app.essazanov.Daisy.SystemAudioScreenDiscard",
        qos: .utility
    )

    // MARK: - Default-output-device change observer

    /// Install a CoreAudio property listener for the default-output-
    /// device selector. When the user plugs in AirPods, unplugs them,
    /// or flips Sound output via Control Centre mid-meeting, this
    /// fires and we rebuild the SCStream against the new default —
    /// otherwise SCK stays bound to the OLD device and the remote
    /// side stops landing in the recording without any visible
    /// indication.
    ///
    /// Block-based variant (vs the C-callback variant) because the
    /// closure can capture `[weak self]` cleanly and dispatch back to
    /// MainActor; the C variant requires a raw `void*` self pointer
    /// and is more bookkeeping for the same effect.
    private func installOutputDeviceListener() {
        guard !outputDeviceListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // CoreAudio dispatches the block on the queue we pass
            // below — already off main. Hop back to MainActor for
            // the actual restart logic.
            Task { @MainActor [weak self] in
                await self?.handleOutputDeviceChange()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated),
            block
        )
        if status == noErr {
            outputDeviceListenerBlock = block
            outputDeviceListenerInstalled = true
            log.info("Output device listener installed")
        } else {
            log.error("Failed to install output device listener: status=\(status, privacy: .public)")
        }
    }

    /// Remove the property listener installed by
    /// `installOutputDeviceListener`. Idempotent.
    private func removeOutputDeviceListener() {
        guard outputDeviceListenerInstalled, let block = outputDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated),
            block
        )
        if status != noErr {
            log.error("Failed to remove output device listener: status=\(status, privacy: .public)")
        }
        outputDeviceListenerBlock = nil
        outputDeviceListenerInstalled = false
    }

    /// Tear down + rebuild the SCStream when macOS reports a default-
    /// output-device change. Debounces concurrent fires (macOS often
    /// emits the property change 2–3 times in rapid succession as the
    /// audio graph settles).
    private func handleOutputDeviceChange() async {
        guard state == .capturing else { return }
        guard !outputRestartInFlight else { return }
        // Wall-clock cooldown — defer-only debounce leaks the gap
        // between `outputRestartInFlight = false` and the next
        // CoreAudio fire (sleep/wake can re-emit hours later, the
        // bool alone isn't enough).
        if let last = lastOutputRestartAt,
           Date().timeIntervalSince(last) < 2.0 {
            return
        }
        outputRestartInFlight = true
        defer {
            outputRestartInFlight = false
            lastOutputRestartAt = Date()
        }

        log.info("Default output device changed mid-capture — restarting SCStream")

        if await rebuildStream(reason: "output-device-change") {
            if !quietDiagnostics {
                ToastCenter.shared.show(
                    String(localized: "Output device changed — system audio capture continues."),
                    style: .info
                )
            }
        } else {
            // Don't kill the rest of the recording session — mic
            // capture is in a separate recorder instance and is
            // unaffected by SCStream failure. Just surface to the
            // user so they can stop & restart if they need the
            // remote side captured.
            state = .stopped
            if !quietDiagnostics {
                ToastCenter.shared.show(
                    String(localized: "Output changed and Daisy couldn't keep recording the other side. Stop & restart the recording if you need it."),
                    style: .warning
                )
            }
        }
    }

    /// Tear down whatever stream we hold and start a fresh one against
    /// the CURRENT default output, resetting the liveness latches so
    /// the new stream gets a clean timeout window. Returns whether the
    /// rebuild succeeded; the caller owns state + user messaging.
    ///
    /// Extracted from the route-change handler (2026-08-10) so the
    /// delegate's `didStopWithError` can reuse the exact same recovery
    /// instead of only recording the corpse.
    private func rebuildStream(reason: String) async -> Bool {
        let generation = captureGeneration
        // Tear down current stream cleanly. Failures here don't block
        // the rebuild — we'll just have a dangling stream the kernel
        // cleans up. (On the didStopWithError path the stream is
        // already dead; stopCapture then throws and that's fine.)
        if let s = stream {
            do { try await s.stopCapture() }
            catch { log.info("Stop before rebuild (\(reason, privacy: .public)) failed — stream likely already dead: \(error.localizedDescription, privacy: .public)") }
        }
        stream = nil

        do {
            let newStream = try await buildAndStartSystemAudioStream()
            // Did Stop/Pause land while we were building? Then this
            // stream must not be adopted — kill it here or it captures
            // forever, unreferenced.
            guard generation == captureGeneration else {
                log.info("SCStream rebuild (\(reason, privacy: .public)) finished after capture ended — discarding")
                try? await newStream.stopCapture()
                return false
            }
            self.stream = newStream
            silenceWarningFired = false
            silentContentWarningFired = false
            captureStartedAt = Date()
            lastSampleAt = nil
            lastAudibleSampleAt = nil
            // `receivedAudibleAudio` is NOT reset (it used to be, on the
            // route-change path): it's a session-lifetime truth — the
            // post-stop archive audit reads it to decide `.captured` vs
            // `.empty`. Clearing it mid-session meant a rebuild late in
            // a meeting could report a full, good `.caf` as empty if the
            // far side happened not to speak again before Stop. Once the
            // remote side has been heard, that fact stands for the
            // session; the fresh-start reset still zeroes it.
            log.info("SCStream rebuilt (\(reason, privacy: .public))")
            return true
        } catch {
            log.error("SCStream rebuild (\(reason, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Recover from a stream macOS killed under us (`didStopWithError`).
    ///
    /// Field class of bug (see the silent-SCStream-death entry in the
    /// 2026-08 audit): the delegate used to just record `.stopped`, so
    /// the far side of a meeting stopped being recorded silently and
    /// the user found out when reading the transcript. Handy hit the
    /// same shape on the mic side and fixed it by restarting the
    /// capture worker (cjpais/Handy#1838) — same medicine here, using
    /// the route-change rebuild we already had.
    ///
    /// Bounded on purpose: `maxAutoRestarts` attempts per capture, with
    /// the same 2 s cooldown the route-change path uses, so a
    /// systematically failing stream (permission revoked mid-session,
    /// display disconnected) degrades to one honest toast instead of a
    /// restart storm. The budget is spent-once-per-capture — see
    /// `autoRestartCount`.
    private func handleStreamDeath(dead: ObjectIdentifier, error: Error) async {
        guard state == .capturing else { return }
        guard !outputRestartInFlight else { return }
        // Only the CURRENT stream's death is news (see the delegate).
        guard let live = stream, ObjectIdentifier(live) == dead else {
            log.info("Ignoring didStopWithError from a superseded stream: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Same 2 s cooldown the route-change path uses. A route change
        // both changes the default output AND kills the stream, so
        // without this one user action could spend the whole restart
        // budget in a burst and then claim capture had failed.
        if let last = lastOutputRestartAt,
           Date().timeIntervalSince(last) < 2.0 {
            log.info("Stream death within the restart cooldown — deferring to the in-flight recovery")
            return
        }

        guard autoRestartCount < Self.maxAutoRestarts else {
            log.error("SCStream died again after \(Self.maxAutoRestarts, privacy: .public) restarts — giving up: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            state = .stopped
            onCaptureGaveUp?()
            if !quietDiagnostics {
                CaptureProblemNotification.post(
                    title: String(localized: "Daisy stopped hearing the other side"),
                    body: String(localized: "System audio capture stopped and couldn’t be restarted. Your microphone is still being recorded.")
                )
                ToastCenter.shared.show(
                    String(localized: "System audio capture stopped and couldn’t restart — only your microphone is being recorded. Stop & restart if you need the other side."),
                    style: .warning
                )
            }
            return
        }

        outputRestartInFlight = true
        autoRestartCount += 1
        let attempt = autoRestartCount
        defer {
            outputRestartInFlight = false
            lastOutputRestartAt = Date()
        }
        log.error("SCStream stopped with error — auto-restart \(attempt, privacy: .public)/\(Self.maxAutoRestarts, privacy: .public): \(error.localizedDescription, privacy: .public)")

        if await rebuildStream(reason: "stream-death-\(attempt)") {
            // Quiet on success: the user didn't do anything and the
            // recording is intact. The log carries the detail; a toast
            // here would just teach them to distrust a working capture.
            return
        }
        lastError = error.localizedDescription
        state = .stopped
        onCaptureGaveUp?()
        if !quietDiagnostics {
            CaptureProblemNotification.post(
                title: String(localized: "Daisy stopped hearing the other side"),
                body: String(localized: "System audio capture stopped and couldn’t be restarted. Your microphone is still being recorded.")
            )
            ToastCenter.shared.show(
                String(localized: "System audio capture stopped and couldn’t restart — only your microphone is being recorded. Stop & restart if you need the other side."),
                style: .warning
            )
        }
    }

    /// Begin polling for the silent-capture condition. Polls every
    /// 5 s while `state == .capturing`. Cheap MainActor timer —
    /// touches no audio state, just reads `lastSampleAt` / start time
    /// and compares against `silentCaptureTimeoutSec`.
    private func startSilenceMonitor() {
        silenceMonitorTimer?.invalidate()
        silenceMonitorTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkForSilentCapture() }
        }
    }

    /// Stop the silence-monitor timer. Safe to call when no timer
    /// is installed.
    private func stopSilenceMonitor() {
        silenceMonitorTimer?.invalidate()
        silenceMonitorTimer = nil
    }

    /// Detect the "SCStream is nominally capturing but delivering no
    /// audio" failure mode. Classic causes on macOS Tahoe:
    ///
    ///   - default output is Bluetooth headphones (SCK's loopback
    ///     doesn't reach the BT stack on a number of macOS builds),
    ///   - Screen Recording permission was granted at runtime but
    ///     the foreground app's audio path isn't actually visible,
    ///   - output device hot-swapped mid-session (separate task —
    ///     output-device-change observer, #165).
    ///
    /// We fire a toast once per session. The UI surface for repeat
    /// occurrences (a dim system-audio dot in the widget) lives in
    /// the widget refactor (#168) — this is the audible warning.
    private func checkForSilentCapture() {
        guard state == .capturing else { return }
        let now = Date()

        // Path 1 — NO BUFFERS arriving (BT loopback, SCKit Tahoe
        // no-delivery, denied permission). Warn once per session.
        if !silenceWarningFired {
            let silentDuration: TimeInterval
            if let lastSampleAt {
                // We DID get buffers at some point — measure gap since
                // the last delivered one.
                silentDuration = now.timeIntervalSince(lastSampleAt)
            } else if let captureStartedAt {
                // No buffers since session start — measure age of the
                // capture itself.
                silentDuration = now.timeIntervalSince(captureStartedAt)
            } else {
                silentDuration = 0
            }
            if silentDuration >= Self.silentCaptureTimeoutSec {
                silenceWarningFired = true
                let neverGotAudio = !hasReceivedAudio
                let msg = neverGotAudio
                    ? String(localized: "Daisy isn't hearing the other side — they won't be recorded. Check your output device (Bluetooth headphones can't be captured on macOS).")
                    : String(localized: "The other side went silent and may not be recording anymore. Check your output device.")
                log.warning("Silent SCStream detected after \(Int(silentDuration), privacy: .public)s (hasReceivedAudio=\(self.hasReceivedAudio, privacy: .public))")
                ToastCenter.shared.show(msg, style: .warning)
                return
            }
        }

        // Path 2 — BUFFERS ARE ARRIVING but every sample is silence
        // (DRM-protected playback, or the macOS Tahoe all-zero-buffer
        // capture glitch — buffers flow at full cadence, content is pure
        // zeros, the archive lands a file full of silence). Distinct from
        // path 1: here `hasReceivedAudio` is true but nothing has ever
        // crossed `audibleFloorDB`. Warn once, only after enough time
        // that a merely-quiet remote side wouldn't trip it.
        if !silentContentWarningFired,
           hasReceivedAudio,
           !receivedAudibleAudio,
           let captureStartedAt,
           now.timeIntervalSince(captureStartedAt) >= Self.silentContentTimeoutSec {
            silentContentWarningFired = true
            log.warning("Silent-content system capture: buffers arriving but nothing audible after \(Int(now.timeIntervalSince(captureStartedAt)), privacy: .public)s")
            ToastCenter.shared.show(
                String(localized: "Daisy is capturing the other side but there's no sound in it — they won't be recorded. This usually means DRM-protected playback or a macOS capture glitch. Try a different source or restart the recording."),
                style: .warning
            )
        }
    }

    func stop() async {
        captureGeneration &+= 1   // strand any rebuild in flight
        stopSilenceMonitor()
        removeOutputDeviceListener()
        captureStartedAt = nil
        peakLevelDB = -160
        guard let s = stream else {
            if state != .paused { state = .stopped }
            else { state = .stopped }
            // Close archive even if no stream is active (covers the
            // already-paused → stop transition). Still gated through
            // outputQueue.sync for symmetry — if an old stream's
            // callback is somehow still pending, we serialize behind
            // it.
            outputQueue.sync {
                archiveWriter = nil
                archiveURL = nil
            }
            return
        }
        do { try await s.stopCapture() }
        catch {
            // Benign: the stream was already stopped or never fully started
            // (e.g. Screen Recording denied → SCStream never ran), so there
            // is nothing to stop. Log at info, not error — the real "is the
            // other side captured?" signal lives in `systemAudioStatus` /
            // the silence monitor, not in this teardown.
            log.info("SystemAudio stop: nothing to stop (\(error.localizedDescription, privacy: .public))")
        }
        stream = nil
        bufferContinuation?.finish()
        bufferContinuation = nil
        // Fence behind any in-flight sample-buffer callback. After
        // `stopCapture()` returns, ScreenCaptureKit promises no NEW
        // buffers will be delivered, but a callback currently mid-
        // execution on outputQueue can still touch archiveWriter.
        // `outputQueue.sync` on a serial queue blocks until that
        // callback finishes, then runs our block (which nils out
        // the writer, triggering ExtAudioFile dispose under the
        // same queue — atomic w.r.t. any callback).
        outputQueue.sync {
            archiveWriter = nil
            archiveURL = nil
        }
        state = .stopped
    }

    /// Soft pause: tear down the SCStream but keep the
    /// bufferContinuation alive so the upstream Transcriber's
    /// for-await loop doesn't terminate. ScreenCaptureKit has no
    /// native pause — we rebuild a fresh stream in `resume()` and
    /// route it to the same continuation.
    func pause() async {
        guard state == .capturing, let s = stream else { return }
        captureGeneration &+= 1   // strand any rebuild in flight
        stopSilenceMonitor()
        removeOutputDeviceListener()
        peakLevelDB = -160
        do { try await s.stopCapture() }
        catch { log.error("Pause error: \(error.localizedDescription, privacy: .public)") }
        stream = nil
        state = .paused
        log.info("SystemAudio paused")
    }

    /// Stop writing the system-audio archive but keep delivering buffers
    /// to the transcriber (low-disk → transcript-only). The render
    /// callback yields to the continuation BEFORE the archive block, so
    /// nil-ing the URL + writer just skips the on-disk write (and
    /// finalizes whatever was written so far). Fenced through outputQueue
    /// like every other writer mutation.
    func stopArchivingKeepTranscribing() {
        outputQueue.sync {
            archiveWriter = nil
            archiveURL = nil
        }
        log.warning("System audio archiving stopped (low disk) — transcription continues")
    }

    /// Resume after `pause()`: build a new SCStream with the same
    /// config and route its output to the existing continuation.
    func resume() async throws {
        guard state == .paused else { return }
        // Re-run the full discover + filter + config dance — display
        // topology can change while we were paused (Mac plugged into
        // a different monitor, etc.).
        try await start()
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of outputType: SCStreamOutputType) {
        guard outputType == .audio,
              CMSampleBufferIsValid(sampleBuffer),
              let pcm = Self.pcmBuffer(from: sampleBuffer) else {
            return
        }
        let chunk = AudioChunk(pcm: pcm, time: AVAudioTime(hostTime: mach_absolute_time()))
        bufferContinuation?.yield(chunk)

        // Publish a rate-limited level meter + sample-arrival
        // timestamp to MainActor. SCStream can fire ~50 callbacks/s
        // at 48 kHz with typical CMSampleBuffer sizes; the widget
        // and silence monitor only need ~10 Hz. The gate ensures we
        // don't pound the MainActor queue.
        let nowRefTime = Date().timeIntervalSinceReferenceDate
        if nowRefTime - lastUIUpdateRefTime > 0.1 {
            lastUIUpdateRefTime = nowRefTime
            let peak = Self.peakLevelDB(of: pcm)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.peakLevelDB = peak
                self.lastSampleAt = Date()
                self.hasReceivedAudio = true
                // Buffers are flowing → clear the "no buffers at all"
                // warning so the status reflects live state, not a past
                // stall. It re-fires only if delivery stops again ≥30s.
                self.silenceWarningFired = false
                if peak > Self.audibleFloorDB {
                    self.lastAudibleSampleAt = Date()
                    self.receivedAudibleAudio = true
                    // Real audible content arrived → the remote side IS
                    // being captured. Clear the silent-content warning so
                    // the "Only your voice — couldn't reach the other
                    // side" banner disappears the moment the other party
                    // speaks. It can't re-fire: path 2 in
                    // checkForSilentCapture() requires !receivedAudibleAudio,
                    // which is now permanently true for this session.
                    self.silentContentWarningFired = false
                }
            }
        }

        // Archive write — lazily open AVAudioFile on the first
        // sample so we use the actual stream format (avoids
        // settings-dict drift between what we declared and what SCK
        // delivers). All access happens on `outputQueue`, which is
        // single-threaded, so no race on archiveWriter / archiveURL.
        guard let url = archiveURL else { return }
        if archiveWriter == nil {
            do {
                archiveWriter = try AVAudioFile(
                    forWriting: url,
                    settings: pcm.format.settings,
                    commonFormat: pcm.format.commonFormat,
                    interleaved: pcm.format.isInterleaved
                )
            } catch {
                // Don't keep retrying every sample if open failed —
                // disable archiving for the rest of the session.
                // Transcription continues unaffected.
                log.error("System audio archive open failed: \(error.localizedDescription, privacy: .public)")
                archiveURL = nil
                return
            }
        }
        // Format guard (2026-08-10). `AVAudioFile.write(from:)` raises
        // an ObjC `NSInvalidArgumentException` — uncatchable from Swift,
        // i.e. an instant crash — when the buffer's format differs from
        // the file's. The writer is opened once and outlives SCStream
        // rebuilds (route change, death recovery), and while
        // `SCStreamConfiguration` pins the rate/layout, a rebuild is
        // exactly where a divergence could appear. The mic path already
        // handles this by rolling a `.partN.caf`; here the archive is a
        // single file, so we stop archiving rather than risk the crash —
        // what's on disk stays valid and the audit reports honestly.
        if let writer = archiveWriter, writer.processingFormat != pcm.format {
            log.error("System audio format changed mid-capture (\(writer.processingFormat, privacy: .public) → \(pcm.format, privacy: .public)) — closing the archive rather than writing a mismatched buffer")
            archiveWriter = nil
            archiveURL = nil
            return
        }
        do {
            try archiveWriter?.write(from: pcm)
            // 2026-05-25 — counter for the silent-write-death detector.
            // hasReceivedAudio flips true on first SCK buffer (above);
            // archiveFramesWritten flips up only on a successful disk
            // write. Divergence between the two is the truncation
            // signal RecordingSession.stop() now toasts on.
            archiveFramesWritten &+= UInt64(pcm.frameLength)
        } catch {
            // One sample's write failure shouldn't trash the whole
            // recording — log and move on. Persistent failures will
            // pollute the log but the live transcript stays intact.
            log.error("System audio archive write failed: \(error.localizedDescription, privacy: .public)")
            archiveWriteErrorCount &+= 1
            if firstArchiveWriteError == nil {
                firstArchiveWriteError = error.localizedDescription
            }
        }
    }

    // MARK: - Archive-truncation telemetry (read by RecordingSession)

    /// Total audio frames that successfully landed in the archive
    /// AVAudioFile via `try archiveWriter.write(from:)`. Zero means
    /// either no SCK buffers arrived (combine with `hasReceivedAudio`
    /// to distinguish) OR every write threw (combine with
    /// `archiveWriteErrorsSummary` for the cause).
    ///
    /// Thread-safe: read via `outputQueue.sync` because the writer
    /// path mutates this from that queue. Cheap — single hop, no
    /// allocation.
    var archivedFrameCount: UInt64 {
        outputQueue.sync { archiveFramesWritten }
    }

    /// (errorCount, firstErrorMessage). Non-zero `count` with
    /// `archivedFrameCount` ≪ wallClockFrames is the canonical
    /// "truncated" signal. Used by RecordingSession.stop() to
    /// pick `.captured` vs `.truncated` and to choose toast copy.
    var archiveWriteErrorsSummary: (count: Int, first: String?) {
        outputQueue.sync { (archiveWriteErrorCount, firstArchiveWriteError) }
    }

    /// Peak amplitude (in dB, where 0 dB = full-scale) over the
    /// frames in `buffer`. Mirrors `AudioRecorder.peakLevelDB(of:)`
    /// — kept inline here so this class doesn't import the mic
    /// recorder's private static helper. Cheap: O(frames × channels)
    /// over a single PCMBuffer, runs on the SCStream output queue.
    nonisolated private static func peakLevelDB(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return -160 }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        var peak: Float = 0
        for ch in 0..<count {
            let ptr = channels[ch]
            for i in 0..<frames {
                let v = abs(ptr[i])
                if v > peak { peak = v }
            }
        }
        guard peak > 0 else { return -160 }
        return 20 * log10(peak)
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Identify WHICH stream died. `stopCapture()` gives no
        // synchronous guarantee that no further delegate callbacks
        // arrive, so a stream we tore down during a rebuild can report
        // its death afterwards — and acting on that would tear down the
        // healthy replacement and spend recovery budget on a corpse.
        // `ObjectIdentifier` is Sendable; `SCStream` is not.
        let dead = ObjectIdentifier(stream)
        Task { @MainActor [weak self] in
            await self?.handleStreamDeath(dead: dead, error: error)
        }
    }

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer

    nonisolated private static func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sample),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: format.channelCount,
                mDataByteSize: 0,
                mData: nil
            )
        )

        let err = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard err == noErr else { return nil }

        let srcABL = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        if format.isInterleaved {
            if let src = srcABL[0].mData,
               let dst = buffer.audioBufferList.pointee.mBuffers.mData {
                memcpy(dst, src, Int(srcABL[0].mDataByteSize))
            }
        } else {
            let dstABL = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for ch in 0..<min(srcABL.count, dstABL.count) {
                if let src = srcABL[ch].mData, let dst = dstABL[ch].mData {
                    memcpy(dst, src, Int(srcABL[ch].mDataByteSize))
                }
            }
        }
        return buffer
    }
}
