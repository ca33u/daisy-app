// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  TranscriptTimecode.swift
//  Daisy
//
//  The `[mm:ss · Speaker]` stamp at the head of every transcript line,
//  treated as a coordinate rather than decoration.
//
//  It is the only per-line anchor the transcript has. The body is one
//  monolithic NSTextView — there are no row views to hang a control on —
//  so navigation between a moment in the conversation and the screenshot
//  taken around it has to go through the text itself: parse the stamp on
//  render, attach a `daisy-time://<seconds>` link to it, and read it back
//  from the attributed string when something needs to jump.
//
//  The stamps come from `MarkdownExporter`, which writes
//  `**[m:ss · Label]**` (hours appear only past the hour mark), so the
//  parser accepts both `m:ss` and `h:mm:ss`.
//

import AppKit
import Foundation

nonisolated enum TranscriptTimecode {
    static let scheme = "daisy-time"

    /// A parsed stamp: where the time sits inside the segment, and the
    /// link to attach to it.
    struct Stamp {
        /// Range of the TIME text within the segment — not the whole
        /// bracket. Linking `[12:34 · Maria]` end to end would make the
        /// speaker's name a navigation control, which it isn't.
        let range: NSRange
        let seconds: Double
        var url: URL { URL(string: "\(scheme)://\(Int(seconds.rounded()))")! }
    }

    /// Parse a leading `[m:ss …` / `[h:mm:ss …` out of a bold segment.
    /// Returns nil for anything else, which is every bold run that isn't
    /// a transcript stamp (headings, emphasised words in a summary).
    static func leadingStamp(in segment: String) -> Stamp? {
        guard segment.hasPrefix("[") else { return nil }
        // Up to the separator the exporter writes, or the closing
        // bracket when a line somehow has no speaker label.
        let afterBracket = segment.dropFirst()
        guard let end = afterBracket.firstIndex(where: { $0 == " " || $0 == "]" }) else { return nil }
        let timeText = String(afterBracket[afterBracket.startIndex..<end])
        guard let seconds = parse(timeText) else { return nil }
        // NSRange over UTF-16, which is what NSAttributedString indexes
        // by; the stamp is ASCII, but the segment may not be.
        return Stamp(range: NSRange(location: 1, length: timeText.utf16.count), seconds: seconds)
    }

    /// `"12:34"` / `"1:02:03"` → seconds. Nil for anything that isn't
    /// two or three colon-separated integers.
    static func parse(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0
        for part in parts {
            // Bounded per component, because the input is a FILE the user
            // is encouraged to keep and edit (transcript.md, often in an
            // Obsidian vault). Swift's `*` traps on overflow, so a
            // hand-mangled stamp like `[200000000000000000:00 · X]` would
            // crash the app on opening that session rather than simply
            // failing to parse. 24 hours is past any meeting Daisy can
            // record.
            guard let value = Int(part), (0..<86_400).contains(value) else { return nil }
            total = total * 60 + value
        }
        return Double(total)
    }

    /// Seconds carried by a link value from `NSTextViewDelegate`, which
    /// hands over either a `URL` or a `String` depending on how the
    /// attribute was set.
    static func seconds(fromLink link: Any) -> Double? {
        let string: String?
        switch link {
        case let url as URL:    string = url.scheme == scheme ? url.host : nil
        case let text as String: string = URL(string: text).flatMap { $0.scheme == scheme ? $0.host : nil }
        default:                string = nil
        }
        return string.flatMap(Double.init)
    }

    /// Range of the stamp covering `seconds` — the LAST one at or before
    /// it, which is the line being spoken at that moment. Falls back to
    /// the first stamp when the target predates every line (a screenshot
    /// taken before anyone spoke).
    static func range(at seconds: Double, in storage: NSAttributedString) -> NSRange? {
        var best: NSRange?
        var bestSeconds = -Double.infinity
        var first: NSRange?
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.link, in: full) { value, range, _ in
            guard let value, let stamp = self.seconds(fromLink: value) else { return }
            if first == nil { first = range }
            if stamp <= seconds, stamp > bestSeconds {
                bestSeconds = stamp
                best = range
            }
        }
        return best ?? first
    }
}
