//
//  VoiceNoteRecognition.swift
//  DaisyCore
//
//  A Mac voice note, as its files say (session-format.md §3.4 «Voice
//  notes (Mac)», Egor 07.11.2026) — one source of truth for both apps. The
//  Mac reads it to summarize a voice note in its author's voice and to
//  keep it behind its own gate; the phone, to keep a Mac voice note's
//  summary out of what it sends to its provider about other sessions
//  (`PhoneProjectMemory`), since the Mac's gate isn't known there.
//

import Foundation

public nonisolated enum VoiceNoteRecognition: Sendable, Equatable {
    case none
    /// Carries `daisy_voice_note: true`: recorded by a Mac build that
    /// writes the key (2026-11-07 on).
    case marked
    /// A voice note from before the key, known by its shape.
    case byShape

    public var isVoiceNote: Bool { self != .none }

    /// The key, written only as `true` and only beside `daisy_kind: note`.
    public static let frontmatterKey = "daisy_voice_note"
    /// The other note profiles' markers (§3.4).
    public static let otherNoteMarkers: Set<String> = ["daisy_screenshot_note", "daisy_document_note", "daisy_text_note"]
    /// A side note's back-link to its meeting: an excerpt, not a voice note.
    public static let sourceMeetingKey = "daisy_source_meeting"

    /// The rule. `isNote`: the session's kind is `note` (or, from before
    /// `daisy_kind`, it sits in `notes`); `marker`: the raw value of the
    /// key when present; `otherNoteProfile`: another note marker is `true`
    /// or `daisy_source_meeting` is set; `origin`: `daisy_origin`.
    ///
    /// The kind decides first: a session filed as a recording is one. A
    /// room recording (any origin but `mac`, §3.6) is never the owner
    /// thinking aloud. The key settles the rest; without it, the shape: a
    /// length, nothing captured from the other side (a meeting filed as a
    /// note has a system-audio status other than `off`), and a
    /// `## Transcript` heading.
    public static func recognise(isNote: Bool, marker: String?, otherNoteProfile: Bool, origin: String?,
                                 systemAudioStatus: String?, durationSec: Int, body: String) -> VoiceNoteRecognition {
        guard isNote, !otherNoteProfile, !SessionOrigin.isRoomMicrophone(origin) else { return .none }
        if let marker { return isTrue(marker) ? .marked : .none }
        guard durationSec > 0, systemAudioStatus?.trimmingCharacters(in: .whitespaces) == "off",
              hasTranscriptHeading(body) else { return .none }
        return .byShape
    }

    /// The same from a whole `transcript.md`.
    public static func recognise(transcriptMarkdown: String) -> VoiceNoteRecognition {
        let parsed = SessionDocument.parseFrontmatter(in: transcriptMarkdown)
        let kind = parsed.kind?.lowercased()
        let isNote = kind == SessionKind.note.rawValue
            || (kind == nil && parsed.folder?.lowercased() == "notes")
        let otherNote = otherNoteMarkers.contains { parsed[$0].map(isTrue) ?? false }
            || !(parsed[sourceMeetingKey] ?? "").isEmpty
        return recognise(isNote: isNote, marker: parsed[frontmatterKey], otherNoteProfile: otherNote,
                         origin: parsed["daisy_origin"], systemAudioStatus: parsed.systemAudioStatus,
                         durationSec: parsed.durationSec ?? 0, body: parsed.body)
    }

    /// `true`, as frontmatter writes it (bare or quoted, any case).
    public static func isTrue(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased() == "true"
    }

    /// The literal heading every renderer writes, never localized (§3.3).
    public static func hasTranscriptHeading(_ body: String) -> Bool {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "## Transcript" }
    }
}
