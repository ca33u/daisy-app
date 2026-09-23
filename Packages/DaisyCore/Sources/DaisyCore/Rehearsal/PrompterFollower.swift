//
//  PrompterFollower.swift
//  DaisyCore
//
//  Backlog 17 С-2: the prompter scrolls with what is being said, not with
//  a clock. Fed the words the live transcript has heard so far, it keeps
//  the index of the next word to be read.
//
//  Silent: stays. Stumbling (words the text does not have): waits. A
//  paragraph skipped: jumps ahead. Back: only on a confident match —
//  scripts repeat words and phrases all the time, and a prompter that
//  leaps back to the last «и мы» on the page is worse than none.
//

import Foundation

public nonisolated struct PrompterFollower: Sendable {
    public let script: RehearsalScript
    /// Index in `script.words` of the next word to be read.
    public private(set) var position = 0

    /// How far ahead a match is looked for — a paragraph or two.
    public var lookAhead = 80
    /// How far back, and how much agreement going back needs.
    public var lookBehind = 12
    public var backwardConfidence = 4
    /// The tail of what was heard that is matched against the page.
    public var tailLength = 6

    public init(script: RehearsalScript) {
        self.script = script
    }

    public var isFinished: Bool { position >= script.words.count }

    /// `heard`: every word recognised so far, in order (committed lines
    /// and the current draft). Returns the new position.
    @discardableResult
    public mutating func hear(_ heard: [String]) -> Int {
        let tail = heard.suffix(tailLength).map(WordKey.normalize).filter { !$0.isEmpty }
        guard let last = tail.last, !script.words.isEmpty else { return position }

        let lo = max(0, position - lookBehind)
        let hi = min(script.words.count - 1, position + lookAhead)
        guard lo <= hi else { return position }
        var best: (end: Int, score: Int)?
        for end in lo...hi where WordKey.similar(script.words[end].key, last) {
            let score = agreement(tail: tail, endingAt: end)
            let better: Bool = {
                guard let b = best else { return true }
                if score != b.score { return score > b.score }
                // Equal evidence: the nearest place ahead of where we are.
                return abs(end - position) < abs(b.end - position)
            }()
            if better { best = (end, score) }
        }
        guard let best else { return position }
        let target = best.end + 1
        if target >= position {
            // Forward: two words agreeing is enough; one is enough only
            // for the very next word, which is what reading looks like.
            if best.score >= 2 || target == position + 1 { position = target }
        } else if best.score >= backwardConfidence {
            position = target
        }
        return position
    }

    /// Manual correction: a tap on a line of the prompter.
    public mutating func jump(to index: Int) {
        position = max(0, min(index, script.words.count))
    }

    /// Longest run of the tail, read backwards from its last word, that
    /// the script agrees with ending at `end` — allowing a word the model
    /// dropped or added in between.
    private func agreement(tail: [String], endingAt end: Int) -> Int {
        let window = Array(script.words[max(0, end - tail.count - 2)...end].map(\.key))
        // LCS of tail and window, both anchored at their last element.
        let n = tail.count, m = window.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                dp[i][j] = WordKey.similar(tail[i - 1], window[j - 1])
                    ? dp[i - 1][j - 1] + 1
                    : max(dp[i - 1][j], dp[i][j - 1])
            }
        }
        return dp[n][m]
    }
}
