//
//  DaisyKeyTranslation.swift
//  Daisy
//
//  The Daisy key's translation command (03.11.2026, a user's ask in the
//  backlog 32 logs: «зажимаешь клавишу, и твоя речь переводится»). The
//  language is said, never set in Settings (Egor): «переведи на
//  португальский: …» or «…, переведи на португальский», and what goes in
//  is the translation. Nothing is remembered between holds (Egor 03.11).
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

    /// Where the result goes, as the other commands decide it: words said
    /// go in at the caret; with only the command said, an editable
    /// selection is translated in place unless it is «for me».
    func kind(hasSelection: Bool, selectionEditable: Bool) -> DaisyKeyCommandKind {
        guard text.isEmpty, hasSelection else { return .write }
        return selectionEditable && !forMe ? .edit : .answer
    }
}

// MARK: - Recognizing it (no model)

nonisolated enum DaisyKeyTranslateParser {
    /// The verb itself. The infinitive only when asked for: «можешь
    /// перевести…» — «Задача: перевести на английский» is a to-do (review 03.11).
    static let verbs: Set<String> = ["переведи", "translate"]
    static let infinitive = "перевести"
    static let askWords: Set<String> = ["можешь", "можете", "can", "could", "would"]
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
    /// Before a command at the end, these make it part of the sentence:
    /// «попроси его перевести на английский», "ask them to translate into…".
    static let notACommandBefore: Set<String> = ["to", "чтобы", "надо", "нужно", "попроси", "просил", "просила"]
    /// Text that opens with one of these asks for something else first —
    /// «Напиши Пете, что я согласен. Переведи на английский» is a letter to
    /// write in English, not «Напиши Пете…» word for word (review 03.11):
    /// the model gets it as the command it is. (A note opening never gets
    /// here: «запиши…» is a note before any command is looked for.)
    static var commandOpenings: Set<String> {
        DaisyKeyCommandParser.editVerbs.union(DaisyKeyCommandParser.writeVerbs).union(DaisyKeyCommandParser.makeVerbs)
            .union(DaisyKeyCommandParser.answerOpenings.filter { $0.count == 1 }.compactMap(\.first))
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
        let words = tokens.map(DaisyKeyIntentParser.normalized)
        guard !words.isEmpty else { return nil }
        let opensWithVerb = verbs.contains(words[0]) || (asked && words[0] == infinitive)
        // The language first: «переведи на португальский: привет».
        if opensWithVerb, let command = command(words, from: 0, macRegion: macRegion, colons: colons(in: tokens)) {
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
                }
                guard taken > 0 else { break }
                textOpened = rest[taken - 1].hasSuffix(":")
                rest.removeFirst(taken)
            }
            return DaisyKeyTranslation(target: command.target, text: textBetween(leadTrimmed(rest.joined(separator: " "))), forMe: forMe)
        }
        // The text between: «переведи «добрый день» на японский»,
        // "translate good morning into Japanese".
        if opensWithVerb, let tail = tailCommand(words, macRegion: macRegion) {
            let middle = (1..<tail.start).filter { !fillerWords.contains(words[$0]) }
            let text = middle.isEmpty ? "" : leadTrimmed(tokens[middle.first!...middle.last!].joined(separator: " "))
            let forMe = (1..<tail.start).contains { forMeWords.contains(words[$0]) || meWords.contains(words[$0]) }
            return DaisyKeyTranslation(target: tail.target, text: textBetween(text), forMe: forMe)
        }
        // The language last: «привет, как дела? Переведи на португальский».
        // Only a whole last clause, opened by the verb (or «можешь
        // перевести», "please translate", "can you translate") after a stop
        // or a comma, with nothing after it but «пожалуйста». The text is
        // as said: only the name before it goes («Давай встретимся…» keeps
        // its «Давай», review 03.11).
        return textFirst(said, macRegion: macRegion)
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
        for start in stride(from: words.count - 1, to: 0, by: -1) where verbs.contains(words[start]) || words[start] == infinitive {
            guard let command = command(words, from: start, macRegion: macRegion, colons: []),
                  words[command.end...].allSatisfy({ courtesy.contains($0) || $0.isEmpty }) else { continue }
            var clause = start
            if words[start] == infinitive {
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
                  !commandOpenings.contains(first) else { return nil }
            return DaisyKeyTranslation(target: command.target, text: text, forMe: command.forMe)
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

    /// «на японский» / "into Japanese" closing the request, after the verb
    /// that opened it: where it starts, and the language.
    private static func tailCommand(_ words: [String], macRegion: String?) -> (start: Int, target: DaisyKeyTranslationTarget)? {
        var end = words.count
        while end > 1, courtesy.contains(words[end - 1]) || words[end - 1].isEmpty { end -= 1 }
        for start in stride(from: end - 1, to: 1, by: -1) where words[start] == ruInto || enInto.contains(words[start]) {
            if let found = DaisyKeyLanguageNames.match(words, at: start + 1, macRegion: macRegion, colons: []), found.end == end {
                return (start, found.target)
            }
        }
        return nil
    }

    /// The command's words from the verb at `start`: the target and where
    /// the command ends. nil when no language is named.
    /// Where a word ends with a colon: the text opens after it.
    private static func colons(in tokens: [String]) -> Set<Int> {
        Set(tokens.indices.filter { tokens[$0].hasSuffix(":") })
    }

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
        guard i < words.count else { return nil }
        if words[i] == ruInto || enInto.contains(words[i]),
           let found = DaisyKeyLanguageNames.match(words, at: i + 1, macRegion: macRegion, colons: colons) {
            return (found.target, found.end, forMe)
        }
        // «по-португальски», or «по португальски» as some engines write it.
        if let found = DaisyKeyLanguageNames.matchAdverb(words, at: i, macRegion: macRegion) {
            return (found.target, found.end, forMe)
        }
        return nil
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
