//
//  TranscriptDocument.swift
//  DaisyCore
//
//  The body of `transcript.md` (session-format.md §3.3) for a session
//  the phone finished itself: `# <title>`, the recorded-on quote, then
//  `## Transcript` with one `**[m:ss · Name]** text` line per segment.
//  No Summary / Screenshots / Marked moments sections — the phone has
//  none, and an empty heading is worse than no heading.
//
//  Shape and helpers follow the Mac `MarkdownExporter.renderBody`
//  (1.0.7.72): timestamps `m:ss` / `h:mm:ss`, the separator is `·`
//  (U+00B7) with a space on each side, the microphone stream carries the
//  user's display name or `Me`. `## Transcript` is NEVER translated —
//  the Mac's audio-retention sweep finds real content by that literal.
//

import Foundation

public nonisolated enum TranscriptDocument {
    /// The literal heading the retention sweep looks for. Never localize.
    public static let transcriptHeading = "## Transcript"
    /// §3.3: frames live in their own section, above the transcript —
    /// never inside it. The phone writes it since backlog 13 М-2 so the
    /// photos survive leaving the app (the Mac has always read it).
    public static let screenshotsHeading = "## Screenshots"

    /// Full `transcript.md` text: frontmatter + body.
    public static func render(
        frontmatter: SessionFrontmatter,
        segments: [TranscriptSegment],
        userDisplayName: String?,
        screenshots: [String: Double] = [:]
    ) -> String {
        var lines = frontmatter.renderLines()
        lines.append("")
        // The subtitle must read the same duration `duration_sec` names
        // (§3.1: truncated, not rounded) — pass the ALREADY-TRUNCATED
        // integer, not `frontmatter.duration`, so "· 0:41" can never
        // appear next to `duration_sec: 41` while the raw value (say
        // 41.98s) would round the subtitle up to "· 0:42" (bug found in
        // the night-1 report, backlog B-1).
        lines.append(contentsOf: bodyLines(
            title: frontmatter.title,
            started: frontmatter.started,
            duration: TimeInterval(frontmatter.durationSec),
            segments: segments,
            userDisplayName: userDisplayName,
            screenshots: screenshots
        ))
        return lines.joined(separator: "\n")
    }

    /// Body only, from `# title` on.
    public static func bodyLines(
        title: String,
        started: Date?,
        duration: TimeInterval,
        segments: [TranscriptSegment],
        userDisplayName: String?,
        screenshots: [String: Double] = [:]
    ) -> [String] {
        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        if let started {
            lines.append("> recorded \(humanDate(started)) · \(formatDuration(duration))")
            lines.append("")
        }
        // §3.3 order: Screenshots before Transcript. Timecodes come
        // from `index.json`; a stamp past the duration means the frame
        // was attached later (§7.6) and is rendered as such, never as a
        // position in the conversation.
        if !screenshots.isEmpty {
            lines.append(screenshotsHeading)
            lines.append("")
            let ordered = screenshots.sorted { lhs, rhs in
                ScreenshotIndex.number(of: lhs.key) ?? 0 < ScreenshotIndex.number(of: rhs.key) ?? 0
            }
            for (file, offset) in ordered {
                let label = duration > 0 && offset > duration
                    ? String(localized: "added later")
                    : formatDuration(max(0, offset))
                lines.append("![\(label)](screenshots/\(file))")
            }
            lines.append("")
        }
        lines.append(transcriptHeading)
        lines.append("")
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let label = segment.speakerLabel(displayName: userDisplayName)
            lines.append("**[\(formatDuration(max(0, segment.startSec))) · \(label)]** \(text)")
            lines.append("")
        }
        return lines
    }

    /// Does this body carry a real transcript — at least one non-empty
    /// line after the literal heading (§7.4)? Read from the file on disk
    /// by callers, never from a flag.
    public static func hasTranscriptContent(_ markdown: String) -> Bool {
        guard let range = markdown.range(of: "\n\(transcriptHeading)\n") ?? markdown.range(of: "\(transcriptHeading)\n") else {
            return false
        }
        let after = markdown[range.upperBound...]
        return after.split(separator: "\n").contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Words said in a transcript.md: the lines under the Transcript
    /// heading, without the `**[m:ss · Name]**` stamps and without italic
    /// notes («_Nothing was recorded…_»).
    public static func spokenWordCount(_ markdown: String) -> Int {
        var inTranscript = false
        var count = 0
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                inTranscript = line == transcriptHeading
                continue
            }
            guard inTranscript, !line.isEmpty, !line.hasPrefix("_") else { continue }
            var text = line
            while let open = text.range(of: "**["), let close = text.range(of: "]**", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            }
            count += text.split(whereSeparator: \.isWhitespace).filter { $0.contains { $0.isLetter || $0.isNumber } }.count
        }
        return count
    }

    // MARK: - Formatting (Mac `MarkdownExporter`)

    /// `m:ss`, or `h:mm:ss` past an hour. Rounded, as the Mac does for
    /// display timestamps (only `duration_sec` truncates).
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    public static func humanDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// The default title for a session with nothing better —
    /// `Recording — 2026-09-19 08:14`, in the Mac's `yyyy-MM-dd HH:mm`.
    public static func defaultTitle(for date: Date, prefix: String = "Recording") -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(prefix) — \(df.string(from: date))"
    }
}
