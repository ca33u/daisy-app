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
//     the text is wrong, so we convert and get out of the way — always,
//     both ways, as many times as the key is pressed. A word that is
//     real where it stands is converted like any other: «сайт» is a
//     word, and the person wanted «cfqn» (an abbreviation, a password,
//     a product name). The dictionary only helps choose between two
//     possible conversions; it never refuses one.
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

    /// Convert text the user has selected (or just typed) into another
    /// installed layout. Always: the person pressed the key, and whether
    /// the text already reads as words is not ours to judge (Konstantin,
    /// 09.11.2026: «сайт» wouldn't become «cfqn»). From 07.10 to 09.11
    /// the key left real words alone, after a stray press turned
    /// «daisy-provider-api-key» into Cyrillic; a stray press now costs a
    /// second one, which puts the text back. Nil only when no installed
    /// layout would change a character.
    static func deliberate(_ text: String) -> Fix? {
        LayoutFixManual.conversion(
            of: text,
            layouts: KeyboardLayouts.shared.installed,
            currentID: KeyboardLayouts.shared.current?.id,
            realWordShare: { realWordRatio(in: $0, language: $1.language) }
        )
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

// MARK: - Which conversion the fix key makes

/// The fix key's choice of conversion. Pure — the layouts, the active
/// one and the dictionary are handed in — so it is checked without a
/// keyboard or a spell checker.
nonisolated enum LayoutFixManual {
    /// `text` as another layout would have typed it, or nil when no
    /// layout changes a character of it (digits, one layout, two that
    /// share every key the text uses).
    ///
    /// Never a refusal over what the text means. The rules only choose
    /// WHICH conversion:
    ///
    ///  - out of a layout that types every letter of the text — the
    ///    active one first, then the others. With Russian and English
    ///    installed that alone decides it: Cyrillic goes to Latin, Latin
    ///    to Cyrillic, whichever layout is active, so pressing again on
    ///    the result is the way back;
    ///  - when no single layout types it all (a selection with both
    ///    scripts), out of any layout, the active one first;
    ///  - among several possible conversions, the one the dictionary of
    ///    its language reads as words (more than half of them); with no
    ///    such answer, the first in the order above.
    ///
    /// `realWordShare` is the share of the words of a converted text its
    /// target layout's dictionary knows, 0 when it has none.
    static func conversion(
        of text: String,
        layouts: [KeyboardLayout],
        currentID: String?,
        realWordShare: (_ converted: String, _ target: KeyboardLayout) -> Double
    ) -> LayoutFix.Fix? {
        guard layouts.count > 1 else { return nil }
        let ordered = layouts.filter { $0.id == currentID } + layouts.filter { $0.id != currentID }
        let typists = ordered.filter { $0.typesAllLetters(of: text) }
        var first: LayoutFix.Fix?
        var best: (fix: LayoutFix.Fix, share: Double)?
        for source in typists.isEmpty ? ordered : typists {
            for target in ordered where target.id != source.id {
                guard let converted = source.converting(text, to: target) else { continue }
                let fix = LayoutFix.Fix(text: converted, target: target)
                if first == nil { first = fix }
                // Scored, not first-hit: with three layouts installed one
                // incidental real word in the wrong conversion would
                // otherwise win.
                let share = realWordShare(converted, target)
                if share > (best?.share ?? 0) { best = (fix, share) }
            }
        }
        if let best, best.share > 0.5 { return best.fix }
        return first
    }
}
