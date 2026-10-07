//
//  LayoutFix.swift
//  Daisy
//
//  Decides WHETHER a piece of text was typed in the wrong keyboard
//  layout, and into which layout it should have gone. The conversion
//  itself is exact (see KeyboardLayout); everything hard lives here,
//  because "чуфе" and "asdf" are both гибберish and only one of them is
//  a mistake.
//
//  Two modes with deliberately different standards of proof:
//
//   - `deliberate` — the user pressed the fix key. They have asserted
//     the text is wrong, so we convert and get out of the way. Refusing
//     because no dictionary recognises either side would be maddening
//     precisely when it matters (passwords typed into a visible field,
//     product names, slang).
//
//   - `judge` — the automatic path, and nobody asked for it. The bar
//     has to be high enough that being wrong is rare, because being
//     wrong here means silently rewriting what someone typed. The word
//     must be unknown to the system spell checker in the language it
//     was typed in AND a real word in the language it converts to. Both
//     dictionaries must actually be installed; without them we do
//     nothing rather than guess — and say which one was missing, since
//     from the outside that is indistinguishable from a broken feature.
//
//  The spell checker is `NSSpellChecker`, i.e. the dictionaries the user
//  already has for the languages they already type in. No word list of
//  ours to ship, stale or bias.
//

import AppKit
import Carbon.HIToolbox

@MainActor
enum LayoutFix {

    nonisolated struct Fix: Sendable {
        let text: String
        /// The layout the text should have been typed with — the caller
        /// may switch to it so the NEXT word lands right.
        let target: KeyboardLayout
    }

    /// Shortest word we will touch automatically. Two-letter words are
    /// «по» / «on» / «то» — real in one language and plausible junk in
    /// the other, and a wrong flip on a two-letter word is as annoying
    /// as the mistake it fixes.
    /// `nonisolated`: the event tap reads it from its own callback.
    nonisolated static let minAutomaticWordLength = 3

    // MARK: - Deliberate (the user asked)

    /// Convert text the user has selected (or just typed) into whichever
    /// installed layout makes it real words. Falls back to converting
    /// out of the ACTIVE layout when no dictionary can judge — that is
    /// the single most likely intent, and the user can press again.
    static func deliberate(_ text: String) -> Fix? {
        let layouts = KeyboardLayouts.shared.installed
        guard layouts.count > 1 else { return nil }

        var fallback: Fix?
        var best: (fix: Fix, score: Double)?
        /// How real the text already is, judged ONLY in the language of a
        /// layout it converts out of — i.e. one it was typed on. Judged in
        /// any language it would be wrong: the English checker passes
        /// every Cyrillic word as correct, so «руддщ» would never become
        /// «hello» again.
        var original = 0.0
        // Source order matters: the active layout first, because it is
        // what produced the text — unless the user already switched
        // layouts before pressing the key, which is why the others are
        // tried at all.
        for source in orderedSources(layouts) {
            for target in layouts where target.id != source.id {
                guard let converted = source.converting(text, to: target) else { continue }
                // Only a layout the LETTERS were typed on: the English
                // checker passes Cyrillic, and punctuation alone makes
                // Russian text "convert" out of US (review find).
                if source.typesAllLetters(of: text) {
                    original = max(original, realWordRatio(in: text, language: source.language))
                }
                let candidate = Fix(text: converted, target: target)
                // Score, don't first-hit: with three layouts installed a
                // single incidental real word ("a") in the wrong
                // conversion would otherwise win.
                let score = realWordRatio(in: converted, language: target.language)
                if score > (best?.score ?? 0) { best = (candidate, score) }
                if fallback == nil { fallback = candidate }
            }
        }
        // Already right: the text reads as real words in the layout it is
        // in, and no conversion reads better. A user's
        // «daisy-provider-api-key» became «фдштф-зкфыщдщмф-фзш-лун» on a
        // stray press (07.10.2026); now the key says so and leaves it.
        if original > 0.5, original >= (best?.score ?? 0) { return nil }
        if let best, best.score > 0.5 { return best.fix }
        // Nothing the dictionaries recognise. The user still asked, so
        // convert out of the ACTIVE layout — the most likely intent — and
        // let them press again if it was the other way round.
        return fallback
    }

    // MARK: - Automatic (nobody asked)

    /// Why a word was left alone. The REASON only — never the word,
    /// which is someone's typing and has no business in a log.
    ///
    /// This exists because "nothing happens" has half a dozen causes
    /// that look identical from the outside, and the first bug report
    /// said exactly that and nothing more.
    enum Refusal: String, Sendable {
        case tooShort
        case noSecondLayout
        case noCurrentLayout
        /// No spell-check dictionary for the language of the layout the
        /// word was typed on.
        case noDictionaryForSourceLayout
        /// Dictionaries exist for the source but for none of the targets.
        case noDictionaryForTargetLayout
        case alreadyARealWord
        case nothingRealOnTheOtherSide
        /// Undone once already — see `LayoutFixUndo`/`LayoutFixExceptions`.
        /// One bad call is now one lesson, not a standing annoyance.
        case learnedException

        /// True when the reason is a property of the MACHINE rather than
        /// of the word. Those are the ones worth a log line: they mean
        /// the feature is dead until something changes, where the others
        /// just mean this particular word was fine.
        var isStructural: Bool {
            switch self {
            case .noSecondLayout, .noCurrentLayout,
                 .noDictionaryForSourceLayout, .noDictionaryForTargetLayout:
                return true
            case .tooShort, .alreadyARealWord, .nothingRealOnTheOtherSide, .learnedException:
                return false
            }
        }
    }

    /// A finished word, judged strictly. A nil `fix` means "leave it
    /// alone", which is the answer most of the time and has to stay
    /// cheap; `refusal` says why, for the log.
    /// `exceptions` is required, not defaulted to `.shared` — a
    /// default value referencing a `@MainActor` singleton runs into
    /// the same actor-isolation trap as a stored default would, and
    /// the two real call sites (`prepareVerdict`, `consider`, both
    /// already `@MainActor`) pass `.shared` explicitly anyway. The
    /// parameter exists so a test can hand in a throwaway instance
    /// instead of mutating the one real UserDefaults-backed list a
    /// person's undos have taught.
    static func judge(
        _ word: String,
        exceptions: LayoutFixExceptions
    ) -> (fix: Fix?, refusal: Refusal?) {
        guard word.count >= minAutomaticWordLength,
              word.contains(where: { $0.isLetter }) else { return (nil, .tooShort) }
        // Cheapest possible gate, checked before anything cross-process
        // (KeyboardLayouts lookups, the spell checker): this is the
        // branch every automatically-typed word passes through, and a
        // word undone once should stay left alone without paying for a
        // dictionary round trip on every later repeat.
        guard !exceptions.contains(word) else { return (nil, .learnedException) }
        let layouts = KeyboardLayouts.shared.installed
        guard layouts.count > 1 else { return (nil, .noSecondLayout) }
        guard let source = KeyboardLayouts.shared.current else { return (nil, .noCurrentLayout) }
        // A word we can't judge in the language it was typed in is a word
        // we don't touch.
        guard let sourceLanguage = checkerLanguage(for: source) else {
            return (nil, .noDictionaryForSourceLayout)
        }
        // Already a real word where it stands → by definition not a
        // layout mistake, however odd it looks to us.
        guard !isSpelled(word, language: sourceLanguage) else { return (nil, .alreadyARealWord) }

        var anyTargetJudgeable = false
        for target in layouts where target.id != source.id {
            guard let language = checkerLanguage(for: target) else { continue }
            anyTargetJudgeable = true
            guard let converted = source.converting(word, to: target),
                  isSpelled(converted, language: language) else { continue }
            return (Fix(text: converted, target: target), nil)
        }
        return (nil, anyTargetJudgeable ? .nothingRealOnTheOtherSide : .noDictionaryForTargetLayout)
    }

    /// One line for the log report: the layouts we can convert between
    /// and, for each, the spell-checker language it resolves to.
    ///
    /// `none` in that column is the likeliest reason automatic fixing
    /// does nothing on a Mac where every switch looks on — without a
    /// dictionary for the language a word was typed in we cannot tell a
    /// mistake from a word, and standing down is the only safe answer.
    /// Cheap enough to compute on demand and it names the whole failure
    /// class without asking the user to reproduce anything.
    static func diagnostics() -> String {
        let layouts = KeyboardLayouts.shared.installed
        guard !layouts.isEmpty else { return "layouts=none" }
        let described = layouts.map { layout in
            let short = layout.id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
            return "\(short)[\(layout.language ?? "?")→\(checkerLanguage(for: layout) ?? "none")]"
        }
        return "layouts=\(described.joined(separator: ", "))"
            + " current=\(KeyboardLayouts.shared.current?.name ?? "?")"
            + " inputMethod=\(KeyboardLayouts.shared.isInputMethodActive)"
            + " secureInput=\(IsSecureEventInputEnabled())"
    }

    /// Spin the spell-check service up ahead of the first keystroke that
    /// needs it — the first `checkSpelling` launches AppleSpell, and that
    /// is not a cost to pay inside someone's typing.
    static func warmUp() {
        _ = checkerLanguages
        _ = isSpelled("warmup", language: "en")
    }

    // MARK: - Judging

    private static func orderedSources(_ layouts: [KeyboardLayout]) -> [KeyboardLayout] {
        guard let current = KeyboardLayouts.shared.current else { return layouts }
        return [current] + layouts.filter { $0.id != current.id }
    }

    /// Share of the words in `text` the dictionary recognises — 0 when
    /// there is no dictionary for the language, so "can't judge" and
    /// "judged badly" read the same to callers.
    private static func realWordRatio(in text: String, language: String?) -> Double {
        guard let language, let checker = resolvedLanguage(language) else { return 0 }
        // Runs of letters, not whitespace-separated tokens: a hyphenated
        // name or an identifier is several words, and checked whole it is
        // one "misspelling" in every language.
        let words = text
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        guard !words.isEmpty else { return 0 }
        let known = words.filter { isSpelled($0, language: checker) }.count
        return Double(known) / Double(words.count)
    }

    private static func isSpelled(_ word: String, language: String) -> Bool {
        let range = NSSpellChecker.shared.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        return range.location == NSNotFound
    }

    private static func checkerLanguage(for layout: KeyboardLayout) -> String? {
        guard let language = layout.language else { return nil }
        return resolvedLanguage(language)
    }

    /// The identifier the SPELL CHECKER knows for a layout's language, or
    /// nil when it knows none.
    ///
    /// Load-bearing, not defensive, and the two sides don't even spell
    /// languages the same way: `kTISPropertyInputSourceLanguages` gives
    /// BCP-47 with hyphens ("pt-PT"), `NSSpellChecker.availableLanguages`
    /// gives underscores ("pt_PT"). Worse, `checkSpelling` with a
    /// language it doesn't know reports every word as correctly spelled —
    /// so a failed match wouldn't weaken the judgement, it would invert
    /// it.
    private static func resolvedLanguage(_ language: String) -> String? {
        let wanted = normalized(language)
        if let exact = checkerLanguages[wanted] { return exact }
        guard let primary = wanted.split(separator: "-").first else { return nil }
        return checkerLanguages[String(primary)]
    }

    private static func normalized(_ language: String) -> String {
        language.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    /// Normalised identifier → the identifier to hand back to
    /// NSSpellChecker. Both the full form and the primary subtag are
    /// keyed, so "ru" finds "ru_RU". Cached: the list only changes when a
    /// dictionary is installed, and this is consulted per typed word.
    private static let checkerLanguages: [String: String] = {
        var out: [String: String] = [:]
        for language in NSSpellChecker.shared.availableLanguages {
            let key = normalized(language)
            out[key] = language
            if let primary = key.split(separator: "-").first, out[String(primary)] == nil {
                out[String(primary)] = language
            }
        }
        return out
    }()
}
