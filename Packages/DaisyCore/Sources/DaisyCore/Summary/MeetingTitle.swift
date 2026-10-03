//
//  MeetingTitle.swift
//  DaisyCore
//
//  A meeting named after what it was about (Egor, 03.10.2026: «встреча
//  после саммаризации меняла название, чтобы понять о чём была речь»).
//
//  The summary's model writes a short `title` beside the summary. It
//  replaces the session's title only while that title is still the one
//  the app made up at the start — «Meeting 2026-10-03 14:20»,
//  «Recording — 2026-10-03 14:20». A title that came from the calendar,
//  from a business card or from the person's own hands is theirs and is
//  never touched.
//

import Foundation

public nonisolated enum MeetingTitle {
    /// The app's own placeholder titles: a known prefix, then the date
    /// and time the recording started (the Mac writes no dash, the phone
    /// writes an em dash).
    public static func isAutomatic(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.wholeMatch(of: /(Meeting|Recording)( —| -)? \d{4}-\d{2}-\d{2} \d{2}:\d{2}/) != nil
    }

    /// What the model wrote, made fit for a title line: one line, no
    /// wrapping quotes, no trailing period, not longer than a row shows.
    /// nil when nothing usable is left.
    public static func cleaned(_ raw: String?) -> String? {
        guard var t = raw?.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        // Quotes and a closing period, in whichever order they wrap it.
        var changed = true
        while changed {
            changed = false
            for (open, close) in [("\"", "\""), ("«", "»"), ("“", "”"), ("'", "'")] where t.count > 2 && t.hasPrefix(open) && t.hasSuffix(close) {
                t = String(t.dropFirst().dropLast())
                changed = true
            }
            while let last = t.last, ".。 ".contains(last) { t.removeLast(); changed = true }
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !isAutomatic(t) else { return nil }
        return shortened(t, limit: 80)
    }

    /// When the model gave no title (an older provider, the proxy before
    /// it learns the field): the summary's first sentence, cut at a word.
    public static func fallback(fromSummary summary: String) -> String? {
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var sentence = text
        if let end = text.firstIndex(where: { ".!?。".contains($0) }) { sentence = String(text[..<end]) }
        return cleaned(shortened(sentence, limit: 60))
    }

    /// The title to put on a session whose current one is `current`, or
    /// nil when it must stay as it is.
    public static func replacement(for current: String, modelTitle: String?, summary: String) -> String? {
        guard isAutomatic(current) else { return nil }
        return cleaned(modelTitle) ?? fallback(fromSummary: summary)
    }

    static func shortened(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return atWord.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—-")) + "…"
    }
}
