//
//  DaisyKeyTranslation.swift
//  Daisy
//
//  The Daisy key's translation command (03.11.2026, a user's ask in the
//  backlog 32 logs: «зажимаешь клавишу, и твоя речь переводится»). The
//  language is said, never set in Settings (Egor): «переведи на
//  португальский: …» or «…, переведи на португальский», and what goes in
//  is the translation. Nothing is remembered between holds (Egor 03.11).
//  Said freely (Egor 03.11): «скажи по-португальски…», «как будет
//  по-португальски…», «по-английски переведи…», and a message in a
//  language — «напиши Пете по-португальски, что я опоздаю».
//
//  Who translates (Egor 03.11): the model chosen for summaries, under the
//  Daisy key's own rules (a local one at once, a cloud one after its one
//  yes) — it gets exactly the words a «напиши» command would. When no model
//  is set up, Apple's translation on this Mac (macOS 26+, the language
//  downloaded); with neither, the person is told to connect a provider.
//

import Foundation
import NaturalLanguage
import Translation

// MARK: - What language

/// The language a translation is into: a language, and the variant the
/// person named or this Mac's region implies.
nonisolated struct DaisyKeyTranslationTarget: Equatable, Sendable {
    /// ISO 639 code: «pt».
    let code: String
    /// «PT», «BR», «GB» — nil leaves the variant to whoever translates.
    var region: String? = nil
    /// «Hans» / «Hant» for Chinese.
    var script: String? = nil

    var identifier: String { [code, script, region].compactMap { $0 }.joined(separator: "-") }
    var language: Locale.Language { Locale.Language(identifier: identifier) }

    /// What a model is told: «Portuguese (Portugal)».
    var englishName: String {
        Locale(identifier: "en").localizedString(forIdentifier: identifier) ?? code
    }

    /// The language alone, in the app's language, for what Daisy says:
    /// «на португальский», "into Portuguese".
    var displayName: String {
        let ui = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return ui.localizedString(forLanguageCode: code) ?? code
    }
}

/// A translation asked for: into what, and what to translate. An empty
/// `text` means the command alone was said — the selection is then the
/// text, or there is nothing to translate.
nonisolated struct DaisyKeyTranslation: Equatable, Sendable {
    var target: DaisyKeyTranslationTarget
    var text: String
    /// «переведи мне…», "translate for me": the selection is read, not
    /// replaced.
    var forMe = false
    /// «напиши Пете по-португальски, что я опоздаю», "tell Pete in Spanish
    /// that…" (Egor 03.11: free form): a message to write in that language,
    /// not words to carry over one by one. A model writes it as the command
    /// it is — in the person's voice, in the language the request names;
    /// `text` (what comes after «что») is for Apple's translation when there
    /// is no model.
    var compose = false

    /// Where the result goes, as the other commands decide it: words said
    /// go in at the caret; with only the command said, an editable
    /// selection is translated in place unless it is «for me». A message
    /// goes where «напиши» puts one.
    func kind(hasSelection: Bool, selectionEditable: Bool) -> DaisyKeyCommandKind {
        if compose { return hasSelection ? .answer : .write }
        guard text.isEmpty, hasSelection else { return .write }
        return selectionEditable && !forMe ? .edit : .answer
    }

    /// What is translated as such: a message to write is the model's
    /// command when there is a model, and a translation only for Apple's.
    func translated(providerReady: Bool) -> DaisyKeyTranslation? {
        compose && providerReady ? nil : self
    }
}

// MARK: - Recognizing it (no model)

nonisolated enum DaisyKeyTranslateParser {
    /// How a request opens.
    enum Opener: Equatable {
        /// «переведи», "translate".
        case translate
        /// «скажи по-португальски…», "say it in Spanish…": a translation
        /// when the language follows the verb; with someone to say it to
        /// first («скажи Пете по-португальски, что…») a message.
        case say
        /// «как будет по-португальски…», "how do you say … in Spanish".
        case howToSay
        /// «напиши», «ответь», «передай», "tell": a message in that language.
        case write
        /// «перепиши по-английски» over a selection: it, translated.
        case rewrite
    }

    /// The verb itself. The infinitive only when asked for: «можешь
    /// перевести…» — «Задача: перевести на английский» is a to-do (review 03.11).
    static let verbs: Set<String> = ["переведи", "переведите", "translate"]
    static let sayVerbs: Set<String> = ["скажи", "скажите", "say"]
    static let infinitives: [String: Opener] = ["перевести": .translate, "сказать": .say]
    static let askWords: Set<String> = ["можешь", "можете", "can", "could", "would"]
    /// The question, longest first.
    static let howToSayOpenings: [[String]] = [
        ["how", "would", "you", "say"], ["how", "would", "i", "say"], ["how", "do", "you", "say"], ["how", "do", "i", "say"],
        ["how", "can", "i", "say"], ["как", "это", "будет"], ["how", "to", "say"],
        ["как", "будет"], ["как", "сказать"], ["как", "перевести"],
    ]
    /// «как по-португальски будет …»: «как», the language, then one of these.
    static let howToSayAfterLanguage: Set<String> = ["будет", "сказать", "звучит"]
    /// Verbs of a message to write. «передай», "tell": what to tell someone.
    static var writeVerbs: Set<String> {
        DaisyKeyCommandParser.writeVerbs.union(["напишите", "ответьте", "передай", "передайте", "tell"])
    }
    static let rewriteVerbs: Set<String> = ["перепиши", "перепишите", "rewrite"]
    /// What may stand between the verb and the language: «переведи это
    /// сообщение на…», "translate this message into…".
    static let objectWords: Set<String> = [
        "это", "этот", "эту", "сообщение", "текст", "фразу", "следующее", "письмо", "ответ",
        "this", "it", "that", "the", "message", "text", "following", "reply", "email",
    ]
    static let forMeWords: Set<String> = ["мне", "me"]
    /// «для меня», "for me".
    static let forWords: Set<String> = ["для", "for"]
    static let meWords: Set<String> = ["меня", "me"]
    /// «с русского», "from Russian": the source is found from the text.
    static let fromWords: Set<String> = ["с", "со", "from"]
    static let ruInto = "на"
    static let enInto: Set<String> = ["into", "to", "in"]
    /// Around the command: «переведи на английский, пожалуйста».
    static let courtesy: Set<String> = ["пожалуйста", "please"]
    /// What a message says opens after one of these: «напиши Пете
    /// по-португальски, что я опоздаю».
    static let saysWords: Set<String> = ["что", "that"]
    /// A message whose words open with one of these is described, not
    /// said: «напиши по-английски письмо Джону о встрече», «…, чтобы
    /// перезвонил» — the model's to write; Apple has nothing to translate.
    static let describedOpenings: Set<String> = [
        "письмо", "сообщение", "пост", "ответ", "текст", "статью", "комментарий", "отзыв", "о", "об", "про", "чтобы",
        "email", "letter", "message", "post", "reply", "text", "article", "comment", "review", "note", "tweet", "about", "to",
    ]
    /// Before a command at the end, these make it part of the sentence:
    /// «попроси его перевести на английский», "ask them to translate into…".
    static let notACommandBefore: Set<String> = ["to", "чтобы", "надо", "нужно", "попроси", "просил", "просила"]
    /// Text that opens with one of these asks for something else first —
    /// «Напиши Пете, что я согласен. Переведи на английский» is a letter to
    /// write in English, not «Напиши Пете…» word for word (review 03.11):
    /// the model gets it as the command it is. (A note opening never gets
    /// here: «запиши…» is a note before any command is looked for.)
    /// «Скажи, ты завтра будешь?», «Напишите, когда…» are the person's
    /// words, not a command: only the command verbs count (review 03.11).
    static var commandOpenings: Set<String> {
        DaisyKeyCommandParser.editVerbs.union(DaisyKeyCommandParser.writeVerbs).union(DaisyKeyCommandParser.makeVerbs)
            .union(DaisyKeyCommandParser.answerOpenings.filter { $0.count == 1 }.compactMap(\.first))
    }

    /// «переведи-ка» is «переведи».
    static func bare(_ word: String) -> String {
        word.hasSuffix("-ка") ? String(word.dropLast(3)) : word
    }

    /// The opener of one word, or nil.
    static func verb(_ word: String, asked: Bool) -> Opener? {
        let word = bare(word)
        if verbs.contains(word) { return .translate }
        if sayVerbs.contains(word) { return .say }
        if rewriteVerbs.contains(word) { return .rewrite }
        if writeVerbs.contains(word) { return .write }
        if asked, let opener = infinitives[word] { return opener }
        return nil
    }

    /// `macRegion`: this Mac's region, for the variant nobody named.
    static func parse(_ transcript: String, macRegion: String? = Locale.current.region?.identifier) -> DaisyKeyTranslation? {
        let said = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        // Without the name and the courtesy before the request, in any order
        // («Hey Daisy, translate…», «Слушай, Дейзи, переведи…») — when the
        // request opens with the verb.
        var tokens = said
        var asked = false
        while let first = tokens.first.map(DaisyKeyIntentParser.normalized), tokens.count > 1,
              DaisyKeyIntentParser.addressWords.contains(first) || DaisyKeyIntentParser.courtesyWords.contains(first) {
            if askWords.contains(first) { asked = true }
            tokens.removeFirst()
        }
        tokens = languageFirst(tokens, asked: asked, macRegion: macRegion)
        let words = tokens.map(DaisyKeyIntentParser.normalized)
        guard !words.isEmpty else { return nil }
        if let found = request(tokens, words, asked: asked, macRegion: macRegion) { return found }
        // The language last: «привет, как дела? Переведи на португальский».
        // Only a whole last clause, opened by the verb (or «можешь
        // перевести», "please translate", "can you translate") after a stop
        // or a comma, with nothing after it but «пожалуйста». The text is
        // as said: only the name before it goes («Давай встретимся…» keeps
        // its «Давай», review 03.11).
        return textFirst(said, macRegion: macRegion)
    }

    /// A request that opens with its verb (or the question).
    private static func request(_ tokens: [String], _ words: [String], asked: Bool, macRegion: String?) -> DaisyKeyTranslation? {
        let colons = colons(in: tokens)
        // «как по-португальски будет «спасибо»».
        if words[0] == "как", let language = language(words, at: 1, macRegion: macRegion, colons: colons),
           language.end < words.count, howToSayAfterLanguage.contains(words[language.end]) {
            return DaisyKeyTranslation(target: language.target,
                                       text: textBetween(leadTrimmed(tokens[(language.end + 1)...].joined(separator: " "))))
        }
        let opener: Opener
        let length: Int
        if let question = howToSayOpenings.first(where: { words.count > $0.count && Array(words.prefix($0.count)) == $0 }) {
            (opener, length) = (.howToSay, question.count)
        } else if let found = verb(words[0], asked: asked) {
            (opener, length) = (found, 1)
        } else {
            return nil
        }
        if opener == .write { return message(tokens, words, from: length, macRegion: macRegion) }
        // The language first: «переведи на португальский: привет».
        if let command = command(words, from: length - 1, macRegion: macRegion, colons: colons) {
            var forMe = command.forMe
            var rest = Array(tokens[command.end...])
            // «…, пожалуйста: привет», «…for me: hi», «…сообщение: привет».
            // A colon opens the text — after the language or after these
            // words: «…: мне нужно уйти» is what to translate, «мне»
            // included (review 03.11).
            var textOpened = tokens[command.end - 1].hasSuffix(":")
            while !textOpened, let first = rest.first.map(DaisyKeyIntentParser.normalized) {
                var taken = 0
                if courtesy.contains(first) || first.isEmpty {
                    taken = 1
                } else if forMeWords.contains(first) {
                    forMe = true; taken = 1
                } else if forWords.contains(first), rest.count > 1, meWords.contains(DaisyKeyIntentParser.normalized(rest[1])) {
                    forMe = true; taken = 2
                } else if objectWords.contains(first), rest[0].hasSuffix(":") {
                    taken = 1
                } else if opener == .howToSay, howToSayAfterLanguage.contains(first) {
                    taken = 1
                } else if opener == .say, saysWords.contains(first), !rest.joined().hasSuffix("?") {
                    // «скажи по-португальски, что я опоздаю»: what to say,
                    // not «что я опоздаю». «…, что ты делаешь?» is the question.
                    taken = 1
                }
                guard taken > 0 else { break }
                textOpened = rest[taken - 1].hasSuffix(":")
                rest.removeFirst(taken)
            }
            let text = textBetween(leadTrimmed(rest.joined(separator: " ")))
            // «перепиши по-английски»: only the selection, rewritten.
            if opener == .rewrite, !text.isEmpty { return nil }
            return DaisyKeyTranslation(target: command.target, text: text, forMe: forMe)
        }
        // The text between: «переведи «добрый день» на японский»,
        // "how do you say good morning in Japanese", «скажи «спасибо»
        // по-японски».
        func between() -> DaisyKeyTranslation? {
            guard let tail = tailCommand(words, from: length, macRegion: macRegion) else { return nil }
            let middle = (length..<tail.start).filter { !fillerWords.contains(words[$0]) }
            var text = textBetween(middle.isEmpty ? "" : leadTrimmed(tokens[middle.first!...middle.last!].joined(separator: " ")))
            var said = length..<tail.start
            // A quote is taken whole, «мне» inside it too: «как будет «напиши мне» по-английски».
            if let first = middle.first {
                let quoted = textBetween(leadTrimmed(tokens[first..<tail.start].joined(separator: " ")))
                if isQuoted(quoted) { text = quoted; said = length..<first }
            }
            let forMe = said.contains { forMeWords.contains(words[$0]) || meWords.contains(words[$0]) }
            // «Как будет готово, напиши Пете по-английски» is no question:
            // another verb inside, unless it is the quoted phrase (review 03.11).
            if opener == .howToSay, !isQuoted(text), middle.contains(where: { verb(words[$0], asked: false) != nil }) { return nil }
            return DaisyKeyTranslation(target: tail.target, text: text, forMe: forMe)
        }
        switch opener {
        case .translate, .howToSay:
            return between()
        case .say:
            // Quoted, what to say; else someone to say it to: «скажи Пете
            // по-португальски, что я опоздаю» — a message.
            if let quoted = between(), isQuoted(quoted.text) { return quoted }
            return message(tokens, words, from: length, macRegion: macRegion)
        case .write, .rewrite:
            return nil
        }
    }

    /// «спасибо» in quotes, as said.
    static func isQuoted(_ text: String) -> Bool {
        guard text.count > 1, let first = text.first, let last = text.last else { return false }
        return "«\"“„'".contains(first) && "»\"”“'".contains(last)
    }

    /// «по-португальски скажи…», «на английский переведи: …»: the verb
    /// is put first, the mark after it moved to the language.
    private static func languageFirst(_ tokens: [String], asked: Bool, macRegion: String?) -> [String] {
        let words = tokens.map(DaisyKeyIntentParser.normalized)
        guard let found = language(words, at: 0, macRegion: macRegion, colons: []), found.end < words.count,
              verb(words[found.end], asked: asked) != nil else { return tokens }
        var verbToken = tokens[found.end]
        var mark = ""
        while let last = verbToken.last, ",:;—".contains(last) { mark = String(last) + mark; verbToken.removeLast() }
        var name = Array(tokens[..<found.end])
        name[name.count - 1] += mark
        return [verbToken] + name + Array(tokens[(found.end + 1)...])
    }

    /// A message in a language: «напиши Пете по-португальски, что я
    /// опоздаю», «ответь на английском: согласен», «напиши Пете, что я
    /// опоздаю, по-португальски», "tell Anna in Spanish that I'm late".
    /// `text` is what the message says — after «что» or a colon, or right
    /// after a language that follows the verb. nil when the message is
    /// described rather than said, or names no language.
    private static func message(_ tokens: [String], _ words: [String], from start: Int, macRegion: String?) -> DaisyKeyTranslation? {
        guard start < words.count else { return nil }
        // Where what it says opens: after «что» / "that", or a colon.
        var opens: Int?
        var headEnd = words.count
        for i in start..<words.count {
            if saysWords.contains(words[i]) { opens = i + 1; headEnd = i; break }
            if tokens[i].hasSuffix(":") { opens = i + 1; headEnd = i + 1; break }
        }
        let colons = colons(in: tokens)
        func said(_ range: Range<Int>, colonOpened: Bool) -> String? {
            guard !range.isEmpty else { return nil }
            let text = textBetween(leadTrimmed(tokens[range].joined(separator: " ")))
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            if !colonOpened, let first = text.split(whereSeparator: \.isWhitespace).first.map({ DaisyKeyIntentParser.normalized(String($0)) }),
               describedOpenings.contains(first) { return nil }
            return text
        }
        // The language before what it says.
        var i = start
        while i < headEnd {
            guard let found = language(words, at: i, macRegion: macRegion, colons: colons), found.end <= headEnd else { i += 1; continue }
            let rightAfterVerb = (start..<i).allSatisfy { fillerWords.contains(words[$0]) }
            let marked = tokens[found.end - 1].last.map { ",:;—".contains($0) } ?? false
            // «на испанском побережье» is a place, not the language: the
            // name has to close the head.
            guard rightAfterVerb || marked || found.end == headEnd else { i += 1; continue }
            if let opens {
                guard let text = said(opens..<words.count, colonOpened: tokens[opens - 1].hasSuffix(":")) else { return nil }
                return DaisyKeyTranslation(target: found.target, text: text, compose: true)
            }
            // Without «что» or a colon, only after a mark: «ответь
            // по-английски вежливо» says how, not what (review 03.11).
            guard marked,
                  let text = said(found.end..<words.count, colonOpened: tokens[found.end - 1].hasSuffix(":")) else { return nil }
            return DaisyKeyTranslation(target: found.target, text: text, compose: true)
        }
        // The language after it: «…, что я опоздаю, по-португальски»,
        // «…, что я согласен. Переведи на английский» — the verb before it
        // is not what the message says.
        guard let opens, let tail = tailCommand(words, from: opens, macRegion: macRegion) else { return nil }
        var end = tail.start
        while end > opens, fillerWords.contains(words[end - 1]) { end -= 1 }
        if end > opens, verb(words[end - 1], asked: true) != nil {
            end -= 1
            while end > opens, askWords.contains(words[end - 1]) || courtesy.contains(words[end - 1]) || words[end - 1] == "you" { end -= 1 }
        } else {
            // Set off by a mark: «…, что встреча будет на английском» says
            // what the meeting is in (review 03.11).
            guard let mark = tokens[tail.start - 1].last, ",.;—".contains(mark) || tokens[tail.start - 1] == "—" else { return nil }
            end = tail.start
        }
        guard let text = said(opens..<end, colonOpened: tokens[opens - 1].hasSuffix(":")) else { return nil }
        return DaisyKeyTranslation(target: tail.target, text: text, compose: true)
    }

    private static func textFirst(_ said: [String], macRegion: String?) -> DaisyKeyTranslation? {
        var tokens = said
        // «Daisy, …», «Слушай, Дейзи, …»: a courtesy word only with the name after it.
        while let first = tokens.first.map(DaisyKeyIntentParser.normalized), tokens.count > 1 {
            if DaisyKeyIntentParser.addressWords.contains(first) { tokens.removeFirst(); continue }
            if DaisyKeyIntentParser.courtesyWords.contains(first),
               DaisyKeyIntentParser.addressWords.contains(DaisyKeyIntentParser.normalized(tokens[1])) {
                tokens.removeFirst(2); continue
            }
            break
        }
        let words = tokens.map(DaisyKeyIntentParser.normalized)
        for start in stride(from: words.count - 1, to: 0, by: -1) {
            // «Переведи», «Скажи это по-португальски», «Напиши это
            // по-португальски» — that one a message, the model's to write.
            let infinitive = infinitives[bare(words[start])] != nil
            guard let opener = verb(words[start], asked: true), opener != .rewrite,
                  let command = command(words, from: start, macRegion: macRegion, colons: []),
                  words[command.end...].allSatisfy({ courtesy.contains($0) || $0.isEmpty }) else { continue }
            var clause = start
            if infinitive {
                guard askWords.contains(words[start - 1]) else { return nil }
                clause -= 1
            } else if courtesy.contains(words[start - 1]) {
                clause -= 1
            } else if start >= 2, words[start - 1] == "you", askWords.contains(words[start - 2]) {
                clause -= 2
            }
            guard clause > 0 else { return nil }
            // A colon before it makes it the text's own: «Задача на завтра: …».
            guard let mark = tokens[clause - 1].last, mark != ":",
                  ".,;!?…—-".contains(mark) || tokens[clause].first?.isUppercase == true,
                  !notACommandBefore.contains(words[clause - 1]) else { return nil }
            let text = textBetween(tokens[..<clause].joined(separator: " "))
            guard text.contains(where: { $0.isLetter || $0.isNumber }),
                  let first = DaisyKeyIntentParser.requestWords(text).first.map(DaisyKeyIntentParser.normalized),
                  !commandOpenings.contains(bare(first)) else { return nil }
            return DaisyKeyTranslation(target: command.target, text: text, forMe: command.forMe, compose: opener == .write)
        }
        return nil
    }

    /// Without the comma or dash that led into the command after it.
    static func textBetween(_ text: String) -> String {
        var text = text
        while let last = text.last, ",;:—-".contains(last) || last.isWhitespace { text.removeLast() }
        return text
    }

    /// Without the comma, colon or dash that led into the text — its own
    /// quotes stay («переведи на японский: «добрый день»»): they come off
    /// in pairs, where the text is cleaned.
    static func leadTrimmed(_ text: String) -> String {
        var t = Substring(text)
        while let c = t.first, ",;:—-".contains(c) || c.isWhitespace { t = t.dropFirst() }
        return String(t)
    }

    /// Words around the text that aren't it: «переведи мне, пожалуйста, на…».
    static let fillerWords: Set<String> = objectWords.union(forMeWords).union(courtesy).union(["", "для", "меня", "for"])

    /// A language at `start`: «на португальский», "into Japanese",
    /// «по-португальски».
    private static func language(_ words: [String], at start: Int, macRegion: String?, colons: Set<Int>)
        -> (target: DaisyKeyTranslationTarget, end: Int)? {
        guard start < words.count else { return nil }
        if words[start] == ruInto || enInto.contains(words[start]) {
            return DaisyKeyLanguageNames.match(words, at: start + 1, macRegion: macRegion, colons: colons)
        }
        return DaisyKeyLanguageNames.matchAdverb(words, at: start, macRegion: macRegion)
    }

    /// «на японский» / "into Japanese" / «по-японски» closing the request,
    /// after the words from `first` on: where it starts, and the language.
    private static func tailCommand(_ words: [String], from first: Int, macRegion: String?)
        -> (start: Int, target: DaisyKeyTranslationTarget)? {
        var end = words.count
        while end > first, courtesy.contains(words[end - 1]) || words[end - 1].isEmpty { end -= 1 }
        for start in stride(from: end - 1, to: first, by: -1) {
            if let found = language(words, at: start, macRegion: macRegion, colons: []), found.end == end {
                return (start, found.target)
            }
        }
        return nil
    }

    /// Where a word ends with a colon: the text opens after it.
    private static func colons(in tokens: [String]) -> Set<Int> {
        Set(tokens.indices.filter { tokens[$0].hasSuffix(":") })
    }

    /// The command's words from the verb at `start`: the target and where
    /// the command ends. nil when no language is named.
    private static func command(_ words: [String], from start: Int, macRegion: String?, colons: Set<Int>)
        -> (target: DaisyKeyTranslationTarget, end: Int, forMe: Bool)? {
        var i = start + 1
        var forMe = false
        while i < words.count {
            let w = words[i]
            if forMeWords.contains(w) { forMe = true; i += 1; continue }
            if forWords.contains(w), i + 1 < words.count, meWords.contains(words[i + 1]) { forMe = true; i += 2; continue }
            if objectWords.contains(w) { i += 1; continue }
            // «с русского» before «на …»: the source, a variant word too
            // ("from Brazilian Portuguese").
            if fromWords.contains(w), i + 2 < words.count {
                i += DaisyKeyLanguageNames.variants[words[i + 1]] != nil && i + 3 < words.count ? 3 : 2
                continue
            }
            break
        }
        guard let found = language(words, at: i, macRegion: macRegion, colons: colons) else { return nil }
        return (found.target, found.end, forMe)
    }
}

// MARK: - Language names, as said

nonisolated enum DaisyKeyLanguageNames {
    /// The languages a person may name: Apple's translation languages and
    /// the others people write in often enough for a model to be asked.
    static let codes = [
        "en", "ru", "uk", "be", "pt", "es", "fr", "de", "it", "nl", "pl", "cs", "sk", "sl", "hr", "sr", "bs", "bg",
        "mk", "ro", "hu", "el", "tr", "ar", "he", "fa", "hi", "ur", "bn", "ta", "te", "th", "vi", "id", "ms", "tl",
        "zh", "ja", "ko", "ka", "hy", "az", "kk", "uz", "ky", "tg", "mn", "sv", "nb", "da", "fi", "is", "et", "lv",
        "lt", "ga", "sq", "sw", "af", "am", "ca", "eu", "gl", "la", "eo", "yi",
    ]
    /// Names the locale tables don't give.
    static let aliases: [String: String] = [
        "норвежский": "nb", "фарси": "fa", "norwegian": "nb", "farsi": "fa", "mandarin": "zh", "filipino": "tl",
    ]

    /// The word «язык» after a name, as people say it.
    static let languageWords: Set<String> = ["язык", "языке", "language"]

    /// A variant said before the language: «бразильский португальский».
    struct Variant { let code: String; var region: String? = nil; var script: String? = nil }
    static let variants: [String: Variant] = {
        var table: [String: Variant] = [:]
        func add(_ words: [String], _ variant: Variant) { for w in words { table[w] = variant } }
        add(["бразильский", "бразильском", "brazilian"], Variant(code: "pt", region: "BR"))
        add(["европейский", "европейском", "european"], Variant(code: "pt", region: "PT"))
        add(["американский", "американском", "american"], Variant(code: "en", region: "US"))
        add(["британский", "британском", "british"], Variant(code: "en", region: "GB"))
        add(["мексиканский", "мексиканском", "mexican"], Variant(code: "es", region: "MX"))
        add(["канадский", "канадском", "canadian"], Variant(code: "fr", region: "CA"))
        add(["упрощённый", "упрощенный", "упрощённом", "упрощенном", "simplified"], Variant(code: "zh", script: "Hans"))
        add(["традиционный", "традиционном", "traditional"], Variant(code: "zh", script: "Hant"))
        return table
    }()

    /// Every spoken form (lowercased words) → language code. Russian names
    /// in the forms that follow «на» («португальский», «португальском»);
    /// English names as they are.
    static let forms: [[String]: String] = {
        var table: [[String]: String] = [:]
        let ru = Locale(identifier: "ru"), en = Locale(identifier: "en")
        for code in codes {
            if let name = ru.localizedString(forLanguageCode: code)?.lowercased() {
                for form in russianForms(name) { table[form.split(separator: " ").map(String.init)] = code }
            }
            if let name = en.localizedString(forLanguageCode: code)?.lowercased() {
                table[name.split(separator: " ").map(String.init)] = code
            }
        }
        for (alias, code) in aliases {
            for form in russianForms(alias) { table[[form]] = code }
        }
        return table
    }()

    /// «по-португальски» → pt.
    static let adverbs: [String: String] = {
        var table: [String: String] = [:]
        for code in codes {
            guard let name = Locale(identifier: "ru").localizedString(forLanguageCode: code)?.lowercased(),
                  !name.contains(" "), name.hasSuffix("ий") else { continue }
            table[String(name.dropLast())] = code
        }
        return table
    }()

    /// The accusative and prepositional of a Russian language name:
    /// adjectives («английский» → «английском»), nouns («иврит» →
    /// «иврите», «латынь» → «латыни»); names ending in a vowel («хинди»)
    /// don't change. Only the last word of a longer name changes.
    static func russianForms(_ name: String) -> [String] {
        var forms = [name]
        if name.hasSuffix("ий") || name.hasSuffix("ый") || name.hasSuffix("ой") {
            forms.append(String(name.dropLast(2)) + "ом")
        } else if name.hasSuffix("ь") {
            forms.append(String(name.dropLast()) + "и")
        } else if let last = name.last, !"аеёиоуыэюя".contains(last) {
            forms.append(name + "е")
        }
        return forms
    }

    /// A language name at `start`, the longest that fits, with a variant
    /// word before it; `end` is the index after it.
    /// `colons`: words said with a colon after them — the text opens there,
    /// so "English: language is hard" keeps its "language".
    static func match(_ words: [String], at start: Int, macRegion: String?, colons: Set<Int> = [])
        -> (target: DaisyKeyTranslationTarget, end: Int)? {
        guard start < words.count else { return nil }
        var i = start
        var variant: Variant?
        if let v = variants[words[i]] { variant = v; i += 1 }
        for length in stride(from: min(3, words.count - i), through: 1, by: -1) {
            guard let code = forms[Array(words[i..<(i + length)])] else { continue }
            // «бразильский английский» names no variant of English.
            let named = variant.flatMap { $0.code == code ? $0 : nil }
            // «на английский язык», «на английском языке», "into the English language".
            let name = i + length
            let end = name < words.count && languageWords.contains(words[name]) && !colons.contains(name - 1) ? name + 1 : name
            return (target(code, named: named, macRegion: macRegion), end)
        }
        // «на бразильский» alone: the variant names its language.
        if let variant, variant.region == "BR" {
            return (target(variant.code, named: variant, macRegion: macRegion), i)
        }
        return nil
    }

    /// «по-португальски» / «по португальски» at `start`.
    static func matchAdverb(_ words: [String], at start: Int, macRegion: String?) -> (target: DaisyKeyTranslationTarget, end: Int)? {
        let word = words[start]
        if word.hasPrefix("по-"), let code = adverbs[String(word.dropFirst(3))] {
            return (target(code, named: nil, macRegion: macRegion), start + 1)
        }
        if word == "по", start + 1 < words.count, let code = adverbs[words[start + 1]] {
            return (target(code, named: nil, macRegion: macRegion), start + 2)
        }
        return nil
    }

    /// The variant: the one named; else this Mac's region where it is one
    /// of the language's; else European Portuguese (Egor 03.11: «иначе на
    /// каком в Португалии говорят») and Simplified Chinese; else none.
    static func target(_ code: String, named: Variant?, macRegion: String?) -> DaisyKeyTranslationTarget {
        if let named { return DaisyKeyTranslationTarget(code: code, region: named.region, script: named.script) }
        let region = macRegion?.uppercased()
        switch code {
        case "pt":
            return DaisyKeyTranslationTarget(code: code, region: region == "BR" ? "BR" : "PT")
        case "zh":
            return DaisyKeyTranslationTarget(code: code, script: ["TW", "HK", "MO"].contains(region ?? "") ? "Hant" : "Hans")
        case "en" where ["US", "GB", "AU", "CA", "IE", "NZ", "IN", "SG", "ZA"].contains(region ?? ""):
            return DaisyKeyTranslationTarget(code: code, region: region)
        case "es" where ["ES", "MX", "US", "CL", "AR", "CO"].contains(region ?? ""):
            return DaisyKeyTranslationTarget(code: code, region: region)
        case "fr" where ["FR", "CA", "BE", "CH"].contains(region ?? ""):
            return DaisyKeyTranslationTarget(code: code, region: region)
        default:
            return DaisyKeyTranslationTarget(code: code)
        }
    }
}

// MARK: - Who translates

nonisolated enum DaisyKeyTranslationEngine: Equatable, Sendable {
    /// The model chosen for summaries, under the Daisy key's rules.
    case provider
    /// Apple's translation, on this Mac.
    case onDevice
    /// Neither: the person is told to connect a provider. `downloadable`:
    /// Apple could do it once the language is downloaded.
    case none(downloadable: Bool)

    /// Egor 03.11: the summary model when there is one; else Apple's.
    static func choose(providerReady: Bool, onDevice: OnDeviceTranslationAvailability) -> DaisyKeyTranslationEngine {
        if providerReady { return .provider }
        switch onDevice {
        case .installed, .sameLanguage: return .onDevice
        case .downloadable: return .none(downloadable: true)
        case .unsupported, .unavailable: return .none(downloadable: false)
        }
    }
}

nonisolated enum OnDeviceTranslationAvailability: Equatable, Sendable {
    /// Both languages are on this Mac.
    case installed
    /// The text is in the target language already.
    case sameLanguage
    /// The pair is supported; a language has to be downloaded first.
    case downloadable
    /// Apple doesn't translate this pair, or the text's language wasn't
    /// recognized.
    case unsupported
    /// Not on this macOS (UI-less sessions came with macOS 26).
    case unavailable
}

/// Translation on this Mac — Apple's, or a stand-in in tests.
nonisolated protocol OnDeviceTranslating: Sendable {
    func availability(of text: String, to target: Locale.Language) async -> OnDeviceTranslationAvailability
    /// The translation, or nil when it couldn't be had.
    func translate(_ text: String, to target: Locale.Language) async -> String?
}

/// Apple's Translation framework. `TranslationSession(installedSource:
/// target:)` (macOS 26) needs no SwiftUI view and works only with
/// languages already downloaded — nothing is fetched behind the person's
/// back; downloading is theirs to do in System Settings. Nothing leaves
/// the Mac.
nonisolated struct AppleOnDeviceTranslator: OnDeviceTranslating {
    /// The text's language, as Apple's translation would name it.
    static func sourceLanguage(of text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    @concurrent
    func availability(of text: String, to target: Locale.Language) async -> OnDeviceTranslationAvailability {
        guard #available(macOS 26.0, *) else { return .unavailable }
        guard let source = Self.sourceLanguage(of: text) else { return .unsupported }
        if source.languageCode == target.languageCode, source.script == target.script || target.script == nil {
            return .sameLanguage
        }
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: return .installed
        case .supported: return .downloadable
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    @concurrent
    func translate(_ text: String, to target: Locale.Language) async -> String? {
        guard #available(macOS 26.0, *), let source = Self.sourceLanguage(of: text) else { return nil }
        let session = SessionBox(TranslationSession(installedSource: source, target: target))
        // Esc and the 30-second limit cancel the task: the session stops too.
        return await withTaskCancellationHandler {
            guard let response = try? await session.session.translate(text) else { return nil }
            let result = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? nil : result
        } onCancel: {
            session.session.cancel()
        }
    }

    /// The session, for the cancel handler: `cancel()` is the one call made
    /// from there, and the session is made for this translation alone.
    @available(macOS 26.0, *)
    private final class SessionBox: @unchecked Sendable {
        let session: TranslationSession
        init(_ session: TranslationSession) { self.session = session }
    }
}

extension DaisyKeyTranslation {
    /// Translated on this Mac: the text as it may be inserted, the text
    /// itself when it is in that language already, nil when it couldn't be.
    static func onDevice(_ text: String, to target: DaisyKeyTranslationTarget, field: VoiceCommandContext.Field,
                         translator: any OnDeviceTranslating) async -> String? {
        switch await translator.availability(of: text, to: target.language) {
        case .sameLanguage:
            return DaisyKeyCommandParser.cleaned(text, field: field)
        case .installed:
            guard let translated = await translator.translate(text, to: target.language) else { return nil }
            return DaisyKeyCommandParser.cleaned(translated, field: field)
        case .downloadable, .unsupported, .unavailable:
            return nil
        }
    }
}
