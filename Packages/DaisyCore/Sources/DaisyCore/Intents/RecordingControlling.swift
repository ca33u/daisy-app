//
//  RecordingControlling.swift
//  DaisyCore
//
//  The seam between the App Intents (this package, so the widget
//  extension can reference them too — an extension cannot import the
//  host app's own module) and the ONE real recorder living in the app
//  process. The intents are `LiveActivityIntent`s (RecordingIntents.swift),
//  which is what makes iOS launch the app process itself — without
//  opening the app — to execute `perform()`; so by the time `perform()`
//  runs, `RecordingBridge.controller` was already set, in that SAME app
//  process, by `AppModel.init()` (which runs on any launch, headless or
//  not).
//

import Foundation

@MainActor
public protocol RecordingControlling: AnyObject {
    var isRecording: Bool { get }
    /// backlog 5 E-2a: pause is a state every surface shows, not a button.
    var isPaused: Bool { get }
    /// Pause if recording, resume if paused; nothing when idle.
    func togglePause() async
    /// Whether microphone access is already granted. The intents use
    /// this to decide whether a START can stay in the background or has
    /// to bring the app forward to ask for it (backlog C-1).
    var microphoneAccessGranted: Bool { get }
    /// Starts recording. Returns false on failure (e.g. microphone denied).
    func startRecording() async -> Bool
    func stopRecording() async
    /// Starts if idle, stops if recording — backlog C-1: ONE entry
    /// point for anything that doesn't already know which direction to
    /// go (every widget button, the Control Widget, the Siri toggle).
    /// Must be safe against two fast taps landing as two overlapping
    /// calls — the conformer, not the caller, owns that guarantee.
    /// Returns the resulting `isRecording`.
    @discardableResult
    func toggleRecording() async -> Bool
}

@MainActor
public enum RecordingBridge {
    public static weak var controller: (any RecordingControlling)?
}
