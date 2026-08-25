//
//  ProcessTapAudioCapture.swift
//  Daisy
//
//  EXPERIMENTAL second backend for "the other side" of a meeting
//  (P1-6 spike, 2026-08-25). Lives behind `daisy.debug.processTapCapture`,
//  which is OFF by default — with the flag off not one line of this file
//  is reached and `SystemAudioCapture` behaves exactly as it did before.
//
//  WHY THIS EXISTS
//  ---------------
//  `SystemAudioCapture` reads the remote side through a ScreenCaptureKit
//  loopback. SCStream binds to the window server's audio path, and when
//  the default output is Bluetooth that path delivers nothing: the stream
//  reports `.capturing`, zero buffers arrive, and the other side is simply
//  missing from the recording. AirPods are the most common headset our
//  users own, so this is not an edge case — see the field reports in
//  [[daisy-bluetooth-capture-root-cause]].
//
//  A Core Audio process tap reads at the HAL, BELOW device routing. The
//  Bluetooth stack never enters the picture, and as a bonus the tap also
//  hears processes that have no window at all — Continuity phone calls
//  (`callservicesd`) and FaceTime (`avconferenced`) — which ScreenCaptureKit
//  structurally cannot see.
//
//  It also asks for a *smaller* permission: "System Audio Recording Only"
//  instead of "Screen & System Audio Recording", and it lights no screen
//  recording indicator in the menu bar.
//
//  THE SILENT-DENIAL TRAP
//  ----------------------
//  Every call in this pipeline returns `noErr` even when TCC has denied
//  us, and the IOProc fires on schedule delivering buffers of pure zeros.
//  There is no error to check. The only detector is "are the samples
//  non-zero?", which `SystemAudioCapture`'s existing silent-content
//  monitor already is — that monitor is load-bearing here, not a nicety.
//
//  KNOWN LIMITATIONS OF THIS SPIKE
//  -------------------------------
//  • Only the AGGREGATE DEVICE is watched for death. A tap can be
//    revoked while the aggregate stays alive and keeps handing us zeros;
//    nothing fires for that, and the silent-content monitor's 120 s
//    timeout is the only thing that notices.
//  • Opening a permission prompt requires standing up the whole
//    pipeline, so the FIRST recording after the flag is turned on is the
//    one that shows the dialog. There is no preflight.
//
//  macOS 14.4+. The API lands in 14.2, but 14.4 is where taps became
//  usable and where the `kTCCServiceAudioCapture` category settled.
//  Older systems keep the SCStream path.
//

import AVFoundation
import CoreAudio
import Foundation
import os

// MARK: - Hidden debug flag

/// The switch that swaps `SystemAudioCapture`'s backend, plus the small
/// amount of state a log report needs to say which backend actually ran.
///
/// Hidden rather than shipped-off, because this is a spike and not a
/// feature: the row in Settings → Audio diagnostics only appears once the
/// key EXISTS in the defaults database. A normal user never sees it; Egor
/// reveals it once with
///
///     defaults write app.essazanov.Daisy daisy.debug.processTapCapture -bool true
///
/// and can flip it from the UI from then on.
nonisolated enum ProcessTapDebugFlag {
    /// Use the Core Audio tap instead of ScreenCaptureKit.
    static let key = "daisy.debug.processTapCapture"

    /// Second flag, same reveal rule: tap only the known meeting apps
    /// instead of everything. OFF (= global tap) is the default we expect
    /// to ship; this exists so the global-vs-per-process question can be
    /// answered on a device without a rebuild.
    static let meetingAppsOnlyKey = "daisy.debug.processTapMeetingAppsOnly"

    /// Third flag: host the tap aggregate on the CURRENT DEFAULT output
    /// instead of the built-in one. Built-in is the default because it
    /// never disappears mid-meeting; this exists because the two working
    /// public recipes disagree about which host is right, and a device
    /// that delivers no samples on one of them should be one
    /// `defaults write` away from testing the other, not a rebuild.
    static let hostOnDefaultOutputKey = "daisy.debug.processTapHostDefaultOutput"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var meetingAppsOnly: Bool {
        get { UserDefaults.standard.bool(forKey: meetingAppsOnlyKey) }
        set { UserDefaults.standard.set(newValue, forKey: meetingAppsOnlyKey) }
    }

    static var hostOnDefaultOutput: Bool {
        get { UserDefaults.standard.bool(forKey: hostOnDefaultOutputKey) }
        set { UserDefaults.standard.set(newValue, forKey: hostOnDefaultOutputKey) }
    }

    /// Whether the Settings row is shown at all. Presence of the key —
    /// not its value — is the reveal, so turning the spike back off from
    /// the UI doesn't hide the switch again.
    static var isRevealed: Bool {
        UserDefaults.standard.object(forKey: key) != nil
    }

    /// Backend the last capture actually ran on, so a log report written
    /// after the meeting says what happened rather than what the flag
    /// says now. Written once per fresh `SystemAudioCapture.start()`.
    ///
    /// Persisted rather than kept in memory: the log report a user files
    /// after a bad meeting is very often written after a relaunch, which
    /// is exactly when a process-lifetime value would read "unknown".
    static var lastActiveBackend: String? {
        get { UserDefaults.standard.string(forKey: "daisy.debug.processTapLastBackend") }
        set { UserDefaults.standard.set(newValue, forKey: "daisy.debug.processTapLastBackend") }
    }

    /// Host device the last tap aggregate was built around, for the same
    /// reason. nil on the ScreenCaptureKit path.
    static var lastTapHostDevice: String? {
        get { UserDefaults.standard.string(forKey: "daisy.debug.processTapLastHost") }
        set { UserDefaults.standard.set(newValue, forKey: "daisy.debug.processTapLastHost") }
    }
}

// MARK: - Engine

/// One live Core Audio process tap plus the private aggregate device that
/// makes it readable. Owned by `SystemAudioCapture`; built and torn down
/// as a unit, never reconfigured in place — a rebuild means a new
/// instance, which is what lets the owner apply the same identity check
/// it applies to a replaced `SCStream` (rule 2 of the restart rules).
///
/// `nonisolated` because the module compiles main-actor-by-default and
/// the HAL IO block runs on a dispatch queue: nothing in here may be
/// MainActor-isolated. `@unchecked Sendable` on the same terms as
/// `RenderContext` in `CoreAudioMicRecorder` — see the confinement notes
/// on the individual members.
nonisolated final class ProcessTapAudioCapture: @unchecked Sendable {

    /// What to record.
    enum Scope: Equatable {
        /// Everything the Mac plays except Daisy itself. The default, and
        /// the one we expect to ship — see the rationale at the call site
        /// in `start()`.
        case globalExcludingSelf
        /// Only these processes. Used by the `meetingAppsOnly` debug flag
        /// so the two shapes can be compared on a real device.
        case onlyProcesses(pids: [pid_t])
    }

    // MARK: Configuration (immutable for the life of the instance)

    private let scope: Scope
    /// UID of the device to host the aggregate on. Non-nil only on a
    /// rebuild, where it carries the host the SESSION started on — a
    /// mid-recording recovery must not silently move to a different
    /// device (restart rule 6). nil means "resolve the preferred host".
    private let requestedHostUID: String?
    /// Format the session's first buffer arrived in, if this instance is
    /// replacing an earlier engine. Buffers are converted back to it so
    /// the archive stays one contiguous file across a rebuild — see the
    /// converter note in `start()`.
    private let pinnedFormat: AVAudioFormat?
    /// Queue the owner wants buffers delivered on. `SystemAudioCapture`
    /// passes its own `outputQueue`, the serial queue that already owns
    /// the archive writer, so tap buffers and SCStream buffers reach the
    /// same code under the same confinement.
    private let deliveryQueue: DispatchQueue
    private let onBuffer: @Sendable (AudioChunk) -> Void
    /// Called when the aggregate device dies under us — the tap-backend
    /// analogue of `SCStreamDelegate.didStopWithError`. Carries this
    /// instance's identity so the owner can ignore the death of an engine
    /// it already replaced. Takes a message rather than an `Error` so the
    /// payload is Sendable all the way to the MainActor hop.
    private let onDeath: @Sendable (ObjectIdentifier, String) -> Void

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "ProcessTap")

    /// Dedicated IO queue. Must be non-nil: passing `nil` to
    /// `AudioDeviceCreateIOProcIDWithBlock` ("use the HAL's own thread")
    /// has been observed to register the block and never call it.
    /// `.userInteractive` because it is the HAL's IO cycle; the block
    /// itself only memcpys and hands off, all the slow work (disk, FFT,
    /// transcriber hand-off) happens on `deliveryQueue`.
    private let ioQueue = DispatchQueue(
        label: "app.essazanov.Daisy.ProcessTapIO",
        qos: .userInteractive
    )

    /// Back-pressure for the IO → `deliveryQueue` hand-off. See `deliver`.
    private static let deliveryDepth = 48
    private let deliveryPermits = DispatchSemaphore(value: ProcessTapAudioCapture.deliveryDepth)

    /// Buffers dropped because `deliveryQueue` was more than
    /// `deliveryDepth` behind. Written only on `ioQueue`; read from the
    /// MainActor for the log line, where a torn read of a counter is not
    /// worth a lock.
    private var droppedBuffers: UInt64 = 0

    /// Queue CoreAudio dispatches the device-is-alive listener on. A
    /// global queue so the add/remove pair can name the identical object
    /// (same trick `SystemAudioCapture` uses for its output-device
    /// listener).
    private var listenerQueue: DispatchQueue { DispatchQueue.global(qos: .userInitiated) }

    // MARK: Lifecycle state
    //
    // CONFINEMENT: every property below is touched only from the owner's
    // MainActor lifecycle calls (`start()` / `stop()`), never from the IO
    // block — the block captures the format and converter it needs as
    // immutable locals precisely so it never has to read this object's
    // mutable state.

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var aliveListener: AudioObjectPropertyListenerBlock?
    private var started = false

    /// UID of the device the aggregate is hosted on. Read by the owner's
    /// route-change handler to decide whether a default-output change is
    /// any of our business.
    private(set) var hostDeviceUID: String = ""
    /// Human-readable host name, for the log report.
    private(set) var hostDeviceName: String = ""
    /// Format the tap delivers natively, before any conversion.
    private(set) var nativeFormat: AVAudioFormat?
    /// Format the owner will actually see. Equals `pinnedFormat` when a
    /// conversion is in place, otherwise `nativeFormat`.
    private(set) var deliveredFormat: AVAudioFormat?

    // MARK: - Init

    init(
        scope: Scope,
        requestedHostUID: String?,
        pinnedFormat: AVAudioFormat?,
        deliveryQueue: DispatchQueue,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onDeath: @escaping @Sendable (ObjectIdentifier, String) -> Void
    ) {
        self.scope = scope
        self.requestedHostUID = requestedHostUID
        self.pinnedFormat = pinnedFormat
        self.deliveryQueue = deliveryQueue
        self.onBuffer = onBuffer
        self.onDeath = onDeath
    }

    /// Nothing else destroys a tap or an aggregate device. ARC releasing
    /// this object leaves both alive in `coreaudiod` — a running IO cycle
    /// with a dead client — for the rest of the process's life, and the
    /// owner drops its reference on every rebuild. So: belt and braces.
    /// `stop()` is idempotent, so the normal path (owner calls `stop()`,
    /// then releases) costs nothing here.
    deinit {
        stop()
    }

    // MARK: - Start

    /// Build the tap + aggregate and start IO. Throws
    /// `DaisyError.audioEngineFailed` naming the step and its `OSStatus`;
    /// on any failure the partially-built pipeline is torn down before
    /// the throw, so a failed start leaves no orphan HAL objects behind.
    ///
    /// Note which call surfaces the permission prompt: `AudioDeviceStart`.
    /// Not creating the tap, not creating the aggregate, not registering
    /// the IOProc. There is no `requestAuthorization`-style API for
    /// system audio, so the whole pipeline has to be stood up before
    /// macOS will ask the user anything.
    func start() throws {
        guard #available(macOS 14.4, *) else {
            throw DaisyError.audioEngineFailed(
                "Core Audio process taps need macOS 14.4 or later."
            )
        }
        guard !started else { return }

        do {
            // 1. Describe the tap.
            let description: CATapDescription
            switch scope {
            case .globalExcludingSelf:
                // Global-minus-self is the default on purpose:
                //  • browser calls (Meet, Whereby, Teams in a tab) have no
                //    process of their own to name — they're one of a dozen
                //    renderer children of the browser;
                //  • Continuity phone calls and FaceTime live in system
                //    daemons that no bundle-ID list would ever enumerate;
                //  • a per-app tap goes deaf the moment the app respawns a
                //    helper or restarts mid-meeting, and nothing tells us —
                //    exactly the silent-failure class this spike exists to
                //    kill.
                // The cost is that we also capture music, notification
                // dings and the user's own YouTube tab. That is the same
                // deal the ScreenCaptureKit loopback already gives us
                // today, so it is not a regression.
                let excluded = Self.processObjectIDs(forPIDs: [getpid()])
                if excluded.isEmpty {
                    // Not fatal, but worth knowing: without the exclusion
                    // Daisy's own start/stop chimes land in the recording.
                    log.warning("Could not resolve Daisy's own audio process object — tap will include our own output")
                }
                description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
            case .onlyProcesses(let pids):
                let included = Self.processObjectIDs(forPIDs: pids)
                guard !included.isEmpty else {
                    throw DaisyError.audioEngineFailed(
                        "None of the known meeting apps is running — nothing to tap."
                    )
                }
                description = CATapDescription(monoMixdownOfProcesses: included)
            }

            // Mono, both above: Whisper wants mono anyway, the SCStream
            // path already delivers 1 channel on macOS 26, and it halves
            // the archive. Stereo buys us nothing downstream — the system
            // track is never spatially diarized.
            description.name = "Daisy meeting capture"
            description.uuid = UUID()
            // Private — the tap is visible only inside Daisy, so it never
            // shows up in the user's Audio MIDI Setup or Sound menu.
            description.isPrivate = true
            // Unmuted — we are recording the call, not muting it. `.muted`
            // takes the other side out of the user's headphones and
            // `.mutedWhenTapped` does the same for as long as we read;
            // either one turns a recorder into a mute button.
            description.muteBehavior = .unmuted
            // DELIBERATELY NOT ASSIGNED: `isExclusive`. It reads like a
            // lock-mode flag and is actually the DIRECTION flag — the
            // `…GlobalTapButExclude…` initializers set it true ("everything
            // except these"), the `…MixdownOf…` ones set it false ("only
            // these"). Writing to it after init inverts the tap into
            // "record only Daisy", which builds a perfectly healthy
            // pipeline that delivers perfect silence.

            // 2. Create the tap. Returns noErr even when TCC has denied
            //    us — see the silent-denial note at the top of this file.
            var newTapID = AudioObjectID(kAudioObjectUnknown)
            try Self.check(
                AudioHardwareCreateProcessTap(description, &newTapID),
                "AudioHardwareCreateProcessTap"
            )
            guard newTapID != kAudioObjectUnknown else {
                throw DaisyError.audioEngineFailed("The HAL created a tap with no object ID.")
            }
            tapID = newTapID

            // 3. Ask the tap what it will hand us.
            guard let native = Self.tapStreamFormat(tapID: newTapID) else {
                throw DaisyError.audioEngineFailed("Could not read the tap's audio format.")
            }
            nativeFormat = native

            // 4. Pick a device to host the aggregate. The aggregate has to
            //    be built around a REAL output device: a tap-only aggregate
            //    with an empty sub-device list creates successfully and
            //    then delivers zero samples forever.
            //
            //    We host on the BUILT-IN output rather than the current
            //    default. The built-in speakers never disappear, so
            //    connecting AirPods mid-meeting can't take the aggregate's
            //    clock device away with it — the exact hot-swap that makes
            //    the SCStream path rebuild and punch a hole in the
            //    recording. The tap itself is global and device-agnostic,
            //    so hosting it elsewhere costs us nothing: we are not in
            //    the playback path and never write output data.
            //
            //    On a REBUILD the owner hands us the UID the session
            //    started on, and we bind to that rather than re-resolving
            //    — restart rule 6: a mid-session recovery must not
            //    quietly move the recording onto a different device.
            let host: (id: AudioDeviceID, uid: String, name: String)
            if let requestedHostUID, let pinned = Self.device(uid: requestedHostUID) {
                host = pinned
            } else if let resolved = Self.hostOutputDevice() {
                host = resolved
            } else {
                throw DaisyError.audioEngineFailed("No output device available to host the tap aggregate.")
            }
            hostDeviceUID = host.uid
            hostDeviceName = host.name

            // 5. Build the private aggregate.
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Daisy Meeting Capture",
                kAudioAggregateDeviceUIDKey: "app.essazanov.Daisy.tap-aggregate.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: host.uid,
                // Private → not offered to the user anywhere in the system
                // UI, and torn down with the process if we crash.
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                // Required: without it the sub-tap is present but never
                // starts, which looks exactly like a permission denial.
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: host.uid]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true
                    ]
                ]
            ]
            var newAggregateID = AudioObjectID(kAudioObjectUnknown)
            try Self.check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID),
                "AudioHardwareCreateAggregateDevice"
            )
            guard newAggregateID != kAudioObjectUnknown else {
                throw DaisyError.audioEngineFailed("The HAL created an aggregate device with no object ID.")
            }
            aggregateID = newAggregateID

            // 6. Pin the downstream format across rebuilds.
            //
            //    The archive `AVAudioFile` is opened once, from the first
            //    buffer, and `AVAudioFile.write(from:)` raises an
            //    UNCATCHABLE ObjC exception when the buffer's format
            //    differs from the file's — which is why `SystemAudioCapture`
            //    defensively closes the archive on a mismatch rather than
            //    risk the crash. A rebuild that lands a different tap
            //    format would therefore cost us the rest of the recording's
            //    audio. Converting back to the format the session started
            //    in keeps one contiguous file. Same reasoning as the mic
            //    path's converter being pinned to the first format it saw
            //    (the 1.0.7.11 route-change fix).
            let outputFormat: AVAudioFormat
            var converter: AVAudioConverter?
            if let pinned = pinnedFormat, !Self.formatsMatch(pinned, native) {
                guard let conv = AVAudioConverter(from: native, to: pinned) else {
                    throw DaisyError.audioEngineFailed(
                        "Could not convert tap audio (\(native)) back to the session format (\(pinned))."
                    )
                }
                converter = conv
                outputFormat = pinned
                log.info("Tap format \(native, privacy: .public) differs from the session format — converting")
            } else {
                outputFormat = native
            }
            deliveredFormat = outputFormat

            // 7. Register the IOProc. The block captures the format and
            //    converter as immutable locals rather than reading them
            //    back off `self`, so the audio thread touches no mutable
            //    state of this object at all.
            let capturedConverter = converter
            var newProcID: AudioDeviceIOProcID?
            try Self.check(
                AudioDeviceCreateIOProcIDWithBlock(
                    &newProcID,
                    newAggregateID,
                    ioQueue
                ) { [weak self] _, inInputData, _, _, _ in
                    self?.deliver(
                        inInputData,
                        format: native,
                        converter: capturedConverter,
                        outputFormat: outputFormat
                    )
                },
                "AudioDeviceCreateIOProcIDWithBlock"
            )
            guard let procID = newProcID else {
                throw DaisyError.audioEngineFailed("The HAL returned no IOProc ID.")
            }
            ioProcID = procID

            // 8. Start IO. THIS is the call that makes macOS show the
            //    "System Audio Recording" prompt.
            try Self.check(AudioDeviceStart(newAggregateID, procID), "AudioDeviceStart")
            started = true
            installAliveListener(on: newAggregateID)

            log.info("Process tap started — \(self.diagnosticsLine, privacy: .public)")
        } catch {
            // Leave nothing behind. `stop()` is idempotent and skips
            // whatever wasn't created.
            stop()
            throw error
        }
    }

    // MARK: - Stop

    /// Stop IO and destroy everything, in the order the HAL wants:
    /// stop → destroy IOProc → destroy aggregate → destroy tap.
    /// Idempotent — the owner calls it from `stop()`, `pause()` and the
    /// rebuild path, and `start()` calls it on its own failure.
    ///
    /// After this returns the HAL guarantees no further IO block runs, so
    /// no new work can be enqueued onto `deliveryQueue`. Work already
    /// enqueued still drains — the owner's `outputQueue.sync` fence right
    /// after this call is what makes the archive teardown safe.
    func stop() {
        removeAliveListener()

        if aggregateID != kAudioObjectUnknown, let procID = ioProcID {
            if started {
                let status = AudioDeviceStop(aggregateID, procID)
                if status != noErr {
                    log.info("AudioDeviceStop returned \(status, privacy: .public) — device likely already gone")
                }
            }
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        started = false

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        // Clear the host too, so a stopped engine can't answer
        // `hostDeviceIsAlive` as if it were still capturing on it.
        hostDeviceUID = ""
    }

    // MARK: - Liveness

    /// Whether the device the aggregate is hosted on still exists. The
    /// owner's route-change handler reads this to decide whether a
    /// default-output change is any of our business: with a global tap
    /// hosted on the built-in output, it usually isn't.
    var hostDeviceIsAlive: Bool {
        guard !hostDeviceUID.isEmpty else { return false }
        return Self.deviceID(forUID: hostDeviceUID) != nil
    }

    /// One-line description for the log report.
    var diagnosticsLine: String {
        let fmt = deliveredFormat.map { "\(Int($0.sampleRate))Hz/\($0.channelCount)ch" } ?? "?"
        let dropped = droppedBuffers > 0 ? " dropped=\(droppedBuffers)" : ""
        return "tap scope=\(scopeLabel) host=\(hostDeviceName.isEmpty ? "?" : hostDeviceName) format=\(fmt)\(dropped)"
    }

    private var scopeLabel: String {
        switch scope {
        case .globalExcludingSelf: return "global"
        case .onlyProcesses(let pids): return "apps(\(pids.count))"
        }
    }

    /// Watch the aggregate for death — the tap-backend analogue of
    /// `SCStreamDelegate.didStopWithError`. The aggregate goes away when
    /// its host device is removed or when the HAL restarts (coreaudiod
    /// crash, sleep/wake), and without this the recording would go silent
    /// with nobody noticing until the transcript was read.
    private func installAliveListener(on device: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // The property fires on any change; only "no longer alive" is
            // news. A failed read counts as dead — if we can't ask the
            // device about itself, it isn't there.
            guard !Self.deviceIsAlive(device) else { return }
            self.onDeath(ObjectIdentifier(self), "The tap's aggregate device went away.")
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, listenerQueue, block)
        if status == noErr {
            aliveListener = block
        } else {
            log.error("Could not watch the tap aggregate for death: status=\(status, privacy: .public)")
        }
    }

    private func removeAliveListener() {
        guard let block = aliveListener, aggregateID != kAudioObjectUnknown else {
            aliveListener = nil
            return
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(aggregateID, &address, listenerQueue, block)
        if status != noErr {
            log.info("Removing the aggregate death listener returned \(status, privacy: .public)")
        }
        aliveListener = nil
    }

    // MARK: - IO

    /// Called on `ioQueue` for every HAL cycle. Copies the input buffer
    /// list into a buffer we own (the HAL's memory is only valid for the
    /// duration of the call), converts if the session format is pinned,
    /// and hands off. Everything slow — disk, level analysis, the
    /// transcriber — happens on `deliveryQueue`, not here.
    private func deliver(
        _ inInputData: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat,
        converter: AVAudioConverter?,
        outputFormat: AVAudioFormat
    ) {
        guard let copied = Self.pcmBuffer(from: inInputData, format: format) else { return }

        let outgoing: AVAudioPCMBuffer
        if let converter {
            guard let converted = Self.convert(copied, with: converter, to: outputFormat) else { return }
            outgoing = converted
        } else {
            outgoing = copied
        }

        // Bounded hand-off. ScreenCaptureKit delivers straight onto
        // `outputQueue`, so a slow disk back-pressures SCK itself; an
        // `async` hop has no such brake and would queue buffers without
        // limit until memory ran out. `deliveryDepth` permits ≈ half a
        // second of slack; past that we drop and count, because a
        // recording that loses 200 ms is recoverable and one that gets
        // OOM-killed is not. Drops show up in the log report.
        guard deliveryPermits.wait(timeout: .now()) == .success else {
            droppedBuffers &+= 1
            return
        }
        let chunk = AudioChunk(pcm: outgoing, time: AVAudioTime(hostTime: mach_absolute_time()))
        deliveryQueue.async { [onBuffer = self.onBuffer, permits = self.deliveryPermits] in
            onBuffer(chunk)
            permits.signal()
        }
    }

    /// Copy a HAL `AudioBufferList` into an owned `AVAudioPCMBuffer`.
    ///
    /// `AVAudioPCMBuffer` does NOT zero its backing store, so every byte
    /// inside `frameLength` has to be written by this function or the
    /// buffer ships malloc garbage downstream. That would be worse than
    /// dropping the cycle twice over: it gets transcribed as noise, and
    /// it defeats the all-zeros check that is our only signal for a
    /// denied System Audio Recording permission (see the header). Hence
    /// the smallest-common frame count and the explicit zero-fill.
    private static func pcmBuffer(
        from list: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: list)
        )
        // For a non-interleaved ASBD `mBytesPerFrame` is one sample and
        // there is one buffer per channel; for an interleaved one it
        // covers every channel and there is a single buffer.
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let expectedBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
        guard bytesPerFrame > 0, expectedBuffers > 0, source.count >= expectedBuffers else {
            return nil
        }

        // Smallest count across the buffers we're going to read: a short
        // channel then truncates the frame count instead of leaving a
        // tail of uninitialised memory.
        var frames = Int.max
        for index in 0..<expectedBuffers {
            guard source[index].mData != nil else { return nil }
            frames = min(frames, Int(source[index].mDataByteSize) / bytesPerFrame)
        }
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frames)
              ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        let bytes = frames * bytesPerFrame
        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for index in 0..<destination.count {
            guard let dst = destination[index].mData else { return nil }
            if index < expectedBuffers, let src = source[index].mData {
                memcpy(dst, src, bytes)
            } else {
                // Silence rather than garbage for any channel the HAL
                // didn't hand us.
                memset(dst, 0, bytes)
            }
        }
        return buffer
    }

    /// Single-shot `AVAudioConverter` pull, same shape as
    /// `AudioConverter.convert(_:)`. Returns nil on hard failure or an
    /// empty result; the caller drops the cycle rather than delivering a
    /// zero-length buffer downstream.
    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        // Generous capacity on purpose: a rate-converting AVAudioConverter
        // that wants more room than we gave it fills what fits and drops
        // the rest WITHOUT reporting an error, which would show up as a
        // subtly clipped archive after a recovery rather than as a
        // failure. Over-allocating a few kB per cycle is the cheaper
        // mistake.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio * 2 + 1024)
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    // MARK: - CoreAudio helpers
    //
    // Deliberately local rather than reused from `AudioInputDevices`:
    // that enum is MainActor-isolated (module default) and everything
    // here has to be callable from a nonisolated context.

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            throw DaisyError.audioEngineFailed("\(step) failed (OSStatus \(status)).")
        }
    }

    /// Translate process IDs into the `AudioObjectID`s `CATapDescription`
    /// wants. Note the type: the tap initializers take process OBJECT ids,
    /// not PIDs, even though most write-ups call them PIDs.
    private static func processObjectIDs(forPIDs pids: [pid_t]) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var resolved: [AudioObjectID] = []
        for pid in pids {
            var input = pid
            var objectID = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                &input,
                &size,
                &objectID
            )
            guard status == noErr, objectID != kAudioObjectUnknown else { continue }
            resolved.append(objectID)
        }
        return resolved
    }

    /// `kAudioTapProperty*` is macOS 14.2; only ever called from inside
    /// `start()`'s 14.4-narrowed region, but availability doesn't cross
    /// a function boundary so it has to be stated here.
    @available(macOS 14.2, *)
    private static func tapStreamFormat(tapID: AudioObjectID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    /// Built-in output first, current default output as the fallback for
    /// Macs that have no built-in speaker (and as an opt-in override —
    /// see `ProcessTapDebugFlag.hostOnDefaultOutput`).
    private static func hostOutputDevice() -> (id: AudioDeviceID, uid: String, name: String)? {
        if !ProcessTapDebugFlag.hostOnDefaultOutput, let builtIn = builtInOutputDevice() {
            return builtIn
        }
        let defaultID = defaultOutputDeviceID()
        guard defaultID != kAudioObjectUnknown,
              let uid = stringProperty(defaultID, kAudioDevicePropertyDeviceUID) else {
            // The override was asked for but there is no usable default —
            // fall back to built-in rather than refusing to record.
            return builtInOutputDevice()
        }
        let name = stringProperty(defaultID, kAudioObjectPropertyName) ?? uid
        return (defaultID, uid, name)
    }

    private static func builtInOutputDevice() -> (id: AudioDeviceID, uid: String, name: String)? {
        for id in allDeviceIDs() {
            var transport: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn,
                  hasOutputStreams(id),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { continue }
            return (id, uid, stringProperty(id, kAudioObjectPropertyName) ?? uid)
        }
        return nil
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr else { return AudioDeviceID(kAudioObjectUnknown) }
        return id
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func deviceIsAlive(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive)
        return status == noErr && alive != 0
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        let status = ids.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            var bytes = size
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address, 0, nil, &bytes, buffer.baseAddress!
            )
        }
        guard status == noErr else { return [] }
        return ids
    }

    private static func stringProperty(
        _ id: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Starts nil so nothing is leaked if CoreAudio doesn't write, and
        // so the +1 the HAL hands back is balanced by ARC releasing the
        // optional at scope exit.
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let cfValue = value else { return nil }
        let string = cfValue as String
        return string.isEmpty ? nil : string
    }

    /// Resolve a UID we already committed to into a full host tuple.
    private static func device(uid: String) -> (id: AudioDeviceID, uid: String, name: String)? {
        guard let id = deviceID(forUID: uid) else { return nil }
        return (id, uid, stringProperty(id, kAudioObjectPropertyName) ?? uid)
    }

    /// Same comparison the mic path uses before writing into an already
    /// open archive: rate, channels, sample type and interleaving.
    private static func formatsMatch(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
            && a.isInterleaved == b.isInterleaved
    }
}
