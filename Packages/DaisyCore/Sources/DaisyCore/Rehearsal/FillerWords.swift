//
//  FillerWords.swift
//  DaisyCore
//
//  Backlog 17 С-4: hesitations in a take. Deliberately narrow — only
//  words that are fillers whenever they are said. «Ну», «вот», «это»,
//  "like" are ordinary words most of the time and are left out: a count
//  that flags every «вот» is worse than none.
//
//  Whisper tends to drop hesitations as noise, so a count of zero means
//  little until the model is known to keep them — see `prompt`, and the
//  backlog's rule: measure before showing people a number.
//

import Foundation

public nonisolated enum FillerWords {
    static let single: Set<String> = [
        "э", "ээ", "эээ", "эм", "эмм", "мм", "ммм", "хм", "а-а", "аа",
        "типа", "короче",
        "um", "uh", "uhm", "erm", "hmm", "mm",
    ]
    static let pairs: Set<[String]> = [
        ["как", "бы"], ["в", "общем"], ["так", "сказать"], ["в", "принципе"],
        ["you", "know"], ["i", "mean"], ["sort", "of"], ["kind", "of"],
    ]

    public struct Hit: Sendable, Equatable {
        public let at: Double
        public let text: String
    }

    public static func find(in words: [WordTiming]) -> [Hit] {
        let keys = words.map { $0.w.lowercased().trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "-"))) }
        var hits: [Hit] = []
        var i = 0
        while i < keys.count {
            if i + 1 < keys.count, pairs.contains([keys[i], keys[i + 1]]) {
                hits.append(Hit(at: words[i].s, text: "\(keys[i]) \(keys[i + 1])"))
                i += 2
                continue
            }
            // «э-э» split by the model into «э» + «-э» is one hesitation.
            if keys[i].hasPrefix("-"), i > 0 { i += 1; continue }
            if single.contains(keys[i]) || keys[i].allSatisfy({ $0 == "э" || $0 == "-" }) && keys[i].contains("э") {
                hits.append(Hit(at: words[i].s, text: keys[i]))
            }
            i += 1
        }
        return hits
    }

    /// Conditioning text that shows the model hesitant speech is to be
    /// written down, not cleaned. Not the script — never the script.
    public static let prompt = "Ну, э-э, я, эм, хотел сказать… Ммм, как бы, в общем, это, короче, типа, вот."
}
