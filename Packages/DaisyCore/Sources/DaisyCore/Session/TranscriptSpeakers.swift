//
//  TranscriptSpeakers.swift
//  DaisyCore
//
//  Бэклог 15 П-3: how many people are actually in a transcript.
//
//  The point is what this is NOT used for. It does not decide whether a
//  recording was "a meeting" or "a note" — that question was dropped
//  because the answer was always a guess and the guess showed up as a
//  switch that changed nothing. It answers a narrower, checkable thing:
//  how many distinct voices the transcript names. A summary that knows
//  there is exactly one voice can stop inventing the other side.
//

import Foundation

public enum TranscriptSpeakers {
    /// Segment lines look like `**[m:ss · Name]** text` (§3.3).
    ///
    /// Built per call rather than held in a `static let`: a `Regex` is
    /// not `Sendable`, and a shared one would be a data race waiting for
    /// two sessions to summarize at once.
    private nonisolated static var line: Regex<(Substring, Substring)> {
        /\*\*\[[^\]]*·\s*([^\]]+)\]\*\*/
    }

    /// Distinct speaker names, in the order they first speak.
    ///
    /// Order matters more than it looks: the first voice in a recording
    /// is usually the person holding the phone, and a caller reading
    /// this wants "who starts" without re-parsing the body.
    public nonisolated static func distinct(inBody body: String) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for raw in body.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let match = raw.firstMatch(of: line) else { continue }
            let name = String(match.1).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            order.append(name)
        }
        return order
    }

    /// True when the transcript names exactly one voice.
    ///
    /// Zero speakers is NOT "one": an empty or unlabelled transcript
    /// tells us nothing, and pretending it is a monologue would apply
    /// the narrower prompt to a meeting whose labels simply failed.
    ///
    /// **This is a fact about the text, not a conclusion about the
    /// room.** Before acting on it, ask `labelsAreMeaningful` —
    /// see the note there.
    public nonisolated static func isSingleVoice(inBody body: String) -> Bool {
        distinct(inBody: body).count == 1
    }

    /// Whether the speaker labels in this transcript carry information
    /// at all.
    ///
    /// Found on a real phone, 2026-09-23: a phone transcript labels
    /// EVERY segment `Me` and ships `daisy_speaker_map: {}`, because
    /// the phone does not diarize — §3.6 calls its transcript a first
    /// pass, not a claim about who spoke. So "one distinct name" is
    /// true of every phone session, a two-person meeting included.
    /// Acting on it there would suppress the attendees and decisions
    /// that were really said — the very failure П-3 exists to prevent,
    /// mirrored.
    ///
    /// Labels mean something only once something has diarized: a
    /// non-empty speaker map, or an explicit `daisy_diarization`.
    public nonisolated static func labelsAreMeaningful(speakerMap: [String: String]?,
                                                       diarization: String?) -> Bool {
        if let diarization, !diarization.isEmpty, diarization != "none" { return true }
        return !(speakerMap?.isEmpty ?? true)
    }
}
