//
//  RepetitionLoop.swift
//  DaisyCore
//
//  Инцидент 23.09: a dying system-audio stream handed Whisper silence,
//  and the model looped — «я знаю, что я знаю, что я знаю…» — for
//  nearly half a minute. With archiving off there is no finishing pass,
//  so the live text IS the transcript: the loop stayed in the user's
//  meeting notes for good.
//
//  The existing defence is an exact-match blocklist of known phrases
//  ("Thanks for watching", «Продолжение следует…»). A loop is not a
//  known phrase — it is a shape, and it has to be recognised as one.
//
//  Deliberately conservative. Real speech repeats: "да, да, да", "все,
//  все", a name said twice. Throwing those away would be a second way
//  to lose what someone said, so the bar is a phrase repeated MANY
//  times and covering most of the line.
//

import Foundation

public enum RepetitionLoop {
    /// How many times a phrase must repeat before it stops being
    /// emphasis and starts being a loop.
    public nonisolated static let minRepeats = 5
    /// And how much of the line it must account for.
    public nonisolated static let minCoverage = 0.7
    /// Short lines are left alone entirely: "да, да, да" is six words
    /// of agreement, not a malfunction.
    public nonisolated static let minWords = 10

    /// True when this line is one phrase repeating itself.
    public nonisolated static func isLoop(_ text: String) -> Bool {
        let words = text
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
        guard words.count >= minWords else { return false }

        // Try short phrases first: a loop's unit is usually two to four
        // words ("что я знаю"), and the shortest unit that explains the
        // line is the honest description of it.
        for size in 1...min(5, words.count / minRepeats) {
            var counts: [String: Int] = [:]
            for start in stride(from: 0, to: words.count - size + 1, by: size) {
                let phrase = words[start..<(start + size)].joined(separator: " ")
                counts[phrase, default: 0] += 1
            }
            guard let (_, best) = counts.max(by: { $0.value < $1.value }) else { continue }
            guard best >= minRepeats else { continue }
            let covered = Double(best * size) / Double(words.count)
            if covered >= minCoverage { return true }
        }
        return false
    }
}
