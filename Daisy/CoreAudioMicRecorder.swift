//
//  CoreAudioMicRecorder.swift
//  Daisy
//
//  Direct CoreAudio AUHAL microphone capture — a drop-in replacement
//  for `AudioRecorder` (which uses AVAudioEngine). Everything runs
//  locally; no audio leaves the device.
//
//  WHY THIS EXISTS (the AVAudioEngine bug it sidesteps)
//  ----------------------------------------------------
//  On macOS 26.5, AVAudioEngine's `inputNode`/`outputNode` share ONE
//  internal AUHAL that gets stuck in sample-rate-conversion mode after
//  a route change: the input HARDWARE runs at e.g. 48000 Hz, but
//  `inputNode.outputFormat(forBus: 0)` stays pinned at a stale 44100 Hz,
//  and even a full `AVAudioEngine()` rebuild does NOT clear it (the
//  stale state is HAL/aggregate-device level, not the Swift object).
//  The tap then either delivers 0 frames or delivers 44100-rate audio
//  the transcriber can't use → empty transcript. See `AudioRecorder`'s
//  `handleConfigurationChange` / `rebuildEngineAndRetry` for the long
//  archaeology of fighting that bug from the AVAudioEngine layer.
//
//  CoreAudio reads the device's REAL rate correctly (48000 on the input
//  scope + nominal). So this class owns the device + the stream-format
//  negotiation DIRECTLY against CoreAudio's truth — we open a
//  `kAudioUnitSubType_HALOutput` AudioUnit, pin it to the resolved input
//  device, read the device's real input ASBD, set our float32 client
//  format at THAT rate, and pull frames via `AudioUnitRender` from an
//  input render callback. No shared engine, no hidden SRC, no stale
//  cached format to flush.
//
//  This is the sole microphone-capture backend. (It originally shipped
//  behind `AppSettings.useCoreAudioMicCapture` alongside a legacy
//  AVAudioEngine recorder; that flag and the `AudioRecorder` fallback
//  were removed once CoreAudio capture was validated as the default.)
//
//  REFERENCES
//  ----------
//  • Apple TN2091 "Device input using the HAL Output Audio Unit" — the
//    canonical recipe (EnableIO on element 1, disable element 0, set
//    kAudioOutputUnitProperty_CurrentDevice, kAudioOutputUnitProperty_
//    SetInputCallback, AudioUnitRender in the callback).
//  • Apple CoreAudio "AudioUnitProperties.h" / "AUComponent.h" headers.
//  • The AUHAL element/scope convention: element 1 == INPUT (mic),
//    element 0 == OUTPUT (speaker). Input audio appears on the OUTPUT
//    scope of element 1 (the data "comes out of" the input element).
//

import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Observation
import os

// MARK: - Shared audio types

/// Ferry an `AVAudioPCMBuffer` across actor boundaries. Buffers handed
/// downstream are not mutated after they're yielded, so this is safe in
/// practice. `nonisolated` overrides the file-level MainActor default so
/// it can be constructed/destructured from any context (the CoreAudio
/// render thread, the ScreenCaptureKit output queue, etc.).
///
/// Used by `CoreAudioMicRecorder`, `SystemAudioCapture`, and `Transcriber`.
/// (Originally declared in the now-removed `AudioRecorder.swift`; moved
/// here when that legacy AVAudioEngine backend was deleted.)
nonisolated struct AudioChunk: @unchecked Sendable {
    let pcm: AVAudioPCMBuffer
    let time: AVAudioTime
}

/// Errors surfaced by the audio-capture subsystem (mic + system audio).
/// `nonisolated` so it can be thrown/inspected off the MainActor.
/// Shared by `CoreAudioMicRecorder` and `SystemAudioCapture`. (Originally
/// declared in the now-removed `AudioRecorder.swift`.)
nonisolated enum DaisyError: LocalizedError {
    case noMicrophone
    case speechUnauthorized
    case onDeviceUnsupported(locale: String)
    case recognitionFailed(String)
    case audioEngineFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMicrophone:
            return "No microphone input is available."
        case .speechUnauthorized:
            return "Speech recognition permission was denied. Grant it in System Settings → Privacy & Security → Speech Recognition."
        case .onDeviceUnsupported(let locale):
            return "On-device speech recognition is not available for \(locale). Try a different language."
        case .recognitionFailed(let msg):
            return "Recognition failed: \(msg)"
        case .audioEngineFailed(let msg):
            return "Audio engine failed: \(msg)"
        }
    }
}

/// Why the recorder put itself on pause mid-session. Reported to the
/// session through `onFellToPaused` so the app's state and the person's
/// screen agree with the hardware.
nonisolated enum MicPauseReason: Sendable {
    /// A route change left no usable input device at all.
    case noInputDevice
    /// Rebuilding the audio unit on the new device failed.
    case rebuildFailed
    /// The unit reported started, but no buffers ever arrived.
    case noBuffers
    /// The liveness watchdog fired. It has already told the person why
    /// (digital silence gets its own actionable message), so the
    /// session should update state without a second announcement.
    case silenceAlreadyAnnounced
}

// MARK: - CoreAudioMicRecorder

@Observable
@MainActor
final class CoreAudioMicRecorder {
    enum RecordingState: Equatable {
        case idle
        case recording
        /// Output unit stopped but the file handle, continuation and
        /// device binding are preserved. `resume()` re-reads the format,
        /// rolls a new part if it changed, and starts the unit again —
        /// writes continue appending (audio time jumps, wall clock
        /// doesn't, by design — mirrors AudioRecorder.pause/resume).
        case paused
        case stopped
    }

    // MARK: - Observable state

    private(set) var state: RecordingState = .idle
    private(set) var levelDB: Float = -160
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastError: String?
    private(set) var archivedFileURL: URL?
    /// Normalised 0…1 spectrum bands for the daisy widget's petals.
    /// The render thread writes the latest value into `levelSpectrum`
    /// (a lock-box); a single MainActor display-cadence timer
    /// (`displayTimer`, ~30 Hz) copies it into this Observable property.
    /// We deliberately do NOT hop a `Task { @MainActor }` per render
    /// buffer — see `RenderContext.process` for the why (those detached
    /// Tasks starve under heavy MainActor/cooperative-pool load, e.g.
    /// WhisperKit large-v3 4× fallback, leaving the petals frozen).
    private(set) var spectrumBands: [Float] = Array(
        repeating: 0,
        count: SpectrumAnalyzer.bandCount
    )

    // MARK: - Audio unit + format

    /// The HAL output audio unit configured for INPUT capture. Created
    /// in `start()`, torn down in `stop()`. `nonisolated(unsafe)` is NOT
    /// used — we only touch this from the MainActor (lifecycle) and pass
    /// the opaque handle into the C render callback via the refcon box,
    /// never reading the property from the render thread.
    @ObservationIgnored
    private var audioUnit: AudioComponentInstance?

    /// Client (output-scope, element 1) format we set on the unit: the
    /// device's REAL input rate, float32, non-interleaved, same channel
    /// count the device reports. This is also the format of every
    /// `AVAudioPCMBuffer` we hand downstream and the format the archive
    /// `AVAudioFile` is opened with. Captured in `configureUnit`.
    @ObservationIgnored
    private var clientFormat: AVAudioFormat?

    /// AVAudioFormat object cached for buffer wrapping (same value as
    /// `clientFormat`; kept distinct only for readability at the call
    /// site in the render callback's refcon).
    @ObservationIgnored
    private var audioFile: AVAudioFile?

    @ObservationIgnored
    private var bufferContinuation: AsyncStream<AudioChunk>.Continuation?

    // MARK: - Timing

    @ObservationIgnored
    private var elapsedTimer: Timer?
    /// MainActor display-cadence timer (~30 Hz) that pumps the latest
    /// level + spectrum out of `levelSpectrum` and into the Observable
    /// `levelDB` / `spectrumBands`. Runs on the main run loop (same
    /// place the widget's TimelineView is serviced), so it can't be
    /// starved by a saturated cooperative pool the way the old
    /// per-buffer `Task { @MainActor }` was. Lifecycle mirrors
    /// `elapsedTimer`: armed in start()/resume(), torn down in
    /// pause()/stop().
    @ObservationIgnored
    private var displayTimer: Timer?
    @ObservationIgnored
    private var startedAt: Date?
    /// Sum of completed active intervals before the current one — so a
    /// pause/resume cycle measures audio captured, not wall clock.
    /// Identical semantics to AudioRecorder.
    @ObservationIgnored
    private var accumulatedActiveSec: TimeInterval = 0

    // MARK: - Collaborators

    @ObservationIgnored
    private let analyzer = SpectrumAnalyzer()
    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "CoreAudioMicRecorder")

    // MARK: - Cross-thread boxes (same lock-box patterns as AudioRecorder)

    /// Thread-safe write-failure accumulator (render callback can't reach
    /// MainActor per buffer). Surfaced as a single summary at `stop()`.
    @ObservationIgnored
    private let writeErrors = WriteErrorBox()
    /// Frames that successfully landed on disk via `audioFile.write`.
    /// RecordingSession compares against `elapsed * sampleRate` to tell
    /// `.captured` from `.truncated`. Reset on each `start()`.
    @ObservationIgnored
    private let framesWritten = FrameCountBox()
    /// Render-thread → MainActor bridge for the last-buffer arrival time,
    /// read by the recovery watchdog to detect a silently-dead device.
    @ObservationIgnored
    private let bufferTimestamp = TimestampBox()
    /// Render-thread → MainActor liveness bridge (RMS above floor).
    @ObservationIgnored
    private let micLiveness = LivenessBox()

    /// Latest mic RMS (dBFS) from the render thread — continuously
    /// updated while recording, −160 after pause/stop reset. Used by
    /// RecordingSession's auto-stop speech gate: RMS, unlike
    /// `levelDB`'s peak, rides through keyboard clicks / chair creaks
    /// / fan transients instead of spiking on them.
    /// internal for RecordingSession+AutoStop.swift
    var lastMicRMSDB: Float { micLiveness.snapshot().lastRMS }

    /// True when this capture consisted (almost) entirely of bit-exact
    /// zero samples — macOS handed us an empty signal rather than a
    /// quiet room (see `LivenessBox`). Read by the dictation paste path
    /// so an empty result can name its real cause (2026-07-26).
    var sawDigitalSilence: Bool {
        let snap = micLiveness.snapshot()
        return snap.total > 0 && snap.allZero * 10 >= snap.total * 9
    }

    /// Level helpers, re-exported from the render-thread context below.
    /// The implementations live on `RenderContext` (a PRIVATE class —
    /// invisible outside this file), so these internal forwarders are
    /// the public face DaisyTests' −160 dB sentinel locks compile
    /// against. Pure functions, no recorder state involved.
    nonisolated static func peakLevelDB(of buffer: AVAudioPCMBuffer) -> Float {
        RenderContext.peakLevelDB(of: buffer)
    }
    nonisolated static func rmsLevelDB(of buffer: AVAudioPCMBuffer) -> Float {
        RenderContext.rmsLevelDB(of: buffer)
    }
    /// Render-thread write gate (low-disk → transcript-only without
    /// tearing down capture). Default open; closed by
    /// `stopArchivingKeepTranscribing()`, reopened on each `start()`.
    @ObservationIgnored
    private let archiveGate = AtomicFlag(initial: true)
    /// Render-thread → MainActor bridge for the live level + spectrum.
    /// The render callback writes the latest (rate-limited) value here;
    /// the MainActor `displayTimer` reads it and publishes to the
    /// `@Observable levelDB` / `spectrumBands`. This replaces the old
    /// per-buffer `Task { @MainActor }` hop, which starved under heavy
    /// MainActor + cooperative-pool load and froze the daisy petals.
    @ObservationIgnored
    private let levelSpectrum = LevelSpectrumBox()

    // MARK: - Device / route state

    /// Stashed at `start()` so route-change recovery can re-pin to the
    /// same device choice. Empty string == "follow system default".
    @ObservationIgnored
    private var activePreferredDeviceUID: String = ""
    /// Snapshot of the opt-in background-noise setting for this capture.
    /// A route rebuild reuses it so processing cannot change halfway
    /// through a recording merely because the input device changed.
    @ObservationIgnored
    private var activeNoiseSuppressionEnabled = false
    /// The device we're currently bound to (authoritative, set by US at
    /// bind time, not read back from the unit). nil until first bind.
    @ObservationIgnored
    private var boundDeviceID: AudioDeviceID?
    @ObservationIgnored
    private var lastBoundInputUID: String?

    /// CoreAudio default-input-device listener block + install flag.
    @ObservationIgnored
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored
    private var defaultInputListenerInstalled = false
    /// Stream-format listener on the *bound device's* input scope —
    /// catches an in-place sample-rate flip (e.g. the device renegotiates
    /// 44.1→48 kHz without the default-device selector changing). We need
    /// this because, unlike AVAudioEngine, nobody auto-reconfigures the
    /// AUHAL for us.
    @ObservationIgnored
    private var deviceFormatListenerBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored
    private var deviceFormatListenerDeviceID: AudioDeviceID?
    /// Wall-clock debounce — macOS often emits a route change 2–3 times
    /// in rapid succession as the graph settles. Mirrors AudioRecorder.
    @ObservationIgnored
    private var lastReconfigureAt: Date?

    // MARK: - Recovery watchdog

    @ObservationIgnored
    private var recoveryWatchdog: Timer?
    @ObservationIgnored
    private var recoveryGeneration: Int = 0
    /// Mid-session watchdog rebuilds spent this session (see
    /// `checkRecoveryProgress`). Not refunded on recovery — bounding a
    /// flapping device matters more than surviving a third stall.
    @ObservationIgnored
    private var midSessionRebuilds: Int = 0
    private static let maxMidSessionRebuilds = 2
    @ObservationIgnored
    private var silenceMonitor: Timer?

    // MARK: - Archive parts

    /// Every .caf written this session. First entry == `archivedFileURL`.
    /// Extra entries appear only when a mid-session route change brought
    /// a new input format (mirrors AudioRecorder's part logic).
    @ObservationIgnored
    private(set) var archivedParts: [URL] = []
    @ObservationIgnored
    private var partCounter: Int = 0

    var archivedFrameCount: UInt64 { framesWritten.snapshot() }
    var archiveWriteErrorsSummary: (count: Int, first: (any Error)?) { writeErrors.snapshot() }

    // MARK: - API: buffers

    /// Subscribe to PCM buffers as they arrive. Read this **before**
    /// `start()` so the continuation is installed before the first
    /// `AudioUnitRender`. Same contract as `AudioRecorder.buffers`.
    var buffers: AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            self.bufferContinuation = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.bufferContinuation = nil
                }
            }
        }
    }

    // MARK: - API: start

    /// Begin capturing microphone audio via a HAL Output AudioUnit.
    /// Pass an `archiveURL` to also write a .caf. `preferredDeviceUID`
    /// is the stable device UID the user picked; empty/nil follows the
    /// macOS system default. Throws `DaisyError` on unrecoverable setup
    /// failure (no device, format read failed, unit won't initialize).
    func start(
        archiveURL: URL? = nil,
        preferredDeviceUID: String? = nil,
        noiseSuppressionEnabled: Bool = false
    ) throws {
        guard state != .recording else { return }
        lastError = nil
        // Clear signal accounting up front, not after the unit is
        // built: a throw from makeAndConfigureUnit used to leave the
        // PREVIOUS session's counters in the box, so a later
        // `sawDigitalSilence` read could report stale state
        // (2026-07-26).
        micLiveness.reset(to: Date())

        activePreferredDeviceUID = preferredDeviceUID ?? ""
        activeNoiseSuppressionEnabled = noiseSuppressionEnabled

        // Resolve the device BEFORE creating the unit so we read the
        // right device's real format.
        let deviceID = resolveInputDeviceID(uid: activePreferredDeviceUID)
        guard deviceID != 0 else {
            throw DaisyError.noMicrophone
        }

        // Create + configure the unit (this also reads the real format
        // and stores `clientFormat`).
        let unit = try makeAndConfigureUnit(deviceID: deviceID)
        audioUnit = unit
        boundDeviceID = deviceID
        lastBoundInputUID = AudioInputDevices.uid(for: deviceID)

        guard let format = clientFormat, format.channelCount > 0 else {
            disposeUnit()
            throw DaisyError.noMicrophone
        }

        // Open the archive at the device's REAL format.
        if let archiveURL {
            do {
                audioFile = try AVAudioFile(forWriting: archiveURL, settings: format.settings)
                archivedFileURL = archiveURL
                archivedParts = [archiveURL]
                partCounter = 1
            } catch {
                disposeUnit()
                throw DaisyError.audioEngineFailed(error.localizedDescription)
            }
        } else {
            audioFile = nil
            archivedFileURL = nil
            archivedParts = []
            partCounter = 0
        }

        // Reset cross-thread accounting for a fresh session.
        writeErrors.reset()
        framesWritten.reset()
        bufferTimestamp.reset()
        midSessionRebuilds = 0
        micLiveness.reset(to: Date())
        archiveGate.set(true)
        levelSpectrum.reset()

        // Wire the render context (sets the input callback) BEFORE
        // initialize — the callback reads this box, and the canonical
        // AUHAL ordering is callback-then-initialize.
        installRenderContext(format: format)

        // Initialize now that the callback is in place.
        do {
            try initializeUnit(unit)
        } catch {
            // initializeUnit disposed the unit; clear our handle + box.
            audioUnit = nil
            renderContext = nil
            audioFile = nil
            archivedFileURL = nil
            throw error
        }

        // Route-change listeners. These do the job AVAudioEngine's
        // ConfigurationChange notification + our CoreAudio listener did
        // in AudioRecorder, but here they're the ONLY recovery trigger
        // (no engine to tell us anything).
        installDefaultInputListener()
        installDeviceFormatListener(for: deviceID)

        // Start pulling audio.
        let startStatus = AudioOutputUnitStart(unit)
        guard startStatus == noErr else {
            removeDeviceFormatListener()
            removeDefaultInputListener()
            disposeUnit()
            audioFile = nil
            archivedFileURL = nil
            throw DaisyError.audioEngineFailed("AudioOutputUnitStart failed (status \(startStatus))")
        }

        startedAt = Date()
        elapsed = 0
        accumulatedActiveSec = 0
        state = .recording

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        startDisplayTimer()
        startSilenceMonitor()
        // Same arrival watchdog AudioRecorder arms at initial start:
        // AudioOutputUnitStart can return success while the device
        // delivers 0 frames. On no-buffers-in-5s, reconfigure (re-resolve
        // device + re-read format) rather than burning the meeting on a
        // dead callback.
        armRecoveryWatchdog(escalateToReconfigure: true)

        // Full device identity, not just the numeric ID — see
        // AudioInputDevices.describe. Plus the LIVE mic permission at
        // the moment of capture: the log report's Permissions line is
        // read when the user sends the report, which can be hours and
        // several restarts after the failing session (2026-07-26).
        log.info("CoreAudioMicRecorder started on \(AudioInputDevices.describe(deviceID), privacy: .public) at client \(format.sampleRate, privacy: .public) Hz / \(format.channelCount, privacy: .public) ch, micPermission=\(SystemPermissions.micAuthorizationDescription(), privacy: .public)")
    }

    // MARK: - API: pause / resume

    /// Soft pause. Stops the output unit but keeps the file handle,
    /// continuation and device binding alive — `resume()` re-arms the
    /// unit and writes continue appending. Matches AudioRecorder.pause().
    func pause() {
        guard state == .recording, let unit = audioUnit else { return }
        cancelRecoveryWatchdog()
        stopSilenceMonitor()
        let status = AudioOutputUnitStop(unit)
        if status != noErr {
            log.error("AudioOutputUnitStop (pause) failed: status \(status, privacy: .public)")
        }
        // The unit is stopped, so the RT thread won't enqueue more work.
        // Drain the serial queue so the tail captured right up to the pause
        // is written + counted (and no queued block runs concurrently with
        // the MainActor state mutation below). The file stays open — resume
        // keeps appending — but the in-flight buffers must land first.
        renderContext?.flush()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        stopDisplayTimer()
        levelSpectrum.reset()
        if let startedAt {
            accumulatedActiveSec += Date().timeIntervalSince(startedAt)
        }
        startedAt = nil
        levelDB = -160
        spectrumBands = Array(repeating: 0, count: SpectrumAnalyzer.bandCount)
        state = .paused
        log.info("CoreAudioMicRecorder paused after \(self.elapsed, privacy: .public)s")
    }

    /// Resume after `pause()`. Re-resolves the device, re-reads its real
    /// format, rolls the archive into a new `.partN.caf` if the format
    /// changed (the device may have switched while we were paused — same
    /// scenario AudioRecorder.resume() guards against), reinstalls the
    /// render context, and restarts the unit.
    func resume() throws {
        guard state == .paused else { return }
        // Whatever we warned about is being retried — clear the banner
        // so "Daisy can't hear you" doesn't outlive the problem.
        CaptureProblemNotification.cancel()
        micLiveness.reset(to: Date())

        // Re-resolve the device — the user may have switched mics in
        // Settings, or unplugged a headset, while paused.
        let deviceID = resolveInputDeviceID(uid: activePreferredDeviceUID)
        guard deviceID != 0 else {
            log.error("Resume failed — no input device available.")
            throw DaisyError.audioEngineFailed("No audio input device available. Connect a mic and try again.")
        }

        // If the device changed, we must rebuild the unit (the AUHAL is
        // bound to the OLD AudioDeviceID and its client format was
        // negotiated for the old device). If it's the same device, a
        // re-configure of format on the existing unit is enough, but
        // rebuilding is simplest and always-correct — do that.
        do {
            try rebuildUnit(on: deviceID, reason: "resume")
        } catch {
            throw DaisyError.audioEngineFailed("Mic device couldn't reinitialize on resume: \(error.localizedDescription)")
        }

        startedAt = Date()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        state = .recording
        startDisplayTimer()
        armRecoveryWatchdog()
        startSilenceMonitor()
        log.info("CoreAudioMicRecorder resumed")
    }

    // MARK: - API: stop

    func stop() {
        // Tolerate stop-from-paused (the explicit Stop & save path may
        // come straight from a paused session) — mirrors AudioRecorder.
        guard state == .recording || state == .paused else { return }
        removeDefaultInputListener()
        removeDeviceFormatListener()
        cancelRecoveryWatchdog()
        stopSilenceMonitor()

        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
        }
        disposeUnit()

        bufferContinuation?.finish()
        bufferContinuation = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        stopDisplayTimer()
        levelSpectrum.reset()
        audioFile = nil  // closes the file (flushes header + frames)
        analyzer.reset()
        spectrumBands = Array(repeating: 0, count: SpectrumAnalyzer.bandCount)
        state = .stopped
        log.info("CoreAudioMicRecorder stopped after \(self.elapsed, privacy: .public)s")

        // Surface render-thread write failures (identical UX to
        // AudioRecorder.stop()).
        let (errCount, firstErr) = writeErrors.snapshot()
        if errCount > 0 {
            let firstMessage = firstErr?.localizedDescription ?? "unknown"
            log.error("\(errCount, privacy: .public) audio buffer write(s) failed. First: \(firstMessage, privacy: .public)")
            if errCount > 25 {
                ToastCenter.shared.show(
                    "Audio archive may be incomplete — \(errCount) write errors.",
                    style: .warning
                )
            }
        }

        if archivedParts.count > 1 {
            let names = archivedParts.map(\.lastPathComponent).joined(separator: ", ")
            log.warning("Recording split across \(self.archivedParts.count, privacy: .public) parts due to format change(s): \(names, privacy: .public)")
            ToastCenter.shared.show(
                "Recording saved as \(archivedParts.count) parts — mic format changed mid-session.",
                style: .info
            )
        }
    }

    /// Stop archiving to disk but keep the callback + transcription
    /// running (low-disk → transcript-only). Audio written so far is
    /// kept and finalized at `stop()`. Identical contract to
    /// AudioRecorder.stopArchivingKeepTranscribing().
    func stopArchivingKeepTranscribing() {
        archiveGate.set(false)
        log.warning("Mic archiving stopped (low disk) — transcription continues, no further audio written")
    }

    func reset() {
        if state == .recording || state == .paused { stop() }
        state = .idle
        elapsed = 0
        accumulatedActiveSec = 0
        startedAt = nil
        levelDB = -160
        archivedFileURL = nil
        lastError = nil
    }

    // MARK: - Unit creation + configuration

    /// Create a `kAudioUnitSubType_HALOutput` AudioUnit, enable input
    /// (element 1), disable output (element 0), pin it to `deviceID`,
    /// read the device's REAL input ASBD, set our float32 client format
    /// on the output scope of element 1, install the input callback, and
    /// initialize. Stores `clientFormat`. Throws on any hard failure.
    ///
    /// NB element/scope convention for an AUHAL configured as input:
    ///   • element (bus) 1 = INPUT (the mic side)
    ///   • element (bus) 0 = OUTPUT (the speaker side — disabled here)
    ///   • the captured audio is read from the OUTPUT scope of element 1
    ///     (the data "flows out of" the input element toward us).
    private func makeAndConfigureUnit(deviceID: AudioDeviceID) throws -> AudioComponentInstance {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw DaisyError.audioEngineFailed("HAL output AudioComponent not found")
        }
        var unitOptional: AudioComponentInstance?
        var status = AudioComponentInstanceNew(comp, &unitOptional)
        guard status == noErr, let unit = unitOptional else {
            throw DaisyError.audioEngineFailed("AudioComponentInstanceNew failed (status \(status))")
        }

        // From here on, dispose the unit if anything throws.
        func fail(_ message: String) -> DaisyError {
            AudioComponentInstanceDispose(unit)
            return DaisyError.audioEngineFailed(message)
        }

        // 1. Enable INPUT on element 1.
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            Self.inputElement,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else { throw fail("EnableIO(input, element 1) failed (status \(status))") }

        // 2. Disable OUTPUT on element 0 — we only capture.
        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            Self.outputElement,
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else { throw fail("EnableIO(output, element 0) disable failed (status \(status))") }

        // 3. Pin the unit to the resolved device. This MUST happen after
        //    EnableIO and before reading the input format — the format
        //    we read back is the format of THIS device.
        var mutableDeviceID = deviceID
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw fail("Set CurrentDevice failed (status \(status), device \(deviceID))") }

        // 4. Read the device's REAL input stream format from the unit's
        //    INPUT scope of element 1 — this is the hardware format the
        //    AUHAL will actually deliver. (We could read it off the
        //    device via AudioInputDevices.streamFormatSampleRate, but the
        //    unit's own input-scope ASBD is the authoritative thing the
        //    render side will hand us — channel count included.)
        var hwFormat = AudioStreamBasicDescription()
        var hwSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            Self.inputElement,
            &hwFormat,
            &hwSize
        )
        guard status == noErr, hwFormat.mSampleRate > 0 else {
            throw fail("Read input StreamFormat failed (status \(status), rate \(hwFormat.mSampleRate))")
        }

        // Cross-check against CoreAudio's direct device read. On the
        // hardware this class exists for, these AGREE (that's the whole
        // point — CoreAudio reports the truth). If they disagree, trust
        // the device's input-scope rate (CoreAudio's truth) and log it;
        // we don't crash. We rebuild our client ASBD from the real rate
        // regardless.
        let realRate: Double
        if let deviceRate = AudioInputDevices.streamFormatSampleRate(for: deviceID),
           abs(deviceRate - hwFormat.mSampleRate) > 0.5 {
            log.warning("Unit input rate \(hwFormat.mSampleRate, privacy: .public) Hz disagrees with device input-scope \(deviceRate, privacy: .public) Hz. Using device rate.")
            log.warning("Rate diag: \(AudioInputDevices.streamRateDiagnostics(for: deviceID), privacy: .public)")
            realRate = deviceRate
        } else {
            realRate = hwFormat.mSampleRate
        }

        // Preserve the device's channel count (built-in mic is mono;
        // some interfaces are stereo). ZERO input channels is NOT a
        // clamp case — it means we bound something that can't record
        // (output-only device, virtual driver, an asleep Continuity
        // mic). The old `max(1, …)` invented a mono format, initialized
        // happily and then delivered digital silence forever, and the
        // start log printed the INVENTED format so the report looked
        // like a healthy mono mic (2026-07-26 field bug).
        guard hwFormat.mChannelsPerFrame > 0 else {
            log.error("Input device reports ZERO input channels — refusing to capture silence. \(AudioInputDevices.describe(deviceID), privacy: .public)")
            throw fail("Input device has no input channels")
        }
        let channels = hwFormat.mChannelsPerFrame

        // 5. Build our CLIENT format: float32, non-interleaved (planar),
        //    at the real rate, matching channel count. Non-interleaved
        //    Float32 is exactly what AVAudioPCMBuffer/SpectrumAnalyzer/
        //    AudioConverter expect (floatChannelData[ch]).
        guard let client = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: realRate,
            channels: channels,
            interleaved: false
        ) else {
            throw fail("Couldn't build client AVAudioFormat (rate \(realRate), ch \(channels))")
        }
        clientFormat = client

        // Apply the client ASBD to the OUTPUT scope of element 1 — the
        // scope we read captured audio from. The AUHAL converts the
        // device's native format to this for us internally (this is the
        // ONE conversion we explicitly own and control, vs AVAudioEngine's
        // hidden shared-AUHAL SRC that gets stuck).
        var clientASBD = client.streamDescription.pointee
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            Self.inputElement,
            &clientASBD,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else { throw fail("Set client StreamFormat (output scope, element 1) failed (status \(status))") }

        // NB the input render callback and `AudioUnitInitialize` are NOT
        // done here. The canonical AUHAL recipe (Apple TN2091,
        // TheAmazingAudioEngine, keijiro/AudioJackPlugin) sets
        // `kAudioOutputUnitProperty_SetInputCallback` BEFORE
        // `AudioUnitInitialize`, and our callback needs the per-(re)start
        // `RenderContext` box (which captures the AVAudioFile +
        // continuation). So the caller does, in order:
        //   makeAndConfigureUnit → installRenderContext (sets callback)
        //   → initializeUnit → AudioOutputUnitStart.
        // The unit returned here is configured + format-locked but NOT
        // yet initialized.
        return unit
    }

    /// `AudioUnitInitialize` the configured unit. Split out of
    /// `makeAndConfigureUnit` so it runs AFTER the input callback is
    /// installed (canonical ordering — see the note in
    /// `makeAndConfigureUnit`). Disposes the unit on failure and throws.
    private func initializeUnit(_ unit: AudioComponentInstance) throws {
        let status = AudioUnitInitialize(unit)
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw DaisyError.audioEngineFailed("AudioUnitInitialize failed (status \(status))")
        }
    }

    // MARK: - Render context (refcon box) + callback wiring

    /// Strongly-held render context. The C callback receives an
    /// unretained pointer to this; it is created here and released only
    /// after the unit is disposed (in `disposeUnit`), so the pointer the
    /// callback holds is always valid while the callback can fire.
    @ObservationIgnored
    private var renderContext: RenderContext?

    /// Build the `RenderContext` the render callback reads, point the
    /// AUHAL's input callback at it, and stash the AudioUnit handle
    /// inside it (the callback needs the unit to call AudioUnitRender).
    private func installRenderContext(format: AVAudioFormat) {
        guard let unit = audioUnit else { return }

        // Fresh grace window so the silence monitor doesn't trip during
        // the brief no-buffer transition after (re)install — same as
        // AudioRecorder.installInputTap.
        micLiveness.reset(to: Date())

        let ctx = RenderContext(
            audioUnit: unit,
            format: format,
            continuation: bufferContinuation,
            audioFile: audioFile,
            analyzer: analyzer,
            writeErrors: writeErrors,
            framesWritten: framesWritten,
            bufferTimestamp: bufferTimestamp,
            micLiveness: micLiveness,
            archiveGate: archiveGate,
            levelSpectrum: levelSpectrum,
            noiseSuppressionEnabled: activeNoiseSuppressionEnabled
        )
        renderContext = ctx

        // Unretained pointer — RenderContext outlives the unit by
        // construction (disposeUnit removes the callback before nil-ing
        // the box).
        let refcon = Unmanaged.passUnretained(ctx).toOpaque()
        // Literal NON-CAPTURING closure for the C render callback. A
        // top-level `func` can't be used here when the module defaults to
        // MainActor isolation (the func becomes implicitly @MainActor and a
        // @convention(c) pointer can't be formed from an isolated func —
        // "A C function pointer can only be formed from a reference to a
        // 'func' or a literal closure"). A literal closure that captures
        // nothing IS @convention(c)-formable; the RenderContext travels via
        // the refcon and is recovered with Unmanaged.
        var callbackStruct = AURenderCallbackStruct(
            inputProc: { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
                let ctx = Unmanaged<RenderContext>.fromOpaque(inRefCon).takeUnretainedValue()
                return ctx.process(
                    ioActionFlags: ioActionFlags,
                    inTimeStamp: inTimeStamp,
                    inBusNumber: inBusNumber,
                    inNumberFrames: inNumberFrames
                )
            },
            inputProcRefCon: refcon
        )
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        if status != noErr {
            log.error("SetInputCallback failed (status \(status, privacy: .public))")
        }
    }

    /// Stop + uninitialize + dispose the unit and clear the render
    /// context. Order matters: tear down the callback path FIRST (stop +
    /// uninitialize) so no callback can be in-flight, THEN release the
    /// refcon box.
    private func disposeUnit() {
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        audioUnit = nil
        // The unit (and its render callback) is now stopped + uninitialized
        // + disposed, so the RT thread can no longer fire `process(...)` and
        // therefore cannot enqueue any new work. Drain the serial queue so
        // every buffer that DID get enqueued before the stop is fully
        // written (frames counted) and yielded BEFORE we drop the context's
        // strong reference to the `AVAudioFile`. This is the choke point that
        // guarantees:
        //   • no lost tail — the last enqueued writes run during flush();
        //   • no write-after-close — the file ref is dropped only after the
        //     drain, and no block can run after the context is released;
        //   • on rebuildUnit's part-roll, the OLD part's tail lands before
        //     its file ref is dropped and the new part is opened.
        // Safe (no deadlock): teardown is on the MainActor, flush() is a
        // `sync` barrier, and nothing running ON the queue ever waits on it.
        renderContext?.flush()
        // Safe to release the box now — the unit (and its callback) is
        // gone and the queue is drained, so nothing holds the pointer.
        renderContext = nil
    }

    // MARK: - Device resolution + binding

    /// One "your pinned mic is missing" warning per app run — the device
    /// stays disconnected across back-to-back meetings, and repeating
    /// the warning each time trains the person to ignore it.
    private static var warnedAboutMissingPinnedMic = false

    /// Resolve `uid` to a concrete `AudioDeviceID`. Three paths, same as
    /// AudioRecorder.applyPreferredInputDevice:
    ///   1. User pinned a device that's connected → use it.
    ///   2. User pinned but it's gone → fall back to system default.
    ///   3. User picked "System default" → current default.
    /// Returns 0 if no input device exists at all (caller throws
    /// `.noMicrophone`).
    private func resolveInputDeviceID(uid: String) -> AudioDeviceID {
        if !uid.isEmpty, let pinned = AudioInputDevices.deviceID(forUID: uid) {
            return pinned
        }
        if !uid.isEmpty {
            log.warning("Saved mic UID \(uid, privacy: .public) not connected — falling back to system default")
            // Say it, don't just log it. The person deliberately pinned
            // a microphone; recording the whole meeting through the
            // built-in one instead is the kind of thing you want to know
            // at the start, not when you play the file back. Nothing
            // on screen named the actual device during a recording, and
            // Settings only shows "not connected" if you go looking
            // (audit 2026-09-01).
            //
            // Once per launch: the pinned device stays disconnected
            // across back-to-back meetings, and repeating this every
            // time would train the person to ignore it.
            if !Self.warnedAboutMissingPinnedMic {
                Self.warnedAboutMissingPinnedMic = true
                // `name(for:)`, not `describe(_:)` — the latter is a log
                // line ("device 63 'MacBook Pro Microphone' uid=… …").
                let fallbackName = AudioInputDevices.name(
                    for: AudioInputDevices.systemDefaultInputID()
                ) ?? String(localized: "the default microphone")
                let message = String(
                    localized: "Your chosen microphone isn't connected — recording from \(fallbackName) instead."
                )
                // Bubble first: recording starts from a hotkey, the
                // widget or a calendar auto-start, and a toast lives
                // inside a window that isn't open then. `present`
                // falls back to a notification when the widget is
                // hidden, so the message lands either way.
                WidgetBubbleCenter.shared.present(
                    WidgetBubbleContent(
                        text: message,
                        actionTitle: String(localized: "Choose microphone"),
                        tag: "mic-not-connected",
                        action: {
                            AppNavigation.shared.pendingSettingsTab = .recording
                            AppNavigation.shared.section = .settings
                            WidgetBubbleCenter.shared.openMainWindow?()
                        }
                    ),
                    notificationTitle: String(localized: "Recording from a different microphone")
                )
                ToastCenter.shared.show(message, style: .warning, duration: .seconds(10))
            }
        }
        // Unpinned: take the system default — UNLESS it's a Bluetooth mic,
        // in which case prefer a non-BT input. A BT headset used for OUTPUT
        // (the call / a video) drags the default INPUT onto its SCO mic,
        // which delivers pure silence while the headset is playing audio
        // (A2DP↔SCO conflict) → the mic silence watchdog then pauses the
        // recording and the user's speech is lost. This is the same trap
        // the route-change guard avoids mid-session, now avoided at START
        // too. A pinned BT device is still honoured above (explicit choice).
        let defaultID = AudioInputDevices.systemDefaultInputID()
        // Clamshell (lid closed, external display + keyboard): the Mac's
        // built-in mic is HARDWARE-disconnected with the lid, yet stays
        // in the device list and streams bit-exact zeros forever
        // (2026-07-26 field bug). It must therefore never win ANY
        // fallback below — including the Bluetooth one, whose
        // `firstNonBluetoothInputID` deliberately PREFERS the built-in.
        let lidClosed = AudioInputDevices.isLidClosed()
        if lidClosed, defaultID != 0, AudioInputDevices.isBuiltIn(defaultID),
           let external = AudioInputDevices.firstExternalWiredInputID() {
            log.warning("Lid is closed — the built-in mic records silence in clamshell. Switching to \(AudioInputDevices.describe(external), privacy: .public)")
            return external
        }

        // Unpinned: take the system default — UNLESS it's a Bluetooth mic,
        // in which case prefer a non-BT input. A BT headset used for OUTPUT
        // (the call / a video) drags the default INPUT onto its SCO mic,
        // which delivers pure silence while the headset is playing audio
        // (A2DP↔SCO conflict) → the mic silence watchdog then pauses the
        // recording and the user's speech is lost. This is the same trap
        // the route-change guard avoids mid-session, now avoided at START
        // too. A pinned BT device is still honoured above (explicit choice).
        if defaultID != 0, AudioInputDevices.isBluetooth(defaultID) {
            // With the lid shut the non-BT preference would land on the
            // silent built-in mic — a real external input beats both.
            if lidClosed, let external = AudioInputDevices.firstExternalWiredInputID() {
                log.warning("Default input is Bluetooth and the lid is closed — capturing from \(AudioInputDevices.describe(external), privacy: .public)")
                return external
            }
            // Lid open: the built-in mic is the better SCO-avoiding
            // choice. Lid closed with no external input: keep the BT mic
            // (it actually records) rather than the muted built-in.
            if !lidClosed, let nonBT = AudioInputDevices.firstNonBluetoothInputID() {
                log.info("Default input is Bluetooth — capturing from non-BT input \(AudioInputDevices.describe(nonBT), privacy: .public) to avoid SCO-mic silence")
                return nonBT
            }
        }

        // The system default is not guaranteed to be able to record:
        // a virtual driver, an aggregate with no live input, or an
        // asleep Continuity mic can hold the default slot and deliver
        // digital silence. The pinned path already requires real input
        // streams (deviceID(forUID:)); the default path never did
        // (2026-07-26).
        if defaultID != 0, !AudioInputDevices.hasInputStreams(defaultID) {
            let fallback = lidClosed
                ? AudioInputDevices.firstExternalWiredInputID()
                : AudioInputDevices.firstNonBluetoothInputID()
            if let fallback {
                log.warning("System default input has NO input streams — falling back. Default: \(AudioInputDevices.describe(defaultID), privacy: .public). Using: \(AudioInputDevices.describe(fallback), privacy: .public)")
                return fallback
            }
            log.error("System default input has NO input streams and no alternative exists: \(AudioInputDevices.describe(defaultID), privacy: .public)")
        }
        return defaultID
    }

    // MARK: - Route-change recovery

    /// Tear down the current unit and build a fresh one bound to
    /// `deviceID`, re-reading its real format and rolling the archive
    /// into a new `.partN.caf` if the format differs from what we were
    /// writing. The CoreAudio analogue of AudioRecorder's
    /// `rebuildEngineAndRetry` + the format-roll logic — but far simpler
    /// because there's no hidden cached format to fight: we re-read the
    /// truth from CoreAudio every time. Used by `resume()` and by the
    /// route-change path. Throws on hard failure (caller decides whether
    /// to fall to paused).
    private func rebuildUnit(on deviceID: AudioDeviceID, reason: String) throws {
        // Capture the format we were writing at, to detect a change.
        let oldFormat = clientFormat

        // Remove the device-format listener for the OLD device; we'll
        // reinstall for the new one after configuring.
        removeDeviceFormatListener()

        // Dispose the old unit (stops the callback, releases the refcon).
        disposeUnit()

        // Build + configure the new unit (reads the new real format into
        // `clientFormat`).
        let unit = try makeAndConfigureUnit(deviceID: deviceID)
        audioUnit = unit
        boundDeviceID = deviceID
        lastBoundInputUID = AudioInputDevices.uid(for: deviceID) ?? lastBoundInputUID

        guard let newFormat = clientFormat, newFormat.channelCount > 0 else {
            disposeUnit()
            throw DaisyError.noMicrophone
        }

        // Roll the archive if the format changed — AVAudioFile can't
        // accept frames in a format different from the one it was opened
        // with, so the alternative is silent data loss (the exact bug
        // AudioRecorder's part logic exists to prevent).
        let formatChanged = !(oldFormat.map { Self.formatsAreEqual($0, newFormat) } ?? false)
        if formatChanged, let baseURL = archivedFileURL {
            audioFile = nil
            partCounter += 1
            let newPartURL = Self.makePartURL(base: baseURL, part: partCounter)
            do {
                audioFile = try AVAudioFile(forWriting: newPartURL, settings: newFormat.settings)
                archivedParts.append(newPartURL)
                let oldRate = oldFormat?.sampleRate ?? 0
                log.warning("[\(reason, privacy: .public)] format changed (\(oldRate, privacy: .public) Hz → \(newFormat.sampleRate, privacy: .public) Hz). Archive rolled to \(newPartURL.lastPathComponent, privacy: .public).")
            } catch {
                log.error("[\(reason, privacy: .public)] failed to open part \(self.partCounter, privacy: .public): \(error.localizedDescription, privacy: .public). Continuing without archive for this part.")
                audioFile = nil
            }
        }

        // Wire the render context (sets callback) against the new unit +
        // (possibly new) file, initialize, reinstall the device-format
        // listener, and start.
        installRenderContext(format: newFormat)
        do {
            try initializeUnit(unit)
        } catch {
            audioUnit = nil
            renderContext = nil
            throw error
        }
        installDeviceFormatListener(for: deviceID)

        let startStatus = AudioOutputUnitStart(unit)
        guard startStatus == noErr else {
            throw DaisyError.audioEngineFailed("AudioOutputUnitStart failed on \(reason) (status \(startStatus))")
        }
    }

    /// Deterministic route-change handler. macOS changed the default
    /// input device, or the bound device renegotiated its format. Re-
    /// resolve the device, rebuild the unit against the truth, roll a
    /// part if needed. Debounced (macOS fires these 2–3×). Not invoked
    /// while paused/stopped.
    private func handleRouteChange(trigger: String) {
        guard state == .recording else {
            log.info("Route change ignored (state=\(String(describing: self.state), privacy: .public), trigger=\(trigger, privacy: .public))")
            return
        }
        if let last = lastReconfigureAt, Date().timeIntervalSince(last) < 2.0 {
            log.info("Route change debounced — last reconfigure \(Date().timeIntervalSince(last), privacy: .public)s ago (trigger=\(trigger, privacy: .public))")
            return
        }
        lastReconfigureAt = Date()
        log.warning("Mic route change (\(trigger, privacy: .public)) — reconfiguring deterministically")

        // Decide which device to bind. Same Bluetooth-hijack guard as
        // AudioRecorder: an UNPINNED session whose new default input is
        // Bluetooth keeps the device we were on (AirPods-for-output drags
        // the default input onto their SCO mic, which often delivers
        // silence). A pinned mic always follows its UID; a wired/USB
        // change is intended, so follow it.
        let newDefaultID = AudioInputDevices.systemDefaultInputID()
        let newDefaultIsBluetooth = newDefaultID != 0 && AudioInputDevices.isBluetooth(newDefaultID)

        let targetID: AudioDeviceID
        if activePreferredDeviceUID.isEmpty,
           newDefaultIsBluetooth,
           let keepUID = lastBoundInputUID,
           let keepID = AudioInputDevices.deviceID(forUID: keepUID) {
            log.info("Route change, no pinned mic — new default is Bluetooth; keeping current device (UID \(keepUID, privacy: .public), id \(keepID, privacy: .public)) to avoid a BT-output hijack.")
            targetID = keepID
        } else {
            targetID = resolveInputDeviceID(uid: activePreferredDeviceUID)
        }

        guard targetID != 0 else {
            log.error("Route change — no usable input device. Falling to paused.")
            fallToPaused(reason: .noInputDevice)
            // Only when nobody is listening: a session wired to
            // `onFellToPaused` says this itself, with a bubble that
            // survives a closed window, and two messages about one
            // event read as two problems (review find, 2026-09-02).
            if onFellToPaused == nil {
                ToastCenter.shared.show(
                    String(localized: "Mic disconnected — recording paused. Connect a mic and hit Resume."),
                    style: .warning
                )
            }
            return
        }

        do {
            try rebuildUnit(on: targetID, reason: "route-change")
            log.info("Route-change recovery succeeded — recording continues on device \(targetID, privacy: .public)")
            let body = archivedParts.count > 1
                ? "Mic device changed — recording continues in a new file (\(archivedParts.count) parts so far)."
                : "Mic device changed — recording continues."
            ToastCenter.shared.show(body, style: .info)
            // Unit can report started while the device delivers nothing.
            // Watchdog falls us to paused if no buffer arrives within 5s.
            armRecoveryWatchdog()
        } catch {
            log.error("Route-change rebuild failed: \(error.localizedDescription, privacy: .public). Falling to paused.")
            fallToPaused(reason: .rebuildFailed)
            if onFellToPaused == nil {
                ToastCenter.shared.show(
                    String(localized: "Mic changed — recording paused. Hit Resume to continue."),
                    style: .warning
                )
            }
        }
    }

    /// Called when the recorder has dropped itself to `.paused` — the
    /// watchdogs and the route-change rebuild can all decide, on their
    /// own, that capture has to stop.
    ///
    /// Without this the decision stayed inside the recorder: nobody
    /// reads `recorder.state`, so `RecordingSession.status` remained
    /// `.recording` and the widget went on showing a live recording with
    /// a frozen timer, while the rest of the meeting wasn't captured at
    /// all. The only signal was a toast, which during a meeting has no
    /// window to appear in (audit 2026-09-01).
    @ObservationIgnored
    var onFellToPaused: (@MainActor (MicPauseReason) -> Void)?

    /// Centralised "drop to paused" — preserves `accumulatedActiveSec`,
    /// clears the level/spectrum, stops the unit. Mirrors
    /// AudioRecorder.fallToPaused().
    ///
    /// `reason` tells the session what to say — or, for the silence
    /// watchdog, that the recorder has already said it. The recorder
    /// doesn't write UI copy; it reports what happened.
    private func fallToPaused(reason: MicPauseReason) {
        cancelRecoveryWatchdog()
        stopSilenceMonitor()
        lastReconfigureAt = nil  // let a follow-up recover immediately
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
        }
        // Unit stopped ⇒ no new RT enqueues. Drain the in-flight tail so
        // the buffers captured before the fault are written + counted and
        // no queued block races the MainActor state reset below. (The file
        // stays open; a subsequent resume rebuilds and keeps appending.)
        renderContext?.flush()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        stopDisplayTimer()
        levelSpectrum.reset()
        if let startedAt {
            accumulatedActiveSec += Date().timeIntervalSince(startedAt)
        }
        startedAt = nil
        levelDB = -160
        spectrumBands = Array(repeating: 0, count: SpectrumAnalyzer.bandCount)
        state = .paused
        onFellToPaused?(reason)
    }

    // MARK: - CoreAudio listeners

    /// `kAudioHardwarePropertyDefaultInputDevice` listener — catches the
    /// system default flipping (AirPods connect, USB plug/unplug, user
    /// re-routes input in Control Centre).
    private func installDefaultInputListener() {
        guard !defaultInputListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleRouteChange(trigger: "default-input")
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated),
            block
        )
        if status == noErr {
            defaultInputListenerBlock = block
            defaultInputListenerInstalled = true
            log.info("Default input device listener installed")
        } else {
            log.error("Failed to install default input listener: status=\(status, privacy: .public)")
        }
    }

    private func removeDefaultInputListener() {
        guard defaultInputListenerInstalled, let block = defaultInputListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated),
            block
        )
        defaultInputListenerBlock = nil
        defaultInputListenerInstalled = false
    }

    /// Listener on the BOUND device's input-scope stream format. Catches
    /// an in-place sample-rate flip on the device we're recording (the
    /// device renegotiates 44.1↔48 kHz without the default selector
    /// changing). AVAudioEngine handled this case via its own
    /// ConfigurationChange; here it's on us.
    private func installDeviceFormatListener(for deviceID: AudioDeviceID) {
        removeDeviceFormatListener()
        guard deviceID != 0 else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleRouteChange(trigger: "device-format")
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            DispatchQueue.global(qos: .userInitiated),
            block
        )
        if status == noErr {
            deviceFormatListenerBlock = block
            deviceFormatListenerDeviceID = deviceID
            log.info("Device-format listener installed for device \(deviceID, privacy: .public)")
        } else {
            log.error("Failed to install device-format listener for \(deviceID, privacy: .public): status=\(status, privacy: .public)")
        }
    }

    private func removeDeviceFormatListener() {
        guard let block = deviceFormatListenerBlock, let deviceID = deviceFormatListenerDeviceID else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.global(qos: .userInitiated), block)
        deviceFormatListenerBlock = nil
        deviceFormatListenerDeviceID = nil
    }

    // MARK: - Recovery watchdog (arrival)

    /// Arm a one-shot timer that checks `bufferTimestamp` after start /
    /// recovery. No buffer strictly after the arm time ⇒ the device is
    /// delivering nothing. At INITIAL start (`escalateToReconfigure`) we
    /// re-resolve + rebuild once before giving up; otherwise we fall to
    /// paused. Generation guard makes a stale fired timer a no-op under
    /// route flapping. Mirrors AudioRecorder.armRecoveryWatchdog.
    private func armRecoveryWatchdog(deadline: TimeInterval = 5.0, escalateToReconfigure: Bool = false) {
        cancelRecoveryWatchdog()
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        let armedAt = Date()
        recoveryWatchdog = Timer.scheduledTimer(withTimeInterval: deadline, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkRecoveryProgress(armedAt: armedAt, generation: generation, escalateToReconfigure: escalateToReconfigure)
            }
        }
    }

    private func cancelRecoveryWatchdog() {
        recoveryWatchdog?.invalidate()
        recoveryWatchdog = nil
        recoveryGeneration &+= 1
    }

    private func checkRecoveryProgress(armedAt: Date, generation: Int, escalateToReconfigure: Bool) {
        guard generation == recoveryGeneration else {
            log.info("Stale recovery watchdog (gen \(generation, privacy: .public) ≠ \(self.recoveryGeneration, privacy: .public)) — ignoring.")
            return
        }
        recoveryWatchdog = nil
        guard state == .recording else { return }
        if let c = bufferTimestamp.snapshot(), c > armedAt { return }  // healthy

        // A stalled unit gets ONE rebuild before we give up — at start
        // (`escalateToReconfigure`) and, since 2026-08-10, mid-session
        // too. Mid-session stalls are the same failure Handy fixed by
        // restarting a dead capture worker (cjpais/Handy#1838): the
        // device is fine, the unit's render callback just stopped being
        // called (sleep/wake, USB hub hiccup, CoreAudio restarting
        // under us). Falling straight to paused made that a silent
        // half-recording the user discovered afterwards; a rebuild
        // usually just works, and when it doesn't the second watchdog
        // pauses exactly as before. `midSessionRebuilds` bounds it so a
        // genuinely dead device can't spin. The budget is deliberately
        // NOT refunded when audio resumes: a flapping device (delivers
        // briefly, stalls, repeats) would otherwise rebuild forever.
        // A recording is bounded; 2 recoveries inside one is generous.
        // …and only for a unit that HAD been delivering: if not a single
        // buffer ever arrived, retrying twice more just triples the time
        // the UI lies about recording (~20 s instead of ~10 s) before we
        // admit the mic is dead. That case is what the start-time
        // escalation already covers.
        let everDelivered = bufferTimestamp.snapshot() != nil
        let canRebuildMidSession = everDelivered && midSessionRebuilds < Self.maxMidSessionRebuilds
        if escalateToReconfigure || canRebuildMidSession {
            if escalateToReconfigure {
                log.error("Recovery watchdog fired at start — no buffers post-arm. Rebuilding before pausing.")
            } else {
                midSessionRebuilds += 1
                log.error("Recovery watchdog fired mid-session — no buffers post-arm. Rebuild \(self.midSessionRebuilds, privacy: .public)/\(Self.maxMidSessionRebuilds, privacy: .public) before pausing.")
            }
            // Device choice: mid-session we re-bind to the device we
            // were ALREADY on rather than re-resolving the default.
            // `resolveInputDeviceID` deliberately prefers the built-in
            // when unpinned, so a stall that happens to coincide with
            // AirPods connecting would silently move the recording off
            // the user's USB mic — the same Bluetooth-hijack the route-
            // change handler guards against. A start-time rebuild has no
            // prior binding, so it resolves as before.
            var deviceID: AudioDeviceID = 0
            if !escalateToReconfigure,
               let keepUID = lastBoundInputUID,
               let keepID = AudioInputDevices.deviceID(forUID: keepUID) {
                deviceID = keepID
            } else {
                deviceID = resolveInputDeviceID(uid: activePreferredDeviceUID)
            }
            if deviceID != 0 {
                do {
                    try rebuildUnit(on: deviceID, reason: escalateToReconfigure ? "watchdog-start" : "watchdog-midsession")
                    armRecoveryWatchdog()  // non-escalating; failure past the budget falls to paused
                    return
                } catch {
                    log.error("Watchdog rebuild failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            log.error("Recovery watchdog fired — no audio buffers post-arm (everDelivered=\(everDelivered, privacy: .public), rebuilds=\(self.midSessionRebuilds, privacy: .public)). Falling to paused.")
        }
        fallToPaused(reason: .noBuffers)
        if onFellToPaused == nil {
            ToastCenter.shared.show(
                String(localized: "Mic stopped delivering audio — recording paused. Hit Resume to retry."),
                style: .warning
            )
        }
    }

    // MARK: - Mic silence watchdog (signal level, not arrival)

    private func startSilenceMonitor() {
        stopSilenceMonitor()
        micLiveness.reset(to: Date())
        silenceMonitor = Timer.scheduledTimer(
            withTimeInterval: Self.silenceMonitorIntervalSec, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkMicSilence() }
        }
    }

    private func stopSilenceMonitor() {
        silenceMonitor?.invalidate()
        silenceMonitor = nil
    }

    /// Signal-level dead-input check. If mic RMS has stayed below the
    /// liveness floor for `micSilenceWindowSec` (zero excursions above),
    /// the input is delivering silence — BT-SCO, hardware mute, dead
    /// device — so pause and tell the user. Identical to AudioRecorder.
    private func checkMicSilence() {
        guard state == .recording else { return }
        let snap = micLiveness.snapshot()
        guard let reference = snap.aboveFloorAt else { return }
        let silentFor = Date().timeIntervalSince(reference)
        guard silentFor >= Self.micSilenceWindowSec else { return }
        // Bit-exact digital silence vs a genuinely quiet input: if
        // (almost) every buffer was all zeros, no microphone on earth
        // produced this — macOS is handing us silence (2026-07-26).
        // Different cause ⇒ different message ⇒ different fix.
        let digitalSilence = snap.total > 0 && snap.allZero * 10 >= snap.total * 9
        log.error("Mic silence watchdog fired — RMS below \(Self.micLivenessFloorDB, privacy: .public) dBFS for \(Int(silentFor), privacy: .public)s (last RMS \(snap.lastRMS, privacy: .public) dBFS, all-zero samples \(snap.allZero, privacy: .public)/\(snap.total, privacy: .public) ticks, digitalSilence=\(digitalSilence, privacy: .public), micPermission=\(SystemPermissions.micAuthorizationDescription(), privacy: .public)). Device: \(AudioInputDevices.describe(self.boundDeviceID ?? 0), privacy: .public). Falling to paused.")
        fallToPaused(reason: .silenceAlreadyAnnounced)
        if digitalSilence {
            // Name the specific cause when we can prove it. Lid closed
            // + built-in mic is THE common one on a desk-docked laptop
            // (Egor, 2026-07-26) and has nothing to do with permissions.
            let lidClosed = AudioInputDevices.isLidClosed()
                && AudioInputDevices.isBuiltIn(boundDeviceID ?? 0)
            if lidClosed {
                // start() may have already said this — don't stack a
                // second identical toast (the banner de-dupes itself
                // via its shared request id).
                if RecordingSession.current?.clamshellWarned != true {
                    CaptureProblemNotification.post(
                        title: String(localized: "Daisy can’t hear you"),
                        body: String(localized: "The lid is closed, so the Mac’s built-in microphone is off. Open the lid or connect an external mic.")
                    )
                    ToastCenter.shared.show(
                        String(localized: "The lid is closed — the built-in microphone is off in clamshell mode. Open the lid or connect an external mic."),
                        style: .warning
                    )
                }
            } else {
                CaptureProblemNotification.post(
                    title: String(localized: "Daisy can’t hear you"),
                    body: String(localized: "No sound is reaching Daisy from the microphone. Nothing is being recorded.")
                )
                ToastCenter.shared.showAction(
                    String(localized: "macOS is sending Daisy an empty microphone signal — nothing is being recorded. Check Privacy & Security → Microphone, and that the input isn’t muted in Sound settings."),
                    actionLabel: String(localized: "Open Microphone settings"),
                    style: .warning,
                    duration: .seconds(30)
                ) {
                    SystemPermissions.shared.openMicrophoneSettings()
                }
            }
        } else {
            ToastCenter.shared.show(
                String(localized: "Mic went silent — recording paused. Check your mic (Bluetooth mics often record silence) and hit Resume."),
                style: .warning
            )
        }
    }

    // MARK: - Helpers

    private func tick() {
        guard let startedAt else { return }
        elapsed = accumulatedActiveSec + Date().timeIntervalSince(startedAt)
    }

    // MARK: - Display pump (render-thread level/spectrum → Observable)

    /// Arm the MainActor display-cadence timer that pulls the latest
    /// level + spectrum out of `levelSpectrum` and publishes it to the
    /// Observable `levelDB` / `spectrumBands`. Runs at the same ~30 Hz
    /// cadence the render thread fills the box (and the widget's
    /// TimelineView consumes it). Idempotent. See `spectrumBands`'
    /// doc-comment for why we pull on a run-loop timer instead of
    /// pushing a `Task { @MainActor }` per render buffer.
    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(
            withTimeInterval: Self.spectrumPublishIntervalSec, repeats: true
        ) { [weak self] _ in
            // The timer is scheduled on the MAIN run loop (startDisplayTimer
            // is @MainActor) ⇒ this block fires on the main thread. Run the
            // pump SYNCHRONOUSLY via assumeIsolated. Do NOT hop through
            // `Task { @MainActor }`: that re-queues onto the cooperative
            // executor, which live large-v3 transcription (4× fallback)
            // saturates — so the pump starved and the petals stayed frozen
            // even after c2b9b2b moved it onto a 30 Hz timer (the timer
            // changed the cadence but not the starving locus). The run-loop
            // timer source IS serviced even while the cooperative queue is
            // backed up — same footing as the widget's TimelineView redraw,
            // which keeps rendering — so the pump now actually lands.
            MainActor.assumeIsolated { self?.pumpDisplay() }
        }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    /// Copy the most recent render-thread level + spectrum sample into
    /// the Observable surface. No-op once we're no longer recording so a
    /// final in-flight tick can't repaint a stopped/paused widget (pause/
    /// stop/fallToPaused already zero the values + reset the box).
    private func pumpDisplay() {
        guard state == .recording else { return }
        let snap = levelSpectrum.snapshot()
        levelDB = snap.level
        if let bands = snap.bands { spectrumBands = bands }
    }

    /// AUHAL input element == 1, output element == 0 (Apple convention).
    private static let inputElement: AudioUnitElement = 1
    private static let outputElement: AudioUnitElement = 0

    /// 33 ms = ~30 Hz cap on spectrum/level publishes — matches the
    /// widget's TimelineView and the displayTimer cadence. The per-buffer
    /// rate-limit clock now lives on `RenderContext` (instance-scoped, RT-
    /// thread-only) rather than a shared `static var`; this is just the
    /// interval constant, shared by the render gate and the display pump.
    fileprivate static let spectrumPublishIntervalSec: TimeInterval = 1.0 / 30.0

    /// Liveness floor / window — copied verbatim from AudioRecorder so
    /// both recorders trip the silence watchdog at the same thresholds.
    fileprivate static let micLivenessFloorDB: Float = -80
    private static let micSilenceWindowSec: TimeInterval = 10
    private static let silenceMonitorIntervalSec: TimeInterval = 2

    nonisolated private static func formatsAreEqual(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
            && a.isInterleaved == b.isInterleaved
    }

    /// `microphone.caf` → `microphone.part2.caf`. Identical to
    /// AudioRecorder.makePartURL so downstream part-aware wiring is
    /// format-compatible across the two recorders.
    nonisolated private static func makePartURL(base: URL, part: Int) -> URL {
        let ext = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        let dir = base.deletingLastPathComponent()
        return dir.appendingPathComponent("\(stem).part\(part).\(ext)")
    }
}

// MARK: - Render context (the box the C callback reads)

/// Everything the render callback needs, captured once at install time
/// so the hot path never touches MainActor-isolated `self`. Held by
/// `CoreAudioMicRecorder.renderContext`; an unretained pointer to it is
/// the AUHAL input-callback refcon.
///
/// `@unchecked Sendable`: the callback runs on a single CoreAudio render
/// thread, and the only mutable shared state lives behind the lock-boxes
/// (WriteErrorBox / FrameCountBox / TimestampBox / LivenessBox /
/// AtomicFlag). The `AVAudioFile` and `AsyncStream.Continuation` are the
/// same objects AudioRecorder ferries across the same boundary — written
/// only from the single render thread, never concurrently.
private final class RenderContext: @unchecked Sendable {
    let audioUnit: AudioComponentInstance
    let format: AVAudioFormat
    let continuation: AsyncStream<AudioChunk>.Continuation?
    let audioFile: AVAudioFile?
    let analyzer: SpectrumAnalyzer
    let writeErrors: WriteErrorBox
    let framesWritten: FrameCountBox
    let bufferTimestamp: TimestampBox
    let micLiveness: LivenessBox
    let archiveGate: AtomicFlag
    /// Render-thread → MainActor bridge for the live level + spectrum.
    /// The callback writes the latest rate-limited sample here; the
    /// recorder's MainActor `displayTimer` reads it. Replaces the old
    /// fire-and-forget `Task { @MainActor [weak owner] }` per buffer —
    /// see `process(...)` and `CoreAudioMicRecorder.spectrumBands`.
    let levelSpectrum: LevelSpectrumBox
    /// Conservative opt-in gate, evaluated on `workQueue` before the
    /// buffer is archived or handed to the transcriber.
    let noiseSuppressionEnabled: Bool

    /// Per-context rate-limit clock for the spectrum/level publish.
    /// Instance-scoped (NOT a type-wide static) so a fresh capture
    /// session always starts with an open gate and two recorders can
    /// never share/clobber each other's window.
    ///
    /// CONFINEMENT: read/written ONLY inside `handle(_:)`, which runs
    /// only on `workQueue`. Never touched from the RT thread or the
    /// MainActor, so a plain stored property under `@unchecked Sendable`
    /// is safe (the serial queue gives single-threaded access).
    private var lastSpectrumPublishRefTime: TimeInterval = 0

    /// Dedicated SERIAL queue that owns all the heavy, non-real-time
    /// work the RT render callback used to do inline: the `AVAudioFile`
    /// disk write, the FFT/peak/RMS analysis, the liveness/level publish,
    /// and the transcriber `continuation.yield`. The RT callback now only
    /// renders + copies into an owned buffer and hands it here via one
    /// `async`, so the AUHAL IOWorkLoop is no longer blocked on disk I/O
    /// or vDSP. SERIAL + FIFO ⇒ buffers are written/yielded in exact
    /// arrival order (no reordering, no lost-then-late writes).
    ///
    /// THREAD-CONFINEMENT: this queue is the *single* owner/writer of the
    /// non-thread-safe `audioFile`, `analyzer`, and
    /// `lastSpectrumPublishRefTime`. Nothing else touches them after
    /// install (the RT thread doesn't; the MainActor only drains via
    /// `flush()`, a `sync` barrier that cannot overlap an `async` block).
    /// Uncontended `userInitiated` so it tracks the RT cadence closely.
    private let workQueue = DispatchQueue(
        label: "app.essazanov.Daisy.coreaudio.write",
        qos: .userInitiated
    )

    init(
        audioUnit: AudioComponentInstance,
        format: AVAudioFormat,
        continuation: AsyncStream<AudioChunk>.Continuation?,
        audioFile: AVAudioFile?,
        analyzer: SpectrumAnalyzer,
        writeErrors: WriteErrorBox,
        framesWritten: FrameCountBox,
        bufferTimestamp: TimestampBox,
        micLiveness: LivenessBox,
        archiveGate: AtomicFlag,
        levelSpectrum: LevelSpectrumBox,
        noiseSuppressionEnabled: Bool
    ) {
        self.audioUnit = audioUnit
        self.format = format
        self.continuation = continuation
        self.audioFile = audioFile
        self.analyzer = analyzer
        self.writeErrors = writeErrors
        self.framesWritten = framesWritten
        self.bufferTimestamp = bufferTimestamp
        self.micLiveness = micLiveness
        self.archiveGate = archiveGate
        self.levelSpectrum = levelSpectrum
        self.noiseSuppressionEnabled = noiseSuppressionEnabled
    }

    /// THE REAL-TIME HOT PATH. Runs on the AUHAL hard real-time render
    /// thread. It now does ONLY the minimal real-time-critical work:
    ///   1. allocate an OWNED `AVAudioPCMBuffer`,
    ///   2. `AudioUnitRender` straight into that buffer's own storage,
    ///   3. atomically mark arrival (`bufferTimestamp`),
    ///   4. hand the buffer to the serial `workQueue` via ONE `async`,
    /// then returns. The disk write, the FFT/level analysis, and the
    /// transcriber `yield` all moved OFF this thread onto `workQueue`
    /// (see `handle(_:)`). No disk I/O, no vDSP, no lock fan-out, and no
    /// `AVAudioFile`/`analyzer` access here any more — which is what
    /// stops the `HALC_ProxyIOContext::IOWorkLoop: skipping cycle due to
    /// overload` log: the IOWorkLoop is no longer blocked inside the
    /// callback waiting on a `write(2)` or a 2048-pt FFT.
    func process(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {
        // Allocate a host buffer for this slice. AVAudioPCMBuffer's
        // backing storage is allocated here; this is the one unavoidable
        // per-callback allocation (AVAudioEngine's tap allocates one too,
        // internally). Float32 non-interleaved matches `format`.
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: inNumberFrames) else {
            return kAudio_ParamError
        }
        pcm.frameLength = inNumberFrames

        // Render directly into the PCM buffer's mutable AudioBufferList.
        // `mutableAudioBufferList` exposes the buffer's OWN channel
        // pointers; AudioUnitRender fills THEM in place. So `pcm` owns its
        // samples outright — it does NOT alias the AudioUnit's transient
        // buffer list (which is only valid for the duration of this
        // callback). That ownership is exactly what makes it sound to ship
        // `pcm` to another thread below.
        let abl = pcm.mutableAudioBufferList
        let renderStatus = AudioUnitRender(
            audioUnit,
            ioActionFlags,
            inTimeStamp,
            inBusNumber,
            inNumberFrames,
            abl
        )
        guard renderStatus == noErr else {
            // Don't ship a partial/garbage buffer; just report. A flood
            // of these would show up as silence → the silence watchdog
            // pauses the session.
            return renderStatus
        }

        // Atomic arrival mark — read by the MainActor recovery watchdog.
        // Kept INLINE (not on the queue) so the arrival watchdog measures
        // true device liveness even if the queue briefly backs up.
        bufferTimestamp.mark(Date())

        // Snapshot the render timestamp into an immutable `AVAudioTime`
        // NOW: `inTimeStamp` is only valid for the duration of this
        // callback, so we must capture it before the async hand-off.
        let avTime = AVAudioTime(audioTimeStamp: inTimeStamp, sampleRate: format.sampleRate)

        // Hand the owned buffer to the serial queue and return. We wrap it
        // in `AudioChunk` (already `@unchecked Sendable`) — the SAME
        // wrapper this file uses to ferry a PCM buffer across the
        // AsyncStream Sendable boundary in `continuation.yield` — so the
        // capture introduces no new data-race category: the buffer is
        // produced here, consumed only on `workQueue`, never shared. This
        // single `async` enqueue is the only per-buffer work left on the
        // RT thread besides the render + copy itself.
        let chunk = AudioChunk(pcm: pcm, time: avTime)
        workQueue.async { [weak self] in
            self?.handle(chunk)
        }

        return noErr
    }

    /// The heavy, NON-real-time work, moved off the RT render thread onto
    /// `workQueue`. Runs ONLY on that serial queue — so it is the single
    /// owner of `audioFile`, `analyzer`, and `lastSpectrumPublishRefTime`
    /// (none of which are thread-safe), with no extra locking needed: the
    /// serial queue itself is the mutual exclusion. Order is preserved
    /// (FIFO serial), so writes and transcriber yields stay in exact
    /// arrival order — no reordering, no lost-then-late buffer.
    private func handle(_ chunk: AudioChunk) {
        let pcm = chunk.pcm

        // The silence watchdog must judge the RAW signal. The gate
        // multiplies quiet-but-alive speech by 0.18 (−15 dB), which would
        // push a live mic (−55 dB RMS) under the liveness floor and
        // falsely pause the session as "dead input". Capture the raw RMS
        // BEFORE the in-place gate; the rate-limited publish below reuses
        // it. Peak/spectrum stay post-gate on purpose — the level meter
        // should show what actually lands in the archive.
        let rawRMSDB = Self.rmsLevelDB(of: pcm)
        if noiseSuppressionEnabled {
            MicrophoneNoiseSuppression.apply(to: pcm)
        }

        // Archive write (gated), now off the RT thread — this is the
        // worst former RT offender (it can block on disk I/O). Same
        // try/accumulate pattern as AudioRecorder's tap: only count frames
        // that actually landed. `audioFile` is touched ONLY here.
        if archiveGate.value, let file = audioFile {
            do {
                try file.write(from: pcm)
                framesWritten.add(UInt64(pcm.frameLength))
            } catch {
                writeErrors.record(error)
            }
        }

        // Hand the buffer to the transcriber. Moved here so the RT thread
        // doesn't touch the continuation; serial order means the
        // transcriber still sees buffers in arrival order. (Yielding after
        // the continuation is finished — which only happens AFTER this
        // queue is drained in teardown — is a harmless no-op, so the tail
        // can never be lost: teardown flushes BEFORE it finishes.)
        continuation?.yield(chunk)

        // Rate-limited spectrum + level (≤30 Hz). Same cadence + the same
        // result-into-a-lock-box / MainActor-displayTimer-pull design as
        // before (commit c2b9b2b) — the only change is that the FFT and
        // peak/RMS now run on `workQueue` instead of inline on the RT
        // thread, removing the 2048-pt vDSP FFT from the IOWorkLoop. The
        // `analyzer` (stateful attack/decay) and `lastSpectrumPublishRefTime`
        // are touched ONLY here, so they stay single-threaded.
        let nowRefTime = Date().timeIntervalSinceReferenceDate
        if nowRefTime - lastSpectrumPublishRefTime > CoreAudioMicRecorder.spectrumPublishIntervalSec {
            lastSpectrumPublishRefTime = nowRefTime
            let peak = Self.peakLevelDB(of: pcm)
            micLiveness.record(
                rms: rawRMSDB,
                at: Date(),
                floor: CoreAudioMicRecorder.micLivenessFloorDB
            )
            var bands: [Float]? = nil
            if let ch = pcm.floatChannelData?[0] {
                let frames = Int(pcm.frameLength)
                let sampleRate = pcm.format.sampleRate
                let bufferPtr = UnsafeBufferPointer(start: ch, count: frames)
                bands = analyzer.bands(from: bufferPtr, sampleRate: sampleRate)
            }
            // Single lock-box write (uncontended OSAllocatedUnfairLock —
            // the MainActor reader only holds it for a struct copy).
            levelSpectrum.update(level: peak, bands: bands)
        }
    }

    /// Drain the serial queue synchronously: when this returns, EVERY
    /// buffer already enqueued by `process(...)` has been fully handled —
    /// its disk write completed and counted, its `yield` delivered. A
    /// serial queue is FIFO, so a `sync` barrier appended to the tail
    /// cannot return until all prior blocks have run.
    ///
    /// DEADLOCK-SAFE: only ever called from the MainActor teardown paths,
    /// NEVER from inside a `workQueue` block (and the RT thread never
    /// calls it either — it only `async`s). No code that runs ON the
    /// queue ever waits on the queue, so `sync` can't self-deadlock.
    ///
    /// The caller MUST have stopped the AudioUnit first (so no further
    /// `process(...)` can enqueue new work) — otherwise a freshly-arrived
    /// buffer could land after the drain. All teardown paths do exactly
    /// that: `AudioOutputUnitStop` (which quiesces the RT thread) precedes
    /// every `flush()` call.
    func flush() {
        workQueue.sync { }
    }

    // Level helpers — copied from AudioRecorder (nonisolated statics).
    nonisolated static func peakLevelDB(of buffer: AVAudioPCMBuffer) -> Float {
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

    nonisolated static func rmsLevelDB(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return -160 }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        guard frames > 0, count > 0 else { return -160 }
        var sumSquares: Float = 0
        for ch in 0..<count {
            let ptr = channels[ch]
            for i in 0..<frames {
                let v = ptr[i]
                sumSquares += v * v
            }
        }
        let meanSquare = sumSquares / Float(frames * count)
        guard meanSquare > 0 else { return -160 }
        return 10 * log10(meanSquare)
    }
}

// MARK: - C render callback (free function)

// (The AUHAL input render callback is an inline non-capturing literal
// closure in `installRenderContext` — it must be a literal, not a named
// func, to form a @convention(c) pointer under default MainActor isolation.)

// MARK: - Cross-thread lock-boxes
//
// Local copies of the same primitives AudioRecorder defines privately,
// renamed to avoid colliding with its `private` types in the same module.
// Identical behaviour; `OSAllocatedUnfairLock` is the same lock primitive
// AudioRecorder uses for its render-thread → MainActor bridges.

/// Accumulates archive-write failures off the render thread; one summary
/// surfaced at stop().
private final class WriteErrorBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<(count: Int, first: (any Error)?)>(initialState: (0, nil))
    func record(_ error: any Error) {
        lock.withLock { state in
            state.count += 1
            if state.first == nil { state.first = error }
        }
    }
    func snapshot() -> (count: Int, first: (any Error)?) { lock.withLock { $0 } }
    func reset() { lock.withLock { $0 = (0, nil) } }
}

/// Frames that successfully landed on disk.
private final class FrameCountBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    func add(_ frames: UInt64) { lock.withLock { $0 &+= frames } }
    func snapshot() -> UInt64 { lock.withLock { $0 } }
    func reset() { lock.withLock { $0 = 0 } }
}

/// Last-buffer arrival timestamp bridge (render → MainActor watchdog).
private final class TimestampBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Date?>(initialState: nil)
    func mark(_ at: Date) { lock.withLock { $0 = at } }
    func snapshot() -> Date? { lock.withLock { $0 } }
    func reset() { lock.withLock { $0 = nil } }
}

/// Mic signal liveness bridge (render → MainActor silence monitor).
///
/// `allZero` counts buffers whose samples are BIT-EXACT zero, tracked
/// separately from the RMS floor (2026-07-26). The distinction is the
/// whole diagnosis: a live microphone in a silent room still produces a
/// noise floor around −70…−90 dBFS, so bit-exact zeros are physically
/// impossible from working hardware. They mean exactly one of: macOS is
/// withholding the mic (TCC / a stale coreaudiod decision), the input is
/// muted at the system level, or we're bound to a device that isn't
/// really recording. Telling the user "check your Bluetooth mic" in that
/// state — as this code used to — sends them down the wrong path.
private final class LivenessBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<(aboveFloorAt: Date?, lastRMS: Float, allZero: Int, total: Int)>(
        initialState: (nil, -160, 0, 0)
    )
    func record(rms: Float, at: Date, floor: Float) {
        lock.withLock { state in
            state.lastRMS = rms
            state.total += 1
            // rmsLevelDB returns exactly -160 only when meanSquare == 0,
            // i.e. every sample in the buffer was 0.0.
            if rms <= -160 { state.allZero += 1 }
            if rms > floor { state.aboveFloorAt = at }
        }
    }
    func snapshot() -> (aboveFloorAt: Date?, lastRMS: Float, allZero: Int, total: Int) { lock.withLock { $0 } }
    func reset(to date: Date?) { lock.withLock { $0 = (date, -160, 0, 0) } }
}

/// Render-thread write gate (transcript-only mode without teardown).
private final class AtomicFlag: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Bool>
    init(initial: Bool) { lock = OSAllocatedUnfairLock(initialState: initial) }
    var value: Bool { lock.withLock { $0 } }
    func set(_ v: Bool) { lock.withLock { $0 = v } }
}

/// Render-thread → MainActor bridge for the live level (dBFS peak) +
/// normalised spectrum bands that drive the daisy widget. The render
/// callback writes the latest rate-limited sample; the recorder's
/// MainActor `displayTimer` reads it and publishes to the Observable
/// `levelDB` / `spectrumBands`.
///
/// This is the piece that DECOUPLES the petals from a saturated
/// cooperative pool: the old design hopped a `Task { @MainActor }` from
/// the hard real-time render thread per buffer, and under heavy
/// MainActor load (WhisperKit large-v3 4× fallback + MCP storm) those
/// Tasks were starved, so the petals froze while the transcript (which
/// rides `continuation.yield`, not a MainActor hop) kept flowing.
///
/// `bands` is nil until the first FFT lands so the pump leaves the
/// initial all-zeros array in place rather than briefly clearing it.
/// The lock is held only for a scalar/array-reference swap on the write
/// side and a struct copy on the read side — uncontended in practice.
private final class LevelSpectrumBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<(level: Float, bands: [Float]?)>(
        initialState: (-160, nil)
    )
    /// Render thread: stash the newest sample. `bands` is the analyzer's
    /// already-smoothed/gated output (passed by value — Array is COW, so
    /// the MainActor reader gets an immutable snapshot).
    func update(level: Float, bands: [Float]?) {
        lock.withLock { state in
            state.level = level
            if let bands { state.bands = bands }
        }
    }
    func snapshot() -> (level: Float, bands: [Float]?) { lock.withLock { $0 } }
    func reset() { lock.withLock { $0 = (-160, nil) } }
}
