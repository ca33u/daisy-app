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

    /// What was said in a stored meeting, for another place (Notion,
    /// Claude): what's under `## Transcript`, stamps and labels kept, up to
    /// the screen text after it, then what the person said over the moments
    /// they marked (cut from the transcript, kept only in its own section).
    /// A stored `transcriptText` is the whole document, and sent whole it
    /// repeated the summary as raw Markdown and carried the screenshots'
    /// paths on this Mac (review 23.11). Links to images are left out
    /// wherever they stand.
    ///
    /// A document without the heading (a recovered recording's «Your side»,
    /// a note, a hand-edited file) is all its own text: only the title line,
    /// the «recorded» line and the three sections that are never speech go.
    static func exportBody(_ transcript: String) -> String {
        let lines = transcript.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let heading = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "## Transcript" }
        var body = heading.map { Array(lines[($0 + 1)...]) } ?? droppingDocumentHeader(lines)
        var moments: [String] = []
        if let heading { moments = markedMoments(in: lines[..<heading]) }
        body = outsideSkippedSections(body).compactMap(withoutImages)
        let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !moments.isEmpty else { return text }
        let said = moments.joined(separator: "\n\n")
        return text.isEmpty ? said : text + "\n\n" + said
    }

    private static func droppingDocumentHeader(_ lines: [String]) -> [String] {
        var rest = lines[...]
        func isBlank(_ line: String?) -> Bool { line?.allSatisfy(\.isWhitespace) ?? false }
        while isBlank(rest.first) { rest.removeFirst() }
        if rest.first?.hasPrefix("# ") == true { rest.removeFirst() }
        while isBlank(rest.first) { rest.removeFirst() }
        if rest.first?.hasPrefix("> recorded") == true { rest.removeFirst() }
        return Array(rest)
    }

    private static func outsideSkippedSections(_ lines: [String]) -> [String] {
        var skipping = false
        return lines.filter { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") { skipping = nonSpeechSections.contains(line) }
            return !skipping
        }
    }

    /// «- **[0:12]** what was said — ![0:12](path)» without the list mark
    /// and the frame; a moment nothing was said over is left out.
    private static func markedMoments(in lines: ArraySlice<String>) -> [String] {
        var inside = false
        return lines.compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                inside = line == "## Marked moments"
                return nil
            }
            guard inside, let entry = line.wholeMatch(of: #/- (\*\*\[[^\]]*\]\*\*)(.*)/#) else { return nil }
            var note = String(entry.2).replacing(imageLink, with: "").trimmingCharacters(in: .whitespaces)
            if note.hasSuffix("—") { note = String(note.dropLast()).trimmingCharacters(in: .whitespaces) }
            return note.isEmpty ? nil : "\(entry.1) \(note)"
        }
    }

    /// Nil for a line that was nothing but images.
    private static func withoutImages(_ raw: String) -> String? {
        let line = raw.replacing(imageLink, with: "")
        return line != raw && line.allSatisfy(\.isWhitespace) ? nil : line
    }

    /// A path may hold a pair of parentheses («Daisy (1)»).
    private static var imageLink: Regex<Substring> { #/!\[[^\]]*\]\((?:[^()]|\([^()]*\))*\)/# }

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
