//
//  RecordingIntentsTests.swift
//  DaisyCoreTests
//
//  Backlog C-1: locks the properties that make tap-to-record work
//  WITHOUT opening the app — `LiveActivityIntent` (perform() runs in
//  the app process, app not opened), `AudioRecordingIntent` on the
//  start paths, and `supportedModes` preferring the background.
//

import Testing
import Foundation
import AppIntents
@testable import DaisyCore

/// Compile-time conformance checks — stronger than any runtime `is`.
@available(iOS 26, macOS 26, *)
private func requireAudioRecordingIntent<T: AudioRecordingIntent>(_ type: T.Type) {}
@available(iOS 26, macOS 26, *)
private func requireAppProcessIntent<T: AppProcessIntent>(_ type: T.Type) {}

@Suite("Recording intents")
struct RecordingIntentsTests {
    @Test func startAndToggleRecordAudioAndRunInTheAppProcess() {
        guard #available(iOS 26, macOS 26, *) else { return }
        requireAudioRecordingIntent(StartRecordingIntent.self)
        requireAudioRecordingIntent(ToggleRecordingIntent.self)
        requireAppProcessIntent(StartRecordingIntent.self)
        requireAppProcessIntent(ToggleRecordingIntent.self)
        #expect(StartRecordingIntent.supportedModes.contains(.background))
        #expect(ToggleRecordingIntent.supportedModes.contains(.background))
    }

    @Test func stopRunsInTheAppProcessInTheBackgroundOnly() {
        guard #available(iOS 26, macOS 26, *) else { return }
        // The Live Activity's Stop button must reach the app's recorder,
        // and never bring the app forward.
        requireAppProcessIntent(StopRecordingIntent.self)
        #expect(StopRecordingIntent.supportedModes == .background)
    }

    @Test func shortcutsCoverAllThreeIntents() {
        guard #available(iOS 26, macOS 26, *) else { return }
        let shortcuts = DaisyShortcuts.appShortcuts
        #expect(shortcuts.count == 3)
    }
}

@Suite("RecordingSnapshot timer anchor")
struct RecordingSnapshotTests {
    @Test func timerAnchorShiftsBackByAccumulated() {
        let ref = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = RecordingSnapshot(isPaused: false, accumulated: 90, referenceDate: ref)
        #expect(snapshot.timerAnchor == ref.addingTimeInterval(-90))
    }

    @Test func librarySnapshotIsRecordingReflectsRecordingField() {
        var snapshot = LibrarySnapshot.empty
        #expect(!snapshot.isRecording)
        snapshot.recording = RecordingSnapshot(isPaused: false, accumulated: 0, referenceDate: Date())
        #expect(snapshot.isRecording)
    }

    @Test func snapshotRoundTripsThroughJSONWithRecordingField() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let recording = RecordingSnapshot(isPaused: true, accumulated: 42, referenceDate: Date(timeIntervalSince1970: 500_000))
        let snapshot = LibrarySnapshot(updatedAt: Date(timeIntervalSince1970: 500_100), recent: [], pendingTranscriptionCount: 2, recording: recording)
        LibrarySnapshotStore.write(snapshot, toContainer: dir)
        let read = LibrarySnapshotStore.read(fromContainer: dir)
        #expect(read.recording?.isPaused == true)
        #expect(read.recording?.accumulated == 42)
        #expect(read.pendingTranscriptionCount == 2)
        #expect(read.isRecording)
    }
}
