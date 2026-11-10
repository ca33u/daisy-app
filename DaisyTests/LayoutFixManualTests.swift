//
//  LayoutFixManualTests.swift
//  DaisyTests
//
//  Konstantin 09.11.2026: «сайт» wouldn't become «cfqn» — the fix key saw
//  a real word and left it. The key now converts whatever it is given,
//  both ways, every press; the automatic watcher keeps its caution. What
//  decides is pure and pinned here: which conversion the key makes
//  (`LayoutFixManual`), what the tap remembers as «the last word»
//  (`WordBuffer`'s run and the spaces after it), and the small rules
//  around them. The keystrokes themselves need a real keyboard and a real
//  field.
//

import AppKit
import Carbon.HIToolbox
import Testing
@testable import Daisy

// MARK: - Fixtures

/// Layouts over the same synthetic keys, one character per key and per
/// shifted key — the letter rows of QWERTY with the punctuation keys that
/// are letters on ЙЦУКЕН.
nonisolated private enum Layouts {
    static func make(id: String, language: String?, unshifted: String, shifted: String) -> KeyboardLayout {
        var charByPress: [KeyPress: Character] = [:]
        var pressByChar: [Character: KeyPress] = [:]
        for (index, character) in unshifted.enumerated() {
            let press = KeyPress(keyCode: UInt16(index + 1), shift: false)
            charByPress[press] = character
            pressByChar[character] = press
        }
        for (index, character) in shifted.enumerated() {
            let press = KeyPress(keyCode: UInt16(index + 1), shift: true)
            charByPress[press] = character
            if pressByChar[character] == nil { pressByChar[character] = press }
        }
        return KeyboardLayout(id: id, name: id, language: language, charByPress: charByPress, pressByChar: pressByChar)
    }

    static let us = make(
        id: "test.US", language: "en",
        unshifted: "`qwertyuiop[]asdfghjkl;'zxcvbnm,./",
        shifted: "~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?"
    )
    static let russian = make(
        id: "test.Russian", language: "ru",
        unshifted: "ёйцукенгшщзхъфывапролджэячсмитьбю.",
        shifted: "ЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,"
    )
    /// ЙЦУКЕН with the four keys Ukrainian types differently.
    static let ukrainian = make(
        id: "test.Ukrainian", language: "uk",
        unshifted: "'йцукенгшщзхїфівапролджєячсмитьбю.",
        shifted: "₴ЙЦУКЕНГШЩЗХЇФІВАПРОЛДЖЄЯЧСМИТЬБЮ,"
    )
    /// QWERTY again under another name, one key apart.
    static let british = make(
        id: "test.British", language: "en",
        unshifted: "§qwertyuiop[]asdfghjkl;'zxcvbnm,./",
        shifted: "±QWERTYUIOP{}ASDFGHJKL:@ZXCVBNM<>?"
    )
}

/// A dictionary by language: the share of a text's words it knows.
nonisolated private func share(_ words: [String: Set<String>]) -> (String, KeyboardLayout) -> Double {
    { text, target in
        guard let language = target.language, let known = words[language] else { return 0 }
        let runs = text.split(whereSeparator: { !$0.isLetter }).map { $0.lowercased() }
        guard !runs.isEmpty else { return 0 }
        return Double(runs.filter(known.contains).count) / Double(runs.count)
    }
}

// MARK: - Which conversion the key makes

@Suite("The fix key converts whatever it is given")
struct LayoutFixManualTests {
    /// A dictionary that knows the Russian words and no English one —
    /// the shape of the bug: «сайт» is real, «cfqn» is nothing.
    private let russianWords: [String: Set<String>] = ["ru": ["сайт", "привет", "мир", "даже", "хорошо", "мы"], "en": []]

    private func convert(
        _ text: String,
        active: KeyboardLayout? = Layouts.russian,
        layouts: [KeyboardLayout] = [Layouts.us, Layouts.russian],
        words: [String: Set<String>]? = nil
    ) -> LayoutFix.Fix? {
        LayoutFixManual.conversion(of: text, layouts: layouts, currentID: active?.id, realWordShare: share(words ?? russianWords))
    }

    @Test("A real word is converted like any other")
    func aRealWordIsConverted() {
        // The word is right where it stands, and nothing reads the
        // conversion as a word: converted all the same.
        #expect(convert("сайт")?.text == "cfqn")
        #expect(convert("сайт")?.target.id == Layouts.us.id)
        // Whichever layout is active when the key is pressed.
        #expect(convert("сайт", active: Layouts.us)?.text == "cfqn")
        #expect(convert("сайт", active: nil)?.text == "cfqn")
        // And with no dictionary anywhere.
        #expect(convert("сайт", words: [:])?.text == "cfqn")
    }

    @Test("An abbreviation goes both ways")
    func abbreviations() {
        #expect(convert("ТРС")?.text == "NHC")
        #expect(convert("NHC")?.text == "ТРС")
        #expect(convert("NHC")?.target.id == Layouts.russian.id)
        #expect(convert("CFQN", active: Layouts.us)?.text == "САЙТ")
        #expect(convert("САЙТ", active: Layouts.us)?.text == "CFQN")
    }

    @Test("Every press converts again, there and back")
    func everyPressConverts() {
        for start in ["сайт", "cfqn", "ТРС", "ghbdtn", "Ghbdtn, rfr ltkf?", "daisy-provider-api-key"] {
            // The source follows the conversion, as it does when «switch
            // the layout too» is on …
            var text = start
            var active: KeyboardLayout? = Layouts.russian
            var seen: [String] = []
            for _ in 0..<6 {
                guard let fix = convert(text, active: active) else {
                    Issue.record("\(text) was refused")
                    return
                }
                text = fix.text
                active = fix.target
                seen.append(text)
            }
            #expect(seen[1] == start && seen[3] == start && seen[5] == start)
            #expect(seen[0] != start && seen[0] == seen[2] && seen[2] == seen[4])
            // … and when it stays where it was.
            text = start
            for press in 0..<6 {
                guard let fix = convert(text, active: Layouts.us) else {
                    Issue.record("\(text) was refused")
                    return
                }
                text = fix.text
                #expect((text == start) == (press % 2 == 1))
            }
        }
    }

    @Test("One script: the active layout doesn't decide")
    func oneScript() {
        // The person already switched to Russian before pressing.
        #expect(convert("ghbdtn", active: Layouts.russian)?.text == "привет")
        #expect(convert("ghbdtn", active: Layouts.us)?.text == "привет")
        #expect(convert("привет", active: Layouts.us)?.text == "ghbdtn")
    }

    @Test("The punctuation keys are letters on the other layout")
    func punctuationKeys() {
        #expect(convert("lf;t")?.text == "даже")
        #expect(convert("[jhjij")?.text == "хорошо")
        #expect(convert("даже")?.text == "lf;t")
        #expect(convert("ghbdtn,")?.text == "приветб")
    }

    @Test("Case and spaces stay")
    func caseAndSpaces() {
        #expect(convert("Ghbdtn vbh ")?.text == "Привет мир ")
        #expect(convert(" ghbdtn\nvbh")?.text == " привет\nмир")
    }

    @Test("Both scripts in one selection: the dictionary chooses, else the active layout is the source")
    func bothScripts() {
        // «привет» typed on the wrong layout, «мир» on the right one.
        #expect(convert("ghbdtn мир", active: Layouts.russian)?.text == "привет мир")
        #expect(convert("ghbdtn мир", active: Layouts.us)?.text == "привет мир")
        // Nothing to go by: out of the layout that is active.
        #expect(convert("ghbdtn мир", active: Layouts.russian, words: [:])?.text == "ghbdtn vbh")
        #expect(convert("ghbdtn мир", active: Layouts.us, words: [:])?.text == "привет мир")
    }

    @Test("Nothing a layout changes")
    func nothingToSwitch() {
        #expect(convert("2026") == nil)
        #expect(convert("") == nil)
        #expect(convert("   ") == nil)
        #expect(convert("сайт", layouts: [Layouts.russian]) == nil)
        // Two layouts that share every key the word uses.
        #expect(convert("hello", active: Layouts.us, layouts: [Layouts.us, Layouts.british]) == nil)
    }

    @Test("Three layouts: the dictionary chooses the target, else the active one comes first")
    func threeLayouts() {
        let three = [Layouts.us, Layouts.russian, Layouts.ukrainian]
        // «vs» is «мы» on Russian and «мі» on Ukrainian.
        #expect(convert("vs", active: Layouts.ukrainian, layouts: three)?.text == "мы")
        #expect(convert("vs", active: Layouts.ukrainian, layouts: three)?.target.id == Layouts.russian.id)
        #expect(convert("vs", active: Layouts.ukrainian, layouts: three, words: ["uk": ["мі"]])?.text == "мі")
        // No dictionary knows either: into the layout that is active.
        #expect(convert("vs", active: Layouts.ukrainian, layouts: three, words: [:])?.target.id == Layouts.ukrainian.id)
        #expect(convert("vs", active: Layouts.russian, layouts: three, words: [:])?.target.id == Layouts.russian.id)
        // Cyrillic both Cyrillic layouts type goes to Latin, not to the
        // other Cyrillic one.
        #expect(convert("сайт", active: Layouts.russian, layouts: three)?.text == "cfqn")
        #expect(convert("сайт", active: Layouts.ukrainian, layouts: three)?.text == "cfqn")
    }

    @Test("No dictionary answer is a refusal")
    func theDictionaryNeverRefuses() {
        let layouts = [Layouts.us, Layouts.russian]
        for answer in [0.0, 0.5, 1.0] {
            let fix = LayoutFixManual.conversion(of: "сайт", layouts: layouts, currentID: Layouts.russian.id) { _, _ in answer }
            #expect(fix?.text == "cfqn")
        }
    }
}

// MARK: - On this Mac's own layouts

/// The same promises through the real `uchr` tables and the system spell
/// checker — run only on a Mac with a US and a Russian layout enabled and
/// no third (the keys these words sit on are the same on both Russian
/// layouts Apple ships). Elsewhere they are skipped, and say so.
@MainActor
struct LayoutFixOnThisMacTests {
    private let scratch = ScratchDefaults("LayoutFixOnThisMac")

    static var hasBothLayouts: Bool {
        let ids = Set(KeyboardLayouts.shared.installed.map(\.id))
        let latin: Set = ["com.apple.keylayout.US", "com.apple.keylayout.ABC"]
        let russian: Set = ["com.apple.keylayout.Russian", "com.apple.keylayout.RussianWin"]
        return ids.count == 2 && !ids.isDisjoint(with: latin) && !ids.isDisjoint(with: russian)
    }

    @Test(.enabled("Needs exactly a US and a Russian keyboard layout") { await LayoutFixOnThisMacTests.hasBothLayouts })
    func theKeyConvertsRealWordsAndBack() {
        #expect(LayoutFix.deliberate("сайт")?.text == "cfqn")
        #expect(LayoutFix.deliberate("cfqn")?.text == "сайт")
        #expect(LayoutFix.deliberate("ТРС")?.text == "NHC")
        #expect(LayoutFix.deliberate("NHC")?.text == "ТРС")
        #expect(LayoutFix.deliberate("ghbdtn")?.text == "привет")
        #expect(LayoutFix.deliberate("привет")?.text == "ghbdtn")
        #expect(LayoutFix.deliberate("lf;t")?.text == "даже")
        // The stray press of 07.10: converted now, and a second press is
        // the way back.
        let key = "daisy-provider-api-key"
        let there = LayoutFix.deliberate(key)?.text
        #expect(there != nil && there != key)
        #expect(there.flatMap { LayoutFix.deliberate($0)?.text } == key)
        #expect(LayoutFix.deliberate("2026") == nil)
    }

    /// A second press is the way back for a sentence too, punctuation and
    /// all: the keypad repeats «,», «.», «*», «+» and used to be what
    /// they mapped back to («привет, как дела?» returned as «приветю как
    /// дела?»).
    @Test(.enabled("Needs exactly a US and a Russian keyboard layout") { await LayoutFixOnThisMacTests.hasBothLayouts })
    func aSentenceComesBackWithItsPunctuation() {
        for text in ["привет, как дела?", "Ghbdtn, rfr ltkf?", "Ты где; я тут.", "lf;t: 2+2*2", ";", "a^b"] {
            let there = LayoutFix.deliberate(text)?.text
            #expect(there != nil && there != text, "\(text) wasn't converted")
            #expect(there.flatMap { LayoutFix.deliberate($0)?.text } == text, "\(text) didn't come back")
        }
    }

    /// The watcher is as careful as it was: a real word is left alone.
    @Test(.enabled("Needs exactly a US and a Russian keyboard layout") { await LayoutFixOnThisMacTests.hasBothLayouts })
    func theWatcherStillLeavesARealWordAlone() {
        let exceptions = LayoutFixExceptions(defaults: scratch.make())
        #expect(LayoutFix.judge("сайт", exceptions: exceptions).fix == nil)
        #expect(LayoutFix.judge("hello", exceptions: exceptions).fix == nil)
    }
}

// MARK: - What the tap remembers as the last word

/// Keys as `LayoutAutoFix.handle` feeds them: a letter (or «'», «-») goes
/// into the word, anything else that types ends it.
nonisolated private func typeKeys(_ text: String, into buffer: WordBuffer) {
    for character in text {
        if character.isLetter || character == "'" || character == "-" {
            _ = buffer.append(character)
        } else {
            _ = buffer.take(boundary: character)
        }
    }
}

@Suite("The word the fix key takes from the typing")
struct LayoutFixTypedRunTests {
    private func candidate(_ buffer: WordBuffer, within window: TimeInterval = 3) -> [String]? {
        buffer.wordInFlightOrJustFinished(within: window).map { [$0.word, String($0.presses), $0.trailing] }
    }

    @Test func aWordStillBeingTyped() {
        let buffer = WordBuffer()
        typeKeys("cfqn", into: buffer)
        #expect(candidate(buffer) == ["cfqn", "4", ""])
        // It has no age: nothing was pressed since.
        #expect(candidate(buffer, within: -1) == ["cfqn", "4", ""])
    }

    /// Konstantin 09.11: the last word changes with a space already
    /// typed after it — or two, however long ago.
    @Test func theSpacesAfterItAreKept() {
        let buffer = WordBuffer()
        typeKeys("cfqn ", into: buffer)
        #expect(candidate(buffer) == ["cfqn", "4", " "])
        typeKeys(" ", into: buffer)
        #expect(candidate(buffer) == ["cfqn", "4", "  "])
        #expect(candidate(buffer, within: -1) == ["cfqn", "4", "  "])
    }

    /// «ж», «б», «х» are typed with «;», «,», «[» on the wrong layout:
    /// the run since the last space is the word, as on screen.
    @Test func punctuationKeysBelongToTheWord() {
        let buffer = WordBuffer()
        typeKeys("lf;t", into: buffer)
        #expect(candidate(buffer) == ["lf;t", "4", ""])
        typeKeys(" [jhjij", into: buffer)
        #expect(candidate(buffer) == ["[jhjij", "6", ""])
        typeKeys(" ghbdtn, ", into: buffer)
        #expect(candidate(buffer) == ["ghbdtn,", "7", " "])
    }

    /// The watcher's own word is still a run of letters, as it was.
    @Test func theWatchersWordIsStillLettersOnly() {
        let buffer = WordBuffer()
        typeKeys("lf", into: buffer)
        let ended = buffer.take(boundary: ";")
        #expect(ended?.word == "lf" && ended?.presses == 2)
        let next = buffer.append("t")
        #expect(next.word == "t" && next.presses == 1)
        #expect(buffer.take(boundary: " ")?.word == "t")
        #expect(buffer.take(boundary: " ") == nil)
    }

    @Test func theNextWordTakesItsPlace() {
        let buffer = WordBuffer()
        typeKeys("cfqn l", into: buffer)
        #expect(candidate(buffer) == ["l", "1", ""])
        // Backspaced away again: the caret is back after «cfqn ».
        #expect(buffer.deleteLast())
        #expect(candidate(buffer) == ["cfqn", "4", " "])
        // One more backspace is into text nobody tracked.
        #expect(!buffer.deleteLast())
    }

    @Test func backspaceInsideTheWord() {
        let buffer = WordBuffer()
        typeKeys("lf;tt", into: buffer)
        #expect(buffer.deleteLast())
        #expect(candidate(buffer) == ["lf;t", "4", ""])
    }

    /// The fix key's own press ends the word on its way past the tap: the
    /// word stays its candidate, for a moment.
    @Test func theFixKeysOwnPressKeepsItBriefly() {
        let buffer = WordBuffer()
        typeKeys("cfqn", into: buffer)
        buffer.clear()
        #expect(candidate(buffer) == ["cfqn", "4", ""])
        #expect(candidate(buffer, within: -1) == nil)
        // After «word, space» too: the same key code is keypad Enter or
        // an F-key, and what those did to the field nobody can say.
        let spaced = WordBuffer()
        typeKeys("cfqn ", into: spaced)
        #expect(candidate(spaced, within: -1) == ["cfqn", "4", " "])
        spaced.clear()
        #expect(candidate(spaced) == ["cfqn", "4", " "])
        #expect(candidate(spaced, within: -1) == nil)
    }

    /// What a command key did is unknown, so typing after it doesn't
    /// continue the word it ended.
    @Test func aSpaceAfterACommandKeyDropsTheWord() {
        let buffer = WordBuffer()
        typeKeys("cfqn", into: buffer)
        buffer.clear()
        typeKeys(" ", into: buffer)
        #expect(candidate(buffer) == nil)
    }

    @Test func aMovedCaretForgetsEverything() {
        let buffer = WordBuffer()
        typeKeys("cfqn ", into: buffer)
        buffer.discard()
        #expect(candidate(buffer) == nil)
        typeKeys("ghb", into: buffer)
        buffer.discard()
        #expect(candidate(buffer) == nil)
    }

    @Test func tooLongToRetype() {
        let buffer = WordBuffer()
        typeKeys(String(repeating: "f", count: WordBuffer.maxPresses), into: buffer)
        #expect(candidate(buffer)?[1] == String(WordBuffer.maxPresses))
        typeKeys("f", into: buffer)
        #expect(candidate(buffer) == nil)
        #expect(buffer.deleteLast())
        #expect(candidate(buffer) == nil)
        typeKeys(" ", into: buffer)
        #expect(candidate(buffer) == nil)
        typeKeys("ab", into: buffer)
        #expect(candidate(buffer) == ["ab", "2", ""])
    }

    /// A word of the longest length takes one space after it and no more.
    @Test func spacesStopAtWhatTheKeyRetypes() {
        let buffer = WordBuffer()
        typeKeys(String(repeating: "f", count: WordBuffer.maxPresses) + " ", into: buffer)
        #expect(candidate(buffer)?[2] == " ")
        typeKeys(" ", into: buffer)
        #expect(candidate(buffer) == nil)
    }

    /// What the fix key typed itself is the last thing typed: the tap
    /// skips Daisy's own keystrokes, and without this the second and
    /// third press had nothing to go by in a browser or a chat.
    @Test func whatTheKeyTypedIsTheLastWord() {
        let buffer = WordBuffer()
        typeKeys("сайт", into: buffer)
        buffer.discard(leavingTyped: "cfqn", ifUntouchedSince: buffer.generation)
        #expect(candidate(buffer, within: -1) == ["cfqn", "4", ""])
        // Typing goes on from it, as from a word the person typed.
        typeKeys("s", into: buffer)
        #expect(candidate(buffer) == ["cfqns", "5", ""])

        buffer.discard(leavingTyped: "cfqn  ", ifUntouchedSince: buffer.generation)
        #expect(candidate(buffer, within: -1) == ["cfqn", "4", "  "])
        // A converted selection: its last word, as the screen is read.
        buffer.discard(leavingTyped: "cfqn ghj ТРС", ifUntouchedSince: buffer.generation)
        #expect(candidate(buffer) == ["ТРС", "3", ""])
        // Ending on a line break, or with no word in it: nothing.
        buffer.discard(leavingTyped: "cfqn\n", ifUntouchedSince: buffer.generation)
        #expect(candidate(buffer) == nil)
        buffer.discard(leavingTyped: "2026 ", ifUntouchedSince: buffer.generation)
        #expect(candidate(buffer) == nil)
    }

    /// A key the person pressed while Daisy was typing is in the field
    /// too, on an unknown side of the text: nothing is taken for granted.
    @Test func aKeyPressedMeanwhileLeavesNoCandidate() {
        let buffer = WordBuffer()
        typeKeys("сайт", into: buffer)
        let before = buffer.generation
        typeKeys("ы", into: buffer)
        buffer.discard(leavingTyped: "cfqn", ifUntouchedSince: before)
        #expect(candidate(buffer) == nil)
    }

    /// Six presses in a browser: convert, undo, convert … — every one of
    /// them finds a word.
    @Test func pressAfterPressThereIsAWord() {
        let buffer = WordBuffer()
        typeKeys("сайт ", into: buffer)
        var onScreen = "сайт "
        for press in 0..<6 {
            guard let found = buffer.wordInFlightOrJustFinished(within: 3) else {
                Issue.record("press \(press + 1) found no word")
                return
            }
            #expect(found.word + found.trailing == onScreen)
            onScreen = press % 2 == 0 ? "cfqn " : "сайт "
            buffer.discard(leavingTyped: onScreen, ifUntouchedSince: buffer.generation)
        }
    }

    @Test func digitsAloneAreARunWithNoWordInIt() {
        let buffer = WordBuffer()
        typeKeys("2026 ", into: buffer)
        #expect(candidate(buffer) == ["2026", "4", " "])
    }
}

// MARK: - The small rules around the key

@Suite("Around the fix key")
struct LayoutFixKeyRulesTests {
    /// ⌘C empties and refills the clipboard and waits for an answer: it is
    /// asked only where a selection can't be ruled out.
    @Test func theSelectionIsAskedForOnlyWhenThereMayBeOne() {
        // The field says nothing is selected, and can be believed.
        #expect(!LayoutFixService.asksForSelection(noSelectionReported: true, caretMayBeUnreliable: false, typedJustNow: false))
        // It won't say, or can't be believed (a browser, Electron).
        #expect(LayoutFixService.asksForSelection(noSelectionReported: false, caretMayBeUnreliable: false, typedJustNow: false))
        #expect(LayoutFixService.asksForSelection(noSelectionReported: true, caretMayBeUnreliable: true, typedJustNow: false))
        // A word was typed and nothing pressed since but the key: no
        // selection can have been made, whatever the field says.
        #expect(!LayoutFixService.asksForSelection(noSelectionReported: false, caretMayBeUnreliable: true, typedJustNow: true))
        #expect(!LayoutFixService.asksForSelection(noSelectionReported: true, caretMayBeUnreliable: true, typedJustNow: true))
    }

    /// One key event carries 20 UTF-16 units; the rest never arrives.
    @Test func textIsTypedInPiecesAnEventCanCarry() {
        #expect(LayoutAutoFix.typingChunks(of: "") == [])
        #expect(LayoutAutoFix.typingChunks(of: "cfqn").map(\.count) == [4])
        let long = String(repeating: "ж", count: 45)
        let chunks = LayoutAutoFix.typingChunks(of: long)
        #expect(chunks.map(\.count) == [20, 20, 5])
        #expect(String(decoding: chunks.flatMap { $0 }, as: UTF16.self) == long)
        // A character of two units is never split between two events.
        let emoji = String(repeating: "a", count: 19) + "😀b"
        let pieces = LayoutAutoFix.typingChunks(of: emoji)
        #expect(pieces.map(\.count) == [19, 3])
        #expect(String(decoding: pieces.flatMap { $0 }, as: UTF16.self) == emoji)
    }

    /// Only the fix key's own press keeps the word just typed as its
    /// candidate; any other command may have moved the caret.
    @Test func onlyTheFixKeysOwnPressKeepsTheWord() {
        // The fix shortcut ⇧⌘R and the Daisy key on ⌃⌥D, as registered.
        let fixKeys: Set<UInt32> = [
            HotkeyManager.carbonKey(keyCode: UInt32(kVK_ANSI_R), mods: UInt32(cmdKey | shiftKey)),
            HotkeyManager.carbonKey(keyCode: UInt32(kVK_ANSI_D), mods: UInt32(controlKey | optionKey)),
        ]
        func keeps(_ key: Int, _ flags: CGEventFlags) -> Bool {
            LayoutAutoFix.commandKeepsCandidate(keyCode: UInt16(key), flags: flags, fixKeys: fixKeys)
        }
        #expect(keeps(kVK_ANSI_R, [.maskCommand, .maskShift]))
        #expect(keeps(kVK_ANSI_D, [.maskControl, .maskAlternate]))
        // Caps Lock, Fn and the numeric pad are not part of a shortcut.
        #expect(keeps(kVK_ANSI_R, [.maskCommand, .maskShift, .maskAlphaShift, .maskSecondaryFn, .maskNumericPad]))
        // Select all, word left, paste, undo, a symbol typed with ⌥.
        #expect(!keeps(kVK_ANSI_A, .maskCommand))
        #expect(!keeps(kVK_LeftArrow, .maskAlternate))
        #expect(!keeps(kVK_ANSI_V, .maskCommand))
        #expect(!keeps(kVK_ANSI_Z, .maskCommand))
        #expect(!keeps(kVK_ANSI_Minus, .maskAlternate))
        // The same key with other modifiers is another command.
        #expect(!keeps(kVK_ANSI_R, .maskCommand))
        #expect(!keeps(kVK_ANSI_R, [.maskCommand, .maskShift, .maskAlternate]))
        #expect(!keeps(kVK_ANSI_D, .maskControl))
        #expect(!keeps(kVK_ANSI_R, []))
        // The fix shortcut and the Daisy key, and no other of Daisy's.
        #expect(HotkeyManager.layoutFixSlots == [.fixLayout, .voiceNote])
    }

    /// A character several keys type maps back to the main block's key,
    /// not the keypad's: on the Russian layout «,» is ⇧6 and the keypad's
    /// decimal key, and the latter is «.» in English.
    @Test func theKeypadIsTheLastPlaceACharacterMapsBackTo() {
        let keypadDecimal = KeyPress(keyCode: UInt16(kVK_ANSI_KeypadDecimal), shift: false)
        let shiftSix = KeyPress(keyCode: UInt16(kVK_ANSI_6), shift: true)
        let slash = KeyPress(keyCode: UInt16(kVK_ANSI_Slash), shift: false)
        let shiftSeven = KeyPress(keyCode: UInt16(kVK_ANSI_7), shift: true)
        let keypadPlus = KeyPress(keyCode: UInt16(kVK_ANSI_KeypadPlus), shift: false)
        let map = KeyboardLayout.reverseMap(of: [
            keypadDecimal: ",", shiftSix: ",",
            // Unshifted before shifted on the main block.
            slash: ".", shiftSeven: ".",
            // Only the keypad types it: the keypad it is.
            keypadPlus: "+",
        ])
        #expect(map[","] == shiftSix)
        #expect(map["."] == slash)
        #expect(map["+"] == keypadPlus)
    }

    /// A converted selection goes back on the second press as a word
    /// does: the field showing the conversion right before the caret.
    @Test @MainActor func aConvertedSelectionIsOfferedForUndo() {
        var record = LayoutFixUndo.Record(
            originalWord: "сайт про NHC",
            trailing: "",
            replacementWord: "cfqn ghj ТРС",
            bundleID: "com.apple.Notes",
            restoreLayoutID: "com.apple.keylayout.Russian",
            generation: 7,
            byKey: true,
            pasted: true,
            at: Date()
        )
        #expect(record.replacementText == "cfqn ghj ТРС" && record.originalText == "сайт про NHC")
        #expect(LayoutFixUndo.confirms(record, textBeforeCaret: "cfqn ghj ТРС", tapRunning: false, currentGeneration: 0, triggerKeystrokes: 1))
        // Still selected, or something else there: not an undo.
        #expect(!LayoutFixUndo.confirms(record, textBeforeCaret: "", tapRunning: true, currentGeneration: 7, triggerKeystrokes: 1))
        // An app that won't say: a paste may not have landed as it was
        // sent, so the tap's count of what was typed since isn't enough …
        #expect(!LayoutFixUndo.confirms(record, textBeforeCaret: nil, tapRunning: true, currentGeneration: 8, triggerKeystrokes: 1))
        // … as it is for a word typed back key by key.
        record.pasted = false
        #expect(LayoutFixUndo.confirms(record, textBeforeCaret: nil, tapRunning: true, currentGeneration: 8, triggerKeystrokes: 1))
        #expect(!LayoutFixUndo.confirms(record, textBeforeCaret: nil, tapRunning: true, currentGeneration: 9, triggerKeystrokes: 1))
    }
}
