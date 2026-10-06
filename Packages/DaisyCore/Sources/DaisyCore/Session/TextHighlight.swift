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

    /// What a selection can do to a highlight — what the menu's icon
    /// has to say before the person taps it.
    public enum State: Equatable {
        /// Nothing highlighted here: the action adds one.
        case canHighlight
        /// The selection is a highlight (exactly, partly, or including
        /// its `==` markers): the action removes THAT one, whose span
        /// in the text-with-markers is carried here.
        case canRemove(NSRange)
    }

    /// The highlight the selection touches, if any. Deliberately
    /// generous: selecting the words, selecting half of them, or
    /// selecting them together with the `==` markers (which is what a
    /// triple tap or a drag gives you) all mean the same thing to a
    /// person — "this bit, the marked one".
    public static func state(in text: String, range: NSRange) -> State {
        let ns = text as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return .canHighlight }
        let selectionEnd = range.location + range.length
        for span in ranges(in: text) {
            let inner = NSRange(span, in: text)
            // The span including its markers — what the person sees as
            // the highlighted phrase when the markers are on screen.
            let outer = NSRange(location: inner.location - marker.count,
                                length: inner.length + marker.count * 2)
            let touchesInner = range.length > 0
                ? selectionEnd > inner.location && range.location < inner.location + inner.length
                : range.location >= inner.location && range.location <= inner.location + inner.length
            let insideOuter = range.location >= outer.location && selectionEnd <= outer.location + outer.length
            if touchesInner || insideOuter { return .canRemove(inner) }
        }
        return .canHighlight
    }

    /// Put a highlight on `range`, or take it off if the selection
    /// touches one. Returns the new text and where the same words now
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

        // Touching a highlight at all? Then this is "unmark" — never
        // "add another one inside it": `====nested====` is not a thing,
        // and a selection that includes the markers used to produce
        // exactly that (found 2026-09-23).
        if case .canRemove(let existing) = state(in: text, range: range) {
            let opened = NSRange(location: existing.location - marker.count, length: marker.count)
            let closed = NSRange(location: existing.location + existing.length, length: marker.count)
            var updated = ns.replacingCharacters(in: closed, with: "") as NSString
            updated = updated.replacingCharacters(in: opened, with: "") as NSString
            return (updated as String, NSRange(location: existing.location - marker.count, length: existing.length))
        }

        // §3.3: a highlight lives inside one segment line and never in
        // its stamp. A selection dragged across lines is cut at the end
        // of its first line; one that starts in `**[m:ss · Name]** ` is
        // moved past the stamp — the alternative was `==` straddling a
        // line break, after which the line stopped parsing as a segment.
        selection = withinOneLine(selection, in: ns)
        guard selection.length > 0 else { return (text, range) }

        let marked = marker + ns.substring(with: selection) + marker
        let updated = ns.replacingCharacters(in: selection, with: marked)
        return (updated, NSRange(location: selection.location + marker.count, length: selection.length))
    }

    static func withinOneLine(_ range: NSRange, in ns: NSString) -> NSRange {
        var out = range
        // Cut at the first line break inside the selection.
        let newline = ns.rangeOfCharacter(from: .newlines, options: [], range: out)
        if newline.location != NSNotFound { out.length = newline.location - out.location }
        // Past the stamp, when the selection starts inside it.
        let lineStart = ns.lineRange(for: NSRange(location: out.location, length: 0)).location
        let line = ns.substring(with: NSRange(location: lineStart, length: ns.length - lineStart))
        let close = (line as NSString).range(of: "]** ")
        if line.hasPrefix("**["), close.location != NSNotFound {
            let textStart = lineStart + close.location + close.length
            if out.location < textStart {
                let end = out.location + out.length
                out = NSRange(location: textStart, length: max(0, end - textStart))
            }
        }
        // Trim again: the cut may have left a space at the edge.
        while out.length > 0, isSpace(ns.character(at: out.location)) { out.location += 1; out.length -= 1 }
        while out.length > 0, isSpace(ns.character(at: out.location + out.length - 1)) { out.length -= 1 }
        return out
    }

    /// The highlight this selection would remove, if any.
    public static func enclosingHighlight(in text: String, at range: NSRange) -> NSRange? {
        if case .canRemove(let span) = state(in: text, range: range) { return span }
        return nil
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 32 || unit == 10 || unit == 9
    }
}
