//
//  TranscriptSegment.swift
//  DaisyCore
//
//  Copied from daisy-app/Daisy/Transcriber.swift (`SegmentSource` +
//  `TranscriptSegment`, macOS Daisy 1.0.7.72, 2026-09-19). The value type
//  only — the Mac `Transcriber` class (live windows, commit logic) stays
//  on the Mac. `speakerLabel(displayName:)` is verbatim: it is what the
//  transcript body's `**[m:ss · Name]**` prefix is built from.
//

import Foundation

public nonisolated enum SegmentSource: String, Sendable, Codable, Equatable {
    case microphone
    case systemAudio
}

// Codable since backlog 12 L-1: a long decode checkpoints its finished
// segments to disk after every block, so a job killed by the system
// resumes where it was instead of starting the meeting again.
public nonisolated struct TranscriptSegment: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public let startedAt: Date
    public var text: String
    public var isFinal: Bool
    public var source: SegmentSource = .microphone
    /// Diarization label inside the same `source` stream — e.g. "A",
    /// "B", "C". `nil` while diarization is still running or if it
    /// failed. UI presents this as "Remote A" / "Remote B" for
    /// system-source segments and "Me" for microphone (we assume one
    /// speaker on the mic side).
    public var speakerId: String? = nil
    /// Absolute end time in seconds since the session started.
    public var endSec: Double = 0
    /// Absolute start time in seconds since the session started.
    public var startSec: Double = 0

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        text: String,
        isFinal: Bool = true,
        source: SegmentSource = .microphone,
        speakerId: String? = nil,
        startSec: Double = 0,
        endSec: Double = 0
    ) {
        self.id = id
        self.startedAt = startedAt
        self.text = text
        self.isFinal = isFinal
        self.source = source
        self.speakerId = speakerId
        self.startSec = startSec
        self.endSec = endSec
    }

    /// Human-facing speaker label combining the source stream with
    /// the diarized speaker id.
    public var speakerLabel: String { speakerLabel(displayName: nil) }

    /// Speaker label with an optional override for the user's own
    /// voice. Pass the configured display name to substitute `"Me"`
    /// with the real name; pass nil/empty to keep the generic label.
    /// System-source labels are unaffected — that's the remote
    /// party's voice, not the user's.
    public func speakerLabel(displayName: String?) -> String {
        switch source {
        case .microphone:
            // Display name wins for the mic stream — always (Mac
            // regression 2026-05-22: a diarized mic cluster must not
            // hide the user's own name).
            let trimmed = (displayName ?? "").trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
            if let id = speakerId { return "Speaker \(id)" }
            return "Me"
        case .systemAudio:
            if let id = speakerId { return "Remote \(id)" }
            return "Remote"
        }
    }
}
