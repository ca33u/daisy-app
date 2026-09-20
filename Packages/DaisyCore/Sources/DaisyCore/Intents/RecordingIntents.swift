//
//  RecordingIntents.swift
//  DaisyCore
//
//  The three App Intents everything else builds on: Siri, the Shortcuts
//  app, the Control Center control, the home/lock-screen widgets and
//  the Live Activity's Stop button. They live here — not in the app
//  target — because the widget extension needs to reference these
//  types too (`Button(intent:)`), and an extension can never import its
//  host app's own module.
//
//  How a tap reaches the recorder WITHOUT opening the app (backlog C-1,
//  C-2, C-3), per Apple's documentation:
//   - `LiveActivityIntent`: "the system launches your app process
//     without opening the app, performs the intent, and starts the
//     Live Activity … people might place a control in Control Center
//     that performs a LiveActivityIntent … without opening your app."
//     That is what makes `perform()` run in the APP process (where the
//     one real `RecordingController` lives) instead of the widget
//     extension's, for every surface.
//   - `AudioRecordingIntent`: tells the system this app records audio
//     (recording indicator, mic elevation). Apple: a Live Activity must
//     stay active for the whole recording or the recording is stopped —
//     `RecordingController.start()` starts one before `perform()`
//     returns.
//   - `supportedModes` (iOS 26; replaces the deprecated
//     `openAppWhenRun`, which on iOS 26 devices behaves like
//     `.foreground(.immediate)` — it opened and unlocked the phone on
//     every tap): `.background` first, `.foreground(.dynamic)` only so
//     a START with no microphone permission can bring the app forward
//     to its permission UI instead of failing silently (backlog C-1).
//

import AppIntents
import Foundation

public enum RecordingIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case microphoneDenied

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady: return "Daisy isn’t ready yet — open the app once first."
        case .microphoneDenied: return "Daisy needs microphone access. Enable it in Settings."
        }
    }
}

/// `LiveActivityIntent` is iOS-only; the package also builds for macOS
/// (`swift test` on the Mac, and the Mac app links DaisyDesign), where
/// the plain protocol stands in. The intents themselves are gated to
/// iOS 26 / macOS 26 because the package floor is macOS 14 (E-1).
#if os(macOS)
public typealias AppProcessIntent = AppIntent
#else
public typealias AppProcessIntent = LiveActivityIntent
#endif

@available(iOS 26, macOS 26, *)
private extension AppIntent {
    /// backlog C-1: no microphone permission → open the app (its Record
    /// screen asks for it / explains the Settings toggle) rather than
    /// doing nothing. With permission already granted this is a no-op
    /// and the intent stays in the background.
    @MainActor
    func openAppIfMicrophoneAccessMissing(_ controller: any RecordingControlling) async throws {
        guard !controller.microphoneAccessGranted else { return }
        try await continueInForeground(IntentDialog("Daisy needs microphone access."), alwaysConfirm: false)
    }
}

@available(iOS 26, macOS 26, *)
public struct StartRecordingIntent: AudioRecordingIntent, AppProcessIntent {
    public static var title: LocalizedStringResource { "Start Recording" }
    public static var description: IntentDescription { IntentDescription("Starts a Daisy recording from the microphone.") }
    public static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let controller = RecordingBridge.controller else { throw RecordingIntentError.appNotReady }
        guard !controller.isRecording else {
            return .result(dialog: "Already recording.")
        }
        try await openAppIfMicrophoneAccessMissing(controller)
        guard await controller.startRecording() else { throw RecordingIntentError.microphoneDenied }
        return .result(dialog: "Recording started.")
    }
}

@available(iOS 26, macOS 26, *)
public struct StopRecordingIntent: AppProcessIntent {
    public static var title: LocalizedStringResource { "Stop Recording" }
    public static var description: IntentDescription { IntentDescription("Stops the current Daisy recording.") }
    public static let supportedModes: IntentModes = .background

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentBreadcrumb.log("Stop perform: mode=\(String(describing: systemContext.currentMode)) controller=\(RecordingBridge.controller != nil)")
        guard let controller = RecordingBridge.controller else { throw RecordingIntentError.appNotReady }
        guard controller.isRecording else {
            return .result(dialog: "Nothing is recording.")
        }
        await controller.stopRecording()
        IntentBreadcrumb.log("Stop: done")
        return .result(dialog: "Recording stopped.")
    }
}

/// What every widget button and the Control Widget use (backlog C-1:
/// one intent, not two). The button takes its displayed state from the
/// snapshot; this intent takes the ACTUAL current state from
/// `RecordingController` and does whichever direction applies.
/// `toggleRecording()` on the controller side owns the two-fast-taps
/// guarantee — a second overlapping `perform()` is exactly the case it
/// has to cover, so this intent does not debounce anything itself.
@available(iOS 26, macOS 26, *)
public struct ToggleRecordingIntent: AudioRecordingIntent, AppProcessIntent {
    public static var title: LocalizedStringResource { "Toggle Daisy Recording" }
    public static var description: IntentDescription { IntentDescription("Starts a Daisy recording, or stops the one in progress.") }
    public static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentBreadcrumb.log("Toggle perform: mode=\(String(describing: systemContext.currentMode)) controller=\(RecordingBridge.controller != nil)")
        guard let controller = RecordingBridge.controller else {
            IntentBreadcrumb.log("Toggle: no controller in this process → appNotReady")
            throw RecordingIntentError.appNotReady
        }
        do {
            if !controller.isRecording {
                try await openAppIfMicrophoneAccessMissing(controller)
            }
            // Report the REAL resulting state — a debounced duplicate tap
            // returns whatever is actually true right now, not a guess.
            let nowRecording = await controller.toggleRecording()
            IntentBreadcrumb.log("Toggle: done, isRecording=\(nowRecording)")
            return .result(dialog: nowRecording ? "Recording started." : "Recording stopped.")
        } catch {
            IntentBreadcrumb.log("Toggle: threw \(error)")
            throw error
        }
    }
}

/// The Live Activity's pause/resume button (backlog 5 E-2a). Background,
/// app process — the pause lands in the recorder, and from there in the
/// snapshot every widget and the Control Center control read.
@available(iOS 26, macOS 26, *)
public struct PauseResumeRecordingIntent: AppProcessIntent {
    public static var title: LocalizedStringResource { "Pause or Resume Daisy Recording" }
    public static var description: IntentDescription { IntentDescription("Pauses the recording in progress, or resumes a paused one.") }
    public static let supportedModes: IntentModes = .background

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let controller = RecordingBridge.controller else { throw RecordingIntentError.appNotReady }
        guard controller.isRecording else {
            return .result(dialog: "Nothing is recording.")
        }
        await controller.togglePause()
        return .result(dialog: controller.isPaused ? "Recording paused." : "Recording resumed.")
    }
}

/// Siri phrases ("Hey Siri, start Daisy recording") and the Shortcuts
/// app entries — both come from this one declaration, no extra UI code.
@available(iOS 26, macOS 26, *)
public struct DaisyShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start \(.applicationName) recording",
                "Start recording in \(.applicationName)",
            ],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "Stop \(.applicationName) recording",
                "Stop recording in \(.applicationName)",
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: [
                "Toggle \(.applicationName) recording",
            ],
            shortTitle: "Toggle Recording",
            systemImageName: "record.circle"
        )
    }
}
