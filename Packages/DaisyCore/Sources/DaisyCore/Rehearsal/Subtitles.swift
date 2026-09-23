//
//  Subtitles.swift
//  DaisyCore
//
//  Backlog 17 С-6: SRT and VTT from word timings. Reels burn subtitles in
//  almost always, and every word already has its time — so this is
//  cheap. Cues are short, for a vertical frame: a few words, a couple of
//  seconds, a break at the end of a sentence or at a pause.
//

import Foundation

public nonisolated enum Subtitles {
    public struct Cue: Sendable, Equatable {
        public let start: Double
        public let end: Double
        public let text: String
    }

    public static let maxCharacters = 32
    public static let maxSeconds = 2.5
    public static let breakAtPause = 0.6

    public static func cues(from words: [WordTiming]) -> [Cue] {
        var cues: [Cue] = []
        var line: [WordTiming] = []
        func flush() {
            guard let first = line.first, let last = line.last else { return }
            cues.append(Cue(start: first.s, end: last.e, text: line.map(\.w).joined(separator: " ")))
            line.removeAll()
        }
        for word in words {
            if let first = line.first, let last = line.last {
                let text = (line.map(\.w) + [word.w]).joined(separator: " ")
                if text.count > maxCharacters || word.e - first.s > maxSeconds || word.s - last.e >= breakAtPause {
                    flush()
                }
            }
            line.append(word)
            if let end = word.w.last, ".!?…".contains(end) { flush() }
        }
        flush()
        return cues
    }

    public static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(stamp(cue.start, separator: ",")) --> \(stamp(cue.end, separator: ","))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(stamp(cue.start, separator: ".")) --> \(stamp(cue.end, separator: "."))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    static func stamp(_ seconds: Double, separator: String) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }
}
