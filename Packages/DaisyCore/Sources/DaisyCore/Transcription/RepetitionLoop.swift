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

    // MARK: - Runs across segments

    /// A run this long of the same short line is silence, not speech.
    public nonisolated static let minRunLength = 4
    /// "Спасибо.", "Thank you.", "Угу" — the hallucinations silence
    /// produces are one to three words.
    public nonisolated static let maxRunWords = 3
    /// And they come every second or two, the way nobody talks.
    public nonisolated static let maxRunGap: TimeInterval = 5

    /// Indices of segments that form a silence run: at least
    /// `minRunLength` consecutive segments with the same short text,
    /// each starting within `maxRunGap` seconds of the previous.
    ///
    /// Инцидент 23.09, второй пользователь. After «До свидания» at 33:23
    /// the call was over and the microphone recorded ten minutes of an
    /// empty room. The per-pass filter dropped 162 hallucinated
    /// segments there — correctly — but six «Спасибо.» in eight seconds
    /// at 40:30 got through, because each pass only ever saw one or
    /// two of them. A loop that spans passes has to be judged where the
    /// passes are joined.
    ///
    /// Three in a row is kept on purpose: «Спасибо. Спасибо.» at the end
    /// of a call is real, and so is a triple "да".
    public nonisolated static func silenceRunIndices(texts: [String], starts: [TimeInterval]) -> Set<Int> {
        precondition(texts.count == starts.count)
        func key(_ text: String) -> String? {
            let words = text.lowercased()
                .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            guard !words.isEmpty, words.count <= maxRunWords else { return nil }
            return words.joined(separator: " ")
        }
        var dropped = Set<Int>()
        var runStart = 0
        func close(_ end: Int) {
            if end - runStart >= minRunLength { dropped.formUnion(runStart..<end) }
        }
        for i in texts.indices where i > 0 {
            let continues = key(texts[i]) != nil
                && key(texts[i]) == key(texts[i - 1])
                && starts[i] - starts[i - 1] <= maxRunGap
            if !continues {
                close(i)
                runStart = i
            }
        }
        close(texts.count)
        return dropped
    }
}
