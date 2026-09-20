//
//  LibrarySnapshot.swift
//  DaisyCore
//
//  What the home/lock-screen widgets (backlog B-5) show, written by the
//  app on every library change and only ever READ by the widget
//  extension — an extension can't (and shouldn't) run
//  `SessionClassifier.scan` itself against a security-scoped folder it
//  has no access ticket for. Lives in the App Group container so both
//  processes can reach the same file.
//

import Foundation

public nonisolated struct LibrarySnapshotRow: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var startedAt: Date
    public var durationSec: Int
    public var hasTranscript: Bool
    public var isInterrupted: Bool

    public init(id: String, title: String, startedAt: Date, durationSec: Int, hasTranscript: Bool, isInterrupted: Bool) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.durationSec = durationSec
        self.hasTranscript = hasTranscript
        self.isInterrupted = isInterrupted
    }
}

/// What the Control Center control and the widgets show (backlog 5
/// E-2a): three states, paused included.
public nonisolated enum RecordingControlState: String, Codable, Sendable {
    case idle
    case recording
    case paused
}

/// The live recording's state, exactly as much as a widget/control
/// needs to render a ticking timer without a per-second push (backlog
/// C-2/C-3): `referenceDate` shifted back by `accumulated` is the
/// anchor `Text(_:style:.timer)` needs, same trick the Live Activity
/// uses. `nil` in `LibrarySnapshot.recording` means "not recording" —
/// the one place every surface (app, widgets, Control Widget) reads
/// that fact from (backlog C-4: one source of truth).
public nonisolated struct RecordingSnapshot: Codable, Sendable, Equatable {
    public var isPaused: Bool
    public var accumulated: TimeInterval
    public var referenceDate: Date

    public init(isPaused: Bool, accumulated: TimeInterval, referenceDate: Date) {
        self.isPaused = isPaused
        self.accumulated = accumulated
        self.referenceDate = referenceDate
    }

    /// The date a ticking `Text(_:style:.timer)` should anchor to.
    public var timerAnchor: Date { referenceDate.addingTimeInterval(-accumulated) }
}

public nonisolated struct LibrarySnapshot: Codable, Sendable, Equatable {
    public var updatedAt: Date
    /// Newest first, already capped to what a widget could ever show.
    public var recent: [LibrarySnapshotRow]
    public var pendingTranscriptionCount: Int
    /// `nil` when idle. Updated on every start/pause/resume/stop — NOT
    /// on every tick, since the timer anchor above already ticks on its
    /// own once rendered.
    public var recording: RecordingSnapshot?

    public init(
        updatedAt: Date, recent: [LibrarySnapshotRow], pendingTranscriptionCount: Int,
        recording: RecordingSnapshot? = nil
    ) {
        self.updatedAt = updatedAt
        self.recent = recent
        self.pendingTranscriptionCount = pendingTranscriptionCount
        self.recording = recording
    }

    public var isRecording: Bool { recording != nil }
    public var controlState: RecordingControlState {
        guard let recording else { return .idle }
        return recording.isPaused ? .paused : .recording
    }

    public static let empty = LibrarySnapshot(updatedAt: .distantPast, recent: [], pendingTranscriptionCount: 0)
}

/// Reads/writes `widget-snapshot.json` in a given App Group container.
/// The app calls `write` after every `refreshLibrary()`; the widget
/// extension only ever calls `read`.
public nonisolated enum LibrarySnapshotStore {
    private static let fileName = "widget-snapshot.json"

    public static func url(inContainer container: URL) -> URL {
        container.appendingPathComponent(fileName)
    }

    public static func write(_ snapshot: LibrarySnapshot, toContainer container: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url(inContainer: container), options: .atomic)
    }

    public static func read(fromContainer container: URL) -> LibrarySnapshot {
        guard let data = try? Data(contentsOf: url(inContainer: container)) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LibrarySnapshot.self, from: data)) ?? .empty
    }
}
