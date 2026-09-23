//
//  TakeAnalysis.swift
//  DaisyCore
//
//  Backlog 17 С-4: what the take did with the text. Local and
//  deterministic — no model: the alignment of the script with the words
//  that were said, the pace of each paragraph, the pauses, and the length
//  against the target. Fillers are not counted here: Whisper drops them
//  as noise, and a count of zero where there were forty is worse than no
//  count (the backlog: measure first).
//

import Foundation

public nonisolated struct TakeAnalysis: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// Said as written.
        case match(script: Int, spoken: Int)
        /// Said something else in its place.
        case substitute(script: Int, spoken: Int)
        /// Left out.
        case omit(script: Int)
        /// Said, not written.
        case insert(spoken: Int)
    }

    public struct ParagraphPace: Sendable, Equatable {
        public let paragraph: Int
        public let wordsPerMinute: Double
        public let start: Double
        public let end: Double
    }

    public struct Pause: Sendable, Equatable {
        /// Seconds into the take where the silence began.
        public let at: Double
        public let seconds: Double
    }

    public let steps: [Step]
    public let paces: [ParagraphPace]
    public let pauses: [Pause]
    public let duration: Double
    public let target: Double?

    public var omitted: Int { steps.filter { if case .omit = $0 { true } else { false } }.count }
    public var substituted: Int { steps.filter { if case .substitute = $0 { true } else { false } }.count }
    public var inserted: Int { steps.filter { if case .insert = $0 { true } else { false } }.count }
    /// Share of the script said as written, 0…1.
    public var accuracy: Double {
        let total = steps.filter { if case .insert = $0 { false } else { true } }.count
        guard total > 0 else { return 0 }
        let matched = steps.filter { if case .match = $0 { true } else { false } }.count
        return Double(matched) / Double(total)
    }

    /// A gap between words this long is a pause worth showing.
    public static let pauseThreshold = 1.2

    public init(script: RehearsalScript, spoken: [WordTiming], target: Double? = nil,
                pauseThreshold: Double = TakeAnalysis.pauseThreshold) {
        let keys = spoken.map { WordKey.normalize($0.w) }
        steps = Self.align(script.words.map(\.key), keys)
        duration = spoken.last.map { $0.e } ?? 0
        self.target = target

        var pauses: [Pause] = []
        for (a, b) in zip(spoken, spoken.dropFirst()) where b.s - a.e >= pauseThreshold {
            pauses.append(Pause(at: a.e, seconds: b.s - a.e))
        }
        self.pauses = pauses

        // Each spoken word belongs to the paragraph of the script word it
        // stands for; an inserted word, to the paragraph being read.
        var paragraphOf = [Int](repeating: -1, count: spoken.count)
        var current = 0
        for step in steps {
            switch step {
            case .match(let s, let sp), .substitute(let s, let sp):
                current = script.words[s].paragraph
                paragraphOf[sp] = current
            case .insert(let sp):
                paragraphOf[sp] = current
            case .omit(let s):
                current = script.words[s].paragraph
            }
        }
        var paces: [ParagraphPace] = []
        for paragraph in script.paragraphs.indices {
            let indices = paragraphOf.indices.filter { paragraphOf[$0] == paragraph }
            guard let first = indices.first, let last = indices.last else { continue }
            let start = spoken[first].s, end = spoken[last].e
            guard end > start else { continue }
            paces.append(ParagraphPace(paragraph: paragraph,
                                       wordsPerMinute: Double(indices.count) / (end - start) * 60,
                                       start: start, end: end))
        }
        self.paces = paces
    }

    /// The text of the take as plain text, for sharing: left-out words
    /// as `[−word]`, changed ones as `[written → said]`, added ones as
    /// `[+said]`; paragraphs kept.
    public func markedText(script: RehearsalScript, spoken: [WordTiming]) -> String {
        var paragraphs: [[String]] = Array(repeating: [], count: max(1, script.paragraphs.count))
        var current = 0
        for step in steps {
            switch step {
            case .match(let s, _):
                current = script.words[s].paragraph
                paragraphs[current].append(script.words[s].text)
            case .substitute(let s, let sp):
                current = script.words[s].paragraph
                paragraphs[current].append("[\(script.words[s].text) → \(spoken[sp].w)]")
            case .omit(let s):
                current = script.words[s].paragraph
                paragraphs[current].append("[−\(script.words[s].text)]")
            case .insert(let sp):
                paragraphs[current].append("[+\(spoken[sp].w)]")
            }
        }
        return paragraphs.map { $0.joined(separator: " ") }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Where the take's speech starts and ends, with a little air — for
    /// exporting the audio without the silence before the first word and
    /// after the last.
    public static func speechRange(of spoken: [WordTiming], lead: Double = 0.3, tail: Double = 0.4) -> ClosedRange<Double>? {
        guard let first = spoken.first, let last = spoken.last, last.e > first.s else { return nil }
        return max(0, first.s - lead)...(last.e + tail)
    }

    /// Word-level edit alignment, similar words counting as equal.
    static func align(_ script: [String], _ spoken: [String]) -> [Step] {
        let n = script.count, m = spoken.count
        var cost = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let same = WordKey.similar(script[i - 1], spoken[j - 1])
                    cost[i][j] = min(cost[i - 1][j] + 1, cost[i][j - 1] + 1,
                                     cost[i - 1][j - 1] + (same ? 0 : 1))
                }
            }
        }
        var steps: [Step] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let same = WordKey.similar(script[i - 1], spoken[j - 1])
                if cost[i][j] == cost[i - 1][j - 1] + (same ? 0 : 1) {
                    steps.append(same ? .match(script: i - 1, spoken: j - 1) : .substitute(script: i - 1, spoken: j - 1))
                    i -= 1; j -= 1
                    continue
                }
            }
            if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                steps.append(.omit(script: i - 1)); i -= 1
            } else {
                steps.append(.insert(spoken: j - 1)); j -= 1
            }
        }
        return steps.reversed()
    }
}
