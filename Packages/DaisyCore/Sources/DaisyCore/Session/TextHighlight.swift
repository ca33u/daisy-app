//
//  TextHighlight.swift
//  DaisyCore
//
//  backlog 13, Egor 2026-09-23: mark a word or a sentence in a
//  transcript the way one marks a line in a book, and have it stay
//  marked.
//
//  **The mark is `==text==`.** Reasons, in order:
//   • it is text, so it survives everything a transcript survives —
//     the sync, a re-transcription that keeps edits (§7.2), a file
//     opened in any editor;
//   • it is what Obsidian means by a highlight, and a Daisy library
//     usually lives in an Obsidian vault;
//   • a reader that knows nothing about it shows `==like this==`,
//     which is ugly but never wrong, and never loses the words.
//
//  What it is NOT: a colour. One mark, one meaning — "this matters".
//  Colours would need a legend nobody agreed on, and a second reader
//  would have to guess what red meant.
//
//  Rules kept small on purpose: marks never nest, never span a segment
//  line (a highlight is inside one utterance), and toggling twice
//  leaves the text exactly as it was.
//

import Foundation

public nonisolated enum TextHighlight {
    public static let marker = "=="

    /// Ranges of the HIGHLIGHTED text inside `text`, without the
    /// markers — what a renderer paints.
    public static func ranges(in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var cursor = text.startIndex
        while let open = text.range(of: marker, range: cursor..<text.endIndex) {
            guard let close = text.range(of: marker, range: open.upperBound..<text.endIndex) else { break }
            // An empty `====` marks nothing; skip it rather than paint
            // a zero-width box.
            if open.upperBound < close.lowerBound {
                out.append(open.upperBound..<close.lowerBound)
            }
            cursor = close.upperBound
        }
        return out
    }

    /// The text with the markers removed — for anything that reads the
    /// words rather than showing them (summary, search, the speaker
    /// map's find-and-replace).
    public static func stripped(_ text: String) -> String {
        text.replacingOccurrences(of: marker, with: "")
    }

    /// Put a highlight on `range`, or take it off if it is already
    /// highlighted. Returns the new text and where the same words now
    /// sit, so a caller can keep the selection on screen.
    ///
    /// The range is trimmed of surrounding spaces first: a person
    /// double-taps a word and gets the word plus a trailing space, and
    /// `==word ==` renders with a gap nobody asked for.
    public static func toggle(in text: String, range: NSRange) -> (text: String, range: NSRange) {
        let ns = text as NSString
        var selection = range
        guard selection.location >= 0, selection.location + selection.length <= ns.length else { return (text, range) }
        // Trim whitespace at both ends of the selection.
        while selection.length > 0, isSpace(ns.character(at: selection.location)) {
            selection.location += 1
            selection.length -= 1
        }
        while selection.length > 0, isSpace(ns.character(at: selection.location + selection.length - 1)) {
            selection.length -= 1
        }
        guard selection.length > 0 else { return (text, range) }

        // Already inside a highlight? Then this is "unmark".
        if let existing = enclosingHighlight(in: text, at: selection) {
            let opened = NSRange(location: existing.location - marker.count, length: marker.count)
            let closed = NSRange(location: existing.location + existing.length, length: marker.count)
            var updated = ns.replacingCharacters(in: closed, with: "") as NSString
            updated = updated.replacingCharacters(in: opened, with: "") as NSString
            return (updated as String, NSRange(location: existing.location - marker.count, length: existing.length))
        }

        let marked = marker + ns.substring(with: selection) + marker
        let updated = ns.replacingCharacters(in: selection, with: marked)
        return (updated, NSRange(location: selection.location + marker.count, length: selection.length))
    }

    /// The highlighted span that contains `range`, in the text WITH
    /// markers — nil when the selection is not inside one.
    public static func enclosingHighlight(in text: String, at range: NSRange) -> NSRange? {
        let ns = text as NSString
        for span in ranges(in: text) {
            let nsSpan = NSRange(span, in: text)
            if range.location >= nsSpan.location,
               range.location + range.length <= nsSpan.location + nsSpan.length {
                return nsSpan
            }
        }
        _ = ns
        return nil
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 32 || unit == 10 || unit == 9
    }
}
