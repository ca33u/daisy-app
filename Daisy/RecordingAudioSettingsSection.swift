//
//  RecordingAudioSettingsSection.swift
//  Daisy
//
//  Recording-device controls and short, non-archiving audio probes.
//  Extracted from SettingsView so the largest settings surface can be
//  split feature-by-feature without changing its navigation model.
//

import AppKit
import SwiftUI

struct RecordingAudioSettingsSection: View {
    @Bindable var settings: AppSettings

    @State private var microphoneDevices: [AudioInputDevice] = []
    @State private var outputDevices: [AudioInputDevice] = []
    @State private var selectedOutputUID = ""
    @State private var microphoneProbe = CoreAudioMicRecorder()
    @State private var systemAudioProbe = SystemAudioCapture()
    @State private var microphoneLevelDB: Float = -160
    @State private var systemAudioLevelDB: Float = -160
    @State private var microphoneResult: ProbeResult = .idle
    @State private var systemAudioResult: ProbeResult = .idle
    /// P1-6 spike switch. Hidden until the key exists in the defaults
    /// database — see `ProcessTapDebugFlag`.
    @State private var processTapDebugRevealed = false
    @State private var processTapEnabled = false

    var body: some View {
        Section {
            microphonePicker

            Toggle(isOn: $settings.microphoneNoiseSuppressionEnabled) {
                Text("Reduce background noise")
                Text("A gentle on-device noise gate softens steady room noise before transcription and saving. Off by default; very quiet voices may sound less natural.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            microphoneLevelRow

            Toggle("Record the other side", isOn: $settings.captureSystemAudio)

            outputPicker

            if settings.captureSystemAudio {
                systemAudioLevelRow

                if !SystemAudioCapture.usesProcessTapBackend, !ScreenRecordingPermission.isGranted {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Screen Recording permission is off", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") {
                            ScreenRecordingPermission.openSystemSettings()
                        }
                    }
                } else if !SystemAudioCapture.usesProcessTapBackend,
                          AudioInputDevices.systemDefaultOutputIsBluetooth() {
                    Label {
                        Text("Bluetooth output is selected. If the other-side test stays empty, switch macOS output to built-in speakers, USB audio, or a wired device and test again.")
                    } icon: {
                        Image(systemName: "wave.3.right.circle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                processTapDebugRow
            }

            if recordingIsActive {
                Label("Audio tests are unavailable while a recording is active.", systemImage: "record.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio diagnostics")
                Text("Choose the routes Daisy will use, then verify that real signal reaches both tracks before a meeting.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textCase(nil)
            }
        }
        .task {
            refreshDevices()
            processTapDebugRevealed = ProcessTapDebugFlag.isRevealed
            processTapEnabled = ProcessTapDebugFlag.isEnabled
        }
        // Live mic monitor — restarts whenever the selected device, the
        // noise-suppression toggle, or the recording state changes, and
        // stops automatically when the section leaves the screen (task
        // cancellation). While it runs, macOS shows the orange mic
        // indicator — expected on an audio-diagnostics screen; System
        // Settings → Sound behaves the same way.
        .task(id: liveMonitorKey) {
            await runLiveMicrophoneMonitor()
        }
        // Live other-side monitor — same lifecycle contract as the mic
        // meter: runs only while the section is on screen, restarts on
        // output-device / toggle / recording changes, and is silenced
        // during a real recording (the session owns its own SCStream;
        // two captures would fight). Runs SCStream in quiet-diagnostics
        // mode, so all in-class toasts are suppressed and the verdicts
        // below are the only messaging.
        .task(id: systemLiveMonitorKey) {
            await runLiveSystemAudioMonitor()
        }
        .onDisappear {
            microphoneProbe.stop()
            Task { await systemAudioProbe.stop() }
        }
    }

    /// Experimental backend switch (P1-6). Deliberately not a shipped
    /// setting: it appears only once someone has written the key by hand,
    /// so a normal user never meets it, and it takes effect on the NEXT
    /// recording rather than the current one — `SystemAudioCapture`
    /// decides its backend at fresh start and never mid-session.
    @ViewBuilder
    private var processTapDebugRow: some View {
        if processTapDebugRevealed {
            Toggle(isOn: $processTapEnabled) {
                Text("Record the other side with Core Audio taps")
                Text("Experimental. Captures below device routing, so Bluetooth headphones stop silencing the other side. Applies to the next recording, and asks for System Audio Recording permission the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: processTapEnabled) { _, newValue in
                ProcessTapDebugFlag.isEnabled = newValue
            }
        }
    }

    private var microphonePicker: some View {
        LabeledContent("Microphone") {
            Picker("", selection: $settings.selectedMicDeviceUID) {
                Text(systemDefaultLabel).tag("")
                if !microphoneDevices.isEmpty {
                    Divider()
                    ForEach(microphoneDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                if !settings.selectedMicDeviceUID.isEmpty,
                   !microphoneDevices.contains(where: { $0.uid == settings.selectedMicDeviceUID }) {
                    Divider()
                    Text("Saved device (not connected)")
                        .tag(settings.selectedMicDeviceUID)
                }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: settings.selectedMicDeviceUID) { _, _ in
                microphoneResult = .idle
                microphoneLevelDB = -160
            }
        }
    }

    private var systemDefaultLabel: String {
        if let current = microphoneDevices.first(where: \.isSystemDefault) {
            return String(localized: "System default (\(current.name))")
        }
        return String(localized: "System default")
    }

    /// Live level row — continuous, System-Settings-style segment meter
    /// instead of the old "test for 8 seconds" button. The verdict logic
    /// survives as a rolling check inside the monitor loop.
    private var microphoneLevelRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Microphone level")
                Spacer()
                Text(levelLabel(microphoneLevelDB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                SegmentLevelMeter(progress: levelProgress(microphoneLevelDB))
            }
            if let message = microphoneResult.message {
                Label(message, systemImage: microphoneResult.symbol)
                    .font(.caption)
                    .foregroundStyle(microphoneResult.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    /// System OUTPUT picker in the same visual grammar as the microphone
    /// picker. Selecting a device changes the SYSTEM default output — the
    /// same action as Sound Settings — because Daisy deliberately follows
    /// the macOS route instead of keeping a private one.
    private var outputPicker: some View {
        LabeledContent("Mac output") {
            HStack(spacing: 8) {
                if AudioInputDevices.systemDefaultOutputIsBluetooth() {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Bluetooth output can prevent macOS from exposing the other side to ScreenCaptureKit.")
                }
                Picker("", selection: $selectedOutputUID) {
                    ForEach(outputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: selectedOutputUID) { _, newUID in
                    guard let device = outputDevices.first(where: { $0.uid == newUID }),
                          !device.isSystemDefault else { return }
                    if AudioInputDevices.setSystemDefaultOutput(deviceID: device.id) {
                        refreshDevices()
                    } else {
                        // CoreAudio refused — resync the picker to reality.
                        refreshDevices()
                    }
                }
            }
        }
    }

    /// Live other-side row — mirrors `microphoneLevelRow`. The meter
    /// shows the peak of the latest captured system-audio buffer; the
    /// caption under it carries the rolling verdict (play something /
    /// audio confirmed / route broken).
    private var systemAudioLevelRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Other-side level")
                Spacer()
                Text(levelLabel(systemAudioLevelDB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                SegmentLevelMeter(progress: levelProgress(systemAudioLevelDB))
            }
            if let message = systemAudioResult.message {
                Label(message, systemImage: systemAudioResult.symbol)
                    .font(.caption)
                    .foregroundStyle(systemAudioResult.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var recordingIsActive: Bool {
        guard let status = RecordingSession.current?.status else { return false }
        switch status {
        case .preparing, .recording, .paused, .stopping, .summarizing:
            return true
        case .idle, .finished, .failed:
            return false
        }
    }

    /// Key that restarts the live monitor task on any relevant change.
    private var liveMonitorKey: String {
        "\(settings.selectedMicDeviceUID)|\(settings.microphoneNoiseSuppressionEnabled)|\(recordingIsActive)"
    }

    /// Restart key for the other-side monitor. Output UID is included so
    /// picking a new output tears the SCStream down and rebinds cleanly
    /// instead of leaning on the in-class route-change rebuild (which is
    /// budgeted for real recordings).
    private var systemLiveMonitorKey: String {
        "\(settings.captureSystemAudio)|\(recordingIsActive)|\(selectedOutputUID)|\(ScreenRecordingPermission.isGranted)"
    }

    /// Continuous mic monitor. Runs while the section is on screen (the
    /// enclosing `.task` cancels it on disappear) and pauses during a
    /// real recording — the probe would fight the session for the device.
    /// Verdict: after ~8 s of continuous near-silence show the same
    /// warning the old button test produced; clear it as soon as real
    /// signal appears.
    private func runLiveMicrophoneMonitor() async {
        microphoneResult = .idle
        microphoneLevelDB = -160
        guard !recordingIsActive else { return }

        do {
            try microphoneProbe.start(
                preferredDeviceUID: settings.selectedMicDeviceUID,
                noiseSuppressionEnabled: settings.microphoneNoiseSuppressionEnabled
            )
        } catch {
            microphoneResult = .failed(error.localizedDescription)
            return
        }
        defer { microphoneProbe.stop() }

        var quietTicks = 0
        var ticks = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { break }
            let level = microphoneProbe.levelDB
            microphoneLevelDB = level
            if level > -48 {
                quietTicks = 0
                if microphoneResult != .idle { microphoneResult = .idle }
            } else {
                quietTicks += 1
                if quietTicks == 80 {
                    microphoneResult = .warning(String(localized: "Almost no microphone signal was detected. Check the selected device, its mute state, and Microphone permission."))
                }
            }
            // Keep device lists fresh while the user is looking at them —
            // plugging in a headset should show up without reopening
            // Settings. Enumeration is cheap at this cadence (every 2 s).
            ticks += 1
            if ticks % 20 == 0 { refreshDevices() }
        }
    }

    /// Continuous other-side monitor — the system-audio twin of
    /// `runLiveMicrophoneMonitor`. One important asymmetry: a silent
    /// meter is AMBIGUOUS here (nothing playing vs. broken route), so
    /// the verdicts only claim what's provable:
    ///   • SCStream delivers buffers even for silence — ZERO buffers
    ///     after ~8 s means the route is broken (classic Bluetooth
    ///     loopback failure) → honest failure.
    ///   • buffers-but-silent just shows the "play any audio" hint.
    ///   • the first audible buffer flips a lasting green verdict.
    private func runLiveSystemAudioMonitor() async {
        systemAudioResult = .idle
        systemAudioLevelDB = -160
        guard settings.captureSystemAudio, !recordingIsActive else { return }
        // The Screen Recording gate belongs to the ScreenCaptureKit
        // backend. With the process-tap spike on, the probe uses a Core
        // Audio tap, which needs System Audio Recording instead — and
        // refusing to run here would hide the meter from exactly the
        // user the spike exists for (Screen Recording denied or reset).
        guard SystemAudioCapture.usesProcessTapBackend || ScreenRecordingPermission.isGranted else { return }

        do {
            try await systemAudioProbe.start(quietDiagnostics: true)
        } catch {
            systemAudioResult = .failed(error.localizedDescription)
            return
        }

        systemAudioResult = .running(String(localized: "Play any audio — the meter shows what Daisy hears from the other side."))

        var ticks = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { break }

            // The stream died and in-class recovery gave up (quiet mode
            // suppressed its toasts) — surface it here instead.
            if systemAudioProbe.state == .stopped {
                systemAudioLevelDB = -160
                systemAudioResult = .failed(String(localized: "No system-audio buffers arrived. Change the macOS output device, avoid Bluetooth, and test again."))
                return
            }

            systemAudioLevelDB = systemAudioProbe.peakLevelDB
            ticks += 1

            if systemAudioProbe.receivedAudibleAudio {
                let verdict = ProbeResult.passed(String(localized: "System audio is reaching Daisy."))
                if systemAudioResult != verdict { systemAudioResult = verdict }
            } else if systemAudioProbe.hasReceivedAudio {
                // Buffers flow (route works), nothing audible yet —
                // recover from an earlier no-buffers verdict if the
                // route came back without a task restart.
                if case .failed = systemAudioResult {
                    systemAudioResult = .running(String(localized: "Play any audio — the meter shows what Daisy hears from the other side."))
                }
            } else if ticks == 80 {
                systemAudioResult = .failed(String(localized: "No system-audio buffers arrived. Change the macOS output device, avoid Bluetooth, and test again."))
            }
        }
        await systemAudioProbe.stop()
    }

    private func refreshDevices() {
        microphoneDevices = AudioInputDevices.list()
        outputDevices = AudioInputDevices.listOutputs()
        selectedOutputUID = outputDevices.first(where: \.isSystemDefault)?.uid ?? ""
    }

    private func levelProgress(_ db: Float) -> Double {
        Double(max(0, min(1, (db + 60) / 60)))
    }

    private func levelLabel(_ db: Float) -> String {
        db <= -120 ? String(localized: "silent") : String(format: "%.0f dB", db)
    }

}

/// System-Settings-style input level meter: a row of capsules that fill
/// left-to-right. Filled = label color, empty = quaternary; the top two
/// segments go orange as a clipping hint.
private struct SegmentLevelMeter: View {
    let progress: Double
    var segments: Int = 15

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<segments, id: \.self) { index in
                Capsule()
                    .fill(color(for: index))
                    .frame(width: 6, height: 16)
            }
        }
        .animation(.linear(duration: 0.08), value: filledCount)
        .accessibilityLabel(Text("Input level"))
        .accessibilityValue(Text("\(Int((progress * 100).rounded())) percent"))
    }

    private var filledCount: Int {
        Int((progress * Double(segments)).rounded())
    }

    private func color(for index: Int) -> Color {
        guard index < filledCount else {
            return Color(nsColor: .quaternaryLabelColor)
        }
        if index >= segments - 2 {
            return .orange
        }
        return Color(nsColor: .labelColor).opacity(0.75)
    }
}

private enum ProbeResult: Equatable {
    case idle
    case running(String)
    case passed(String)
    case warning(String)
    case failed(String)

    var message: String? {
        switch self {
        case .idle: return nil
        case .running(let text), .passed(let text), .warning(let text), .failed(let text): return text
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "circle"
        case .running: return "waveform"
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle, .running: return .secondary
        case .passed: return .green
        case .warning: return .orange
        case .failed: return .red
        }
    }
}
