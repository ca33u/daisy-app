//
//  RehearsalScript.swift
//  DaisyCore
//
//  Backlog 17: the text a person rehearses, as words the prompter and the
//  analysis can count. The script is never given to Whisper (§3.7).
//

import Foundation

public nonisolated struct RehearsalScript: Sendable, Equatable {
    public struct Word: Sendable, Equatable {
        /// As written, punctuation included — what the prompter shows.
        public let text: String
        /// What is compared: lowercased, letters and digits only, ё → е.
        public let key: String
        public let paragraph: Int
    }

    public let text: String
    public let paragraphs: [String]
    public let words: [Word]

    /// A speaking pace for when the person has none on record yet —
    /// conversational speech, a little slower than the English norm to
    /// be fair to Russian's longer words.
    public static let defaultWordsPerMinute = 140.0

    public init(text: String) {
        self.text = text
        let paragraphs = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.paragraphs = paragraphs
        var words: [Word] = []
        for (index, paragraph) in paragraphs.enumerated() {
            for raw in paragraph.split(whereSeparator: \.isWhitespace) {
                let key = WordKey.normalize(String(raw))
                guard !key.isEmpty else { continue }
                words.append(Word(text: String(raw), key: key, paragraph: index))
            }
        }
        self.words = words
    }

    /// How long the text takes at a pace — «at your usual pace this runs
    /// 1:12; the target is 0:60», the first number a reel needs.
    public func estimatedSeconds(wordsPerMinute: Double = defaultWordsPerMinute) -> Double {
        guard wordsPerMinute > 0 else { return 0 }
        return Double(words.count) / wordsPerMinute * 60
    }
}

public nonisolated enum WordKey {
    public static func normalize(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            .replacingOccurrences(of: "ё", with: "е")
    }

    /// Close enough to be the same spoken word: equal, or one edit apart
    /// once both are five letters or longer (Whisper's «договора» for a
    /// written «договору», a dropped letter), or the same first five
    /// letters of long words (case endings).
    public static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        // A brand written in Latin and heard in Cyrillic is the same word
        // («Daisy» in the script, «Дэйзи» from Whisper).
        if let fa = BrandCorrections.canonicalFolds[a], fa == BrandCorrections.canonicalFolds[b] { return true }
        guard a.count >= 5, b.count >= 5 else { return false }
        if a.prefix(5) == b.prefix(5), a.count >= 6, b.count >= 6 { return true }
        return editDistance(a, b, limit: 1) <= 1
    }

    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= limit else { return limit + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// One spoken word with its time — the contents of `words.json` (§2).
public nonisolated struct WordTiming: Codable, Sendable, Equatable {
    public let w: String
    public let s: Double
    public let e: Double

    public init(w: String, s: Double, e: Double) {
        self.w = w
        self.s = s
        self.e = e
    }

    public static let fileName = "words.json"

    public static func read(in directory: URL) -> [WordTiming]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode([WordTiming].self, from: data)
    }

    public static func write(_ words: [WordTiming], in directory: URL) throws {
        let data = try JSONEncoder().encode(words)
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }
}
