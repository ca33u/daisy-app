//
//  UnknownTokenRepair.swift
//  DaisyCore
//
//  Egor, 30.09: dictation wrote «Наш<unk>л», «прош<unk>л». Parakeet v3's
//  vocabulary has no «ё» at all (nor «Ё»); Nemotron's has «ё» but no «Ё».
//  The model emits its unknown token in the letter's place. Every other
//  Russian letter is in both vocabularies, so an `<unk>` touching Cyrillic
//  is «ё» — «Ё» where a capital belongs (a sentence's first letter, a word
//  in capitals). Anywhere else the token is noise and goes.
//

import Foundation

public nonisolated enum UnknownTokenRepair {
    public static let token = "<unk>"

    public static func repair(_ text: String) -> String {
        guard text.contains(token) else { return text }
        let chars = Array(text)
        let tokenChars = Array(token)
        var out: [Character] = []
        var i = 0
        while i < chars.count {
            if i + tokenChars.count <= chars.count, Array(chars[i..<(i + tokenChars.count)]) == tokenChars {
                let before = out.last
                let after = i + tokenChars.count < chars.count ? chars[i + tokenChars.count] : nil
                if isCyrillic(before) || isCyrillic(after) {
                    out.append(capital(before: out, after: after) ? "Ё" : "ё")
                }
                i += tokenChars.count
                continue
            }
            out.append(chars[i])
            i += 1
        }
        // A dropped token can leave two spaces or a space before punctuation.
        var result = String(out)
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        for mark in [",", ".", "!", "?", ":", ";"] {
            result = result.replacingOccurrences(of: " " + mark, with: mark)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func isCyrillic(_ c: Character?) -> Bool {
        guard let scalar = c?.unicodeScalars.first else { return false }
        return (0x0400...0x04FF).contains(scalar.value)
    }

    /// «Ё» at a sentence's start, or inside a word written in capitals.
    static func capital(before: [Character], after: Character?) -> Bool {
        let previous = before.last
        let atWordStart = previous == nil || previous!.isWhitespace || "«\"(—-".contains(previous!)
        if atWordStart {
            // The first word of the text or of a sentence.
            let beforeWord = before.reversed().drop { $0.isWhitespace || "«\"(".contains($0) }.first
            if beforeWord == nil || ".!?…".contains(beforeWord!) { return true }
            return after.map { $0.isUppercase } ?? false
        }
        // Inside a word: capital when its letters around are capitals
        // (ЁЛКА, ВСЁ) — a following space or mark says nothing.
        guard let previous, previous.isUppercase else { return false }
        if let after, after.isLetter, !after.isUppercase { return false }
        if before.count >= 2, before[before.count - 2].isLetter, before[before.count - 2].isLowercase { return false }
        return true
    }
}
