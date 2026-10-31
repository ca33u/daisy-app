//
//  TranscriptSpeech.swift
//  Daisy
//
//  Whether a transcript holds anything anyone said (31.10). A 79-minute
//  meeting recorded with live transcription off had, until its final
//  pass landed a quarter of an hour later, a transcript of 80 screenshot
//  links and not one spoken line — and Summarize sent it. The model
//  wrote that the meeting's content couldn't be determined, a follow-up
//  asking for the transcript, and the meeting was renamed after that.
//  The silence check (`Summarizer.isEffectivelySilent`) never fired: it
//  counts words, and every `![12:34](…/screenshots/…png)` is three.
//
//  Reads every shape the summarizer is handed: a transcript.md body
//  (`**[m:ss · Name]** text` under `## Transcript`), finalize's
//  in-memory `[Name] text` lines, and either of them with the screen
//  text and the marked moments appended (`ImportTranscriptionQueue.
//  summaryTranscript`). Errs toward "there is speech": a shape it doesn't
//  know counts as text, so nothing real is ever refused a summary.
//

import Foundation

nonisolated enum TranscriptSpeech {
    /// The fence finalize and the queue put before the OCR'd screen text
    /// they append for the summary — shown, not said.
    private static let screenFence = "[Content shared on screen"
    /// How `MomentMarker.summaryLine` opens.
    private static let markersNote = "[The participant flagged"
    /// Sections of a transcript.md that are never speech (session-format
    /// §3.3). `## Transcript` and `## Shared on screen` are literals in
    /// every writer; the other two are too.
    private static let nonSpeechSections: Set<String> = [
        "## Screenshots", "## Marked moments", "## Shared on screen",
    ]

    /// True when at least one line of `transcript` is something someone
    /// said — not a heading, a screenshot link, an italic note such as
    /// «No speech detected.», a bracketed note for the model or the
    /// screen text.
    static func hasSpeech(_ transcript: String) -> Bool {
        spokenLines(in: transcript, stopAtFirst: true).isEmpty == false
    }

    /// The spoken lines alone, stamps and speaker labels removed, joined
    /// by newlines. Empty when nobody said anything.
    static func spokenText(_ transcript: String) -> String {
        spokenLines(in: transcript, stopAtFirst: false).joined(separator: "\n")
    }

    private static func spokenLines(in transcript: String, stopAtFirst: Bool) -> [String] {
        var text = Substring(transcript)
        if let fence = text.range(of: screenFence) {
            text = text[..<fence.lowerBound]
        }
        // `isNewline`, not "\n": in Swift "\r\n" is one Character, and a
        // CRLF file split on "\n" is one line starting with "#".
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        // With a `## Transcript` heading only what's under it is speech
        // (until the screen text appended after it). Without one, every
        // line is a candidate, minus the sections that never are.
        let hasTranscriptHeading = lines.contains { $0.trimmingCharacters(in: .whitespaces) == "## Transcript" }
        var inSpeech = !hasTranscriptHeading
        var inSkippedSection = false
        var spoken: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "## Transcript" {
                inSpeech = true
                inSkippedSection = false
                continue
            }
            if line.hasPrefix("## ") {
                if nonSpeechSections.contains(line) {
                    inSkippedSection = true
                    if hasTranscriptHeading { inSpeech = false }
                } else if !hasTranscriptHeading {
                    inSkippedSection = false
                }
                continue
            }
            guard inSpeech, !inSkippedSection, let words = spokenWords(in: line) else { continue }
            spoken.append(words)
            if stopAtFirst { break }
        }
        return spoken
    }

    /// One line's spoken words, or nil when the line isn't speech.
    private static func spokenWords(in line: String) -> String? {
        guard !line.isEmpty,
              !line.hasPrefix("#"),   // title and other headings
              !line.hasPrefix(">"),   // "> recorded 31 Oct · 79 min"
              !line.hasPrefix("_")    // "_No speech detected._"
        else { return nil }
        // The marked moments' note for the model (`MomentMarker.
        // summaryLine`). By its words, not by its brackets: a spoken line
        // can end in Whisper's own "[laughs]".
        if line.hasPrefix(markersNote) { return nil }
        var text = line.replacing(#/!\[[^\]]*\]\([^)]*\)/#, with: "")
        // transcript.md's stamp: "**[0:07 · Alex]** text".
        text = text.replacing(#/\*\*\[[^\]]*\]\*\*/#, with: "")
        // finalize's in-memory label: "[Alex] text".
        text = text.replacing(#/^\s*\[[^\]]*\]/#, with: "")
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains(where: \.isLetter) else { return nil }
        return trimmed
    }
}
