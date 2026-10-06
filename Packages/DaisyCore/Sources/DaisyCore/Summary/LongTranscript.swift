//
//  LongTranscript.swift
//  DaisyCore
//
//  A meeting longer than a model's window (backlog 26, 06.10.2026: «влезает
//  ли 8-часовая запись в запрос провайдера» — it does not: eight hours of
//  Russian speech is ~500 000 characters, over the 200k-token window of the
//  models in use and over the proxy's 600 000-character ceiling).
//
//  The usual two-step answer: the transcript is cut into parts at segment
//  boundaries, each part is summarized as a meeting of its own, and the
//  parts' summaries — ledes, sections, next steps — are written out as one
//  short "transcript" that is summarized once more into the meeting's
//  summary. Nothing here calls a model; the caller runs the same
//  summarizer it always runs, once per part and once at the end.
//

import Foundation

public nonisolated enum LongTranscript {
    /// Above this many characters a transcript is summarized in parts.
    /// ~75k tokens of Russian or ~50k of English: well inside every
    /// provider's window with the prompt and the project context on top.
    public static let threshold = 180_000
    /// What one part may hold.
    public static let partLimit = 150_000

    public static func needsParts(_ transcript: String) -> Bool {
        transcript.count > threshold
    }

    /// The transcript in parts of at most `limit` characters, cut only
    /// between segments (a blank line); a single over-long paragraph is
    /// cut where it is. Every part keeps the order and nothing is dropped.
    public static func parts(of transcript: String, limit: Int = partLimit) -> [String] {
        guard transcript.count > limit else { return [transcript] }
        var parts: [String] = []
        var current = ""
        for paragraph in transcript.components(separatedBy: "\n\n") {
            let piece = paragraph.count > limit ? paragraph : paragraph
            if !current.isEmpty, current.count + 2 + piece.count > limit {
                parts.append(current)
                current = ""
            }
            if piece.count > limit {
                // One paragraph longer than a part: cut it at line breaks,
                // then at characters.
                var rest = Substring(piece)
                while !rest.isEmpty {
                    let chunk = rest.prefix(limit)
                    let cut = chunk.lastIndex(of: "\n").map { chunk.index(after: $0) } ?? chunk.endIndex
                    let end = cut > chunk.startIndex ? cut : chunk.endIndex
                    parts.append(String(rest[..<end]))
                    rest = rest[end...]
                }
                continue
            }
            current = current.isEmpty ? piece : current + "\n\n" + piece
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// The parts' summaries as one text for the final pass — in order,
    /// each under its number, so the last summary sees the whole meeting
    /// at a glance and can say what was decided where.
    public static func digest(of summaries: [MeetingSummary]) -> String {
        var lines: [String] = []
        lines.append("[This meeting was summarized in \(summaries.count) consecutive parts because of its length. Below are the parts' summaries, in order. Write the summary of the WHOLE meeting from them: one storyline, decisions and next steps across all parts, no mention of the parts themselves.]")
        for (index, summary) in summaries.enumerated() {
            lines.append("")
            lines.append("## Part \(index + 1) of \(summaries.count)")
            lines.append(summary.summary)
            for section in summary.sections {
                lines.append("")
                lines.append("### \(section.title)")
                for bullet in section.bullets { lines.append(contentsOf: bulletLines(bullet, depth: 0)) }
            }
            if !summary.actionItems.isEmpty {
                lines.append("")
                lines.append("Next steps from this part:")
                for item in summary.actionItems { lines.append("- \(item)") }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func bulletLines(_ bullet: SummaryBullet, depth: Int) -> [String] {
        var out = [String(repeating: "  ", count: depth) + "- " + bullet.text]
        for child in bullet.children { out += bulletLines(child, depth: depth + 1) }
        return out
    }
}
