//
//  LayoutFixLastWordTests.swift
//  DaisyTests
//
//  Egor 31.10: the layout fix on a key on its own (any shortcut can be a
//  lone modifier now, fired by a clean tap) and on the last word with
//  nothing selected, a second press putting it back. The monitors,
//  Accessibility and the posted keystrokes need a real keyboard and a
//  real field; what decides is pure and pinned here.
//

import AppKit
import Carbon.HIToolbox
import Testing
@testable import Daisy

// MARK: - A modifier on its own, tapped

@MainActor
struct ModifierTapTests {
    private static func flags(_ base: NSEvent.ModifierFlags, bits: UInt = 0) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: base.rawValue | bits)
    }
    private let leftOption = flags(.option, bits: ModifierChordReading.leftOptionBit)
    private let rightOption = flags(.option, bits: ModifierChordReading.rightOptionBit)
    private let bothOptions = flags(.option, bits: ModifierChordReading.leftOptionBit | ModifierChordReading.rightOptionBit)
    private let none: NSEvent.ModifierFlags = []

    /// Feeds raw flags for `choice` through the reading, as the monitor does.
    private struct Driver {
        var machine = ModifierTapMachine()
        let choice: HotkeyChoice
        mutating func flags(_ flags: NSEvent.ModifierFlags, at time: TimeInterval) -> ModifierTapMachine.Tap? {
            machine.flags(ModifierChordReading.read(flags, for: choice), at: time)
        }
        mutating func otherInput() { machine.otherInput() }
    }

    @Test func aCleanTapFires() {
        var d = Driver(choice: .leftOption)
        #expect(d.flags(leftOption, at: 10.0) == nil)
        #expect(d.flags(none, at: 10.1) == ModifierTapMachine.Tap(pressedAt: 10.0, releasedAt: 10.1))
    }

    @Test func onlyTheSideThatWasChosen() {
        var left = Driver(choice: .leftOption)
        _ = left.flags(rightOption, at: 1)
        #expect(left.flags(none, at: 1.1) == nil)
        var right = Driver(choice: .rightOption)
        _ = right.flags(rightOption, at: 2)
        #expect(right.flags(none, at: 2.1) != nil)
        _ = right.flags(leftOption, at: 3)
        #expect(right.flags(none, at: 3.1) == nil)
    }

    @Test func aLetterInBetweenIsATypedCharacterNotATap() {
        var d = Driver(choice: .leftOption)
        _ = d.flags(leftOption, at: 1)
        d.otherInput()   // ⌥E, ⌥-letter
        #expect(d.flags(none, at: 1.1) == nil)
        // And the next clean tap still works.
        _ = d.flags(leftOption, at: 2)
        #expect(d.flags(none, at: 2.1) != nil)
    }

    @Test func aClickOrScrollInBetweenIsNotATap() {
        var d = Driver(choice: .leftOption)
        _ = d.flags(leftOption, at: 1)
        d.otherInput()   // ⌥-click, ⌥-drag, ⌥-scroll
        #expect(d.flags(none, at: 1.2) == nil)
    }

    @Test func typingWithNoModifierDownDoesNothing() {
        var d = Driver(choice: .leftOption)
        d.otherInput()
        d.otherInput()
        _ = d.flags(leftOption, at: 5)
        #expect(d.flags(none, at: 5.1) != nil)
    }

    @Test func aLongHoldIsNotATap() {
        var d = Driver(choice: .leftOption)
        _ = d.flags(leftOption, at: 1)
        #expect(d.flags(none, at: 1 + ModifierTapMachine.maxHold + 0.05) == nil)
        // Right at the limit still counts.
        _ = d.flags(leftOption, at: 3)
        #expect(d.flags(none, at: 3 + ModifierTapMachine.maxHold) != nil)
    }

    /// The Daisy key on ⌃⌥: in either order, and let go in either order,
    /// it never reads as a tap of the left ⌥ — and doesn't leave the
    /// machine stuck.
    @Test func theDaisyKeyCtrlOptionIsNeverALoneOption() {
        let ctrlOption = Self.flags([.control, .option], bits: ModifierChordReading.leftOptionBit)
        let ctrl: NSEvent.ModifierFlags = [.control]
        var d = Driver(choice: .leftOption)

        #expect(d.flags(ctrl, at: 1.00) == nil)
        #expect(d.flags(ctrlOption, at: 1.02) == nil)
        #expect(d.flags(leftOption, at: 1.10) == nil)
        #expect(d.flags(none, at: 1.12) == nil)

        #expect(d.flags(leftOption, at: 2.00) == nil)
        #expect(d.flags(ctrlOption, at: 2.03) == nil)
        #expect(d.flags(ctrl, at: 2.10) == nil)
        #expect(d.flags(none, at: 2.12) == nil)

        #expect(d.flags(leftOption, at: 3.00) == nil)
        #expect(d.flags(ctrlOption, at: 3.03) == nil)
        #expect(d.flags(leftOption, at: 3.10) == nil)
        #expect(d.flags(none, at: 3.12) == nil)

        _ = d.flags(leftOption, at: 4)
        #expect(d.flags(none, at: 4.1) != nil)
    }

    @Test func otherChordsAreNotALoneOption() {
        var d = Driver(choice: .leftOption)
        _ = d.flags(leftOption, at: 1)
        _ = d.flags(Self.flags([.option, .command], bits: ModifierChordReading.leftOptionBit), at: 1.05)
        _ = d.flags(leftOption, at: 1.1)
        #expect(d.flags(none, at: 1.15) == nil)
        _ = d.flags([.shift], at: 2)
        _ = d.flags(Self.flags([.shift, .option], bits: ModifierChordReading.leftOptionBit), at: 2.05)
        _ = d.flags([.shift], at: 2.1)
        #expect(d.flags(none, at: 2.2) == nil)
        _ = d.flags(leftOption, at: 3)
        _ = d.flags(bothOptions, at: 3.05)
        _ = d.flags(leftOption, at: 3.1)
        #expect(d.flags(none, at: 3.15) == nil)
    }

    /// ⌃ held for ⌃C, then ⌥ pressed and let go: a chord, not a tap.
    @Test func aKeyBeforeTheChordCompletesSpoilsIt() {
        var d = Driver(choice: .ctrlOpt)
        _ = d.flags([.control], at: 1)
        d.otherInput()
        _ = d.flags([.control, .option], at: 1.1)
        _ = d.flags([.control], at: 1.15)
        #expect(d.flags(none, at: 1.2) == nil)
    }

    /// A chord of modifiers as a tap: complete, then let go — whichever
    /// key comes up first.
    @Test func aChordTapFiresOnce() {
        var d = Driver(choice: .ctrlOpt)
        _ = d.flags([.control], at: 1)
        _ = d.flags([.control, .option], at: 1.05)
        #expect(d.flags([.option], at: 1.2) == ModifierTapMachine.Tap(pressedAt: 1.05, releasedAt: 1.2))
        #expect(d.flags(none, at: 1.25) == nil)
    }

    @Test func capsLockDoesNotSpoilATap() {
        var d = Driver(choice: .leftOption)
        _ = d.flags(Self.flags([.option, .capsLock], bits: ModifierChordReading.leftOptionBit), at: 1)
        #expect(d.flags([.capsLock], at: 1.1) != nil)
    }

    @Test func theSameKeyReportedTwiceIsStillOnePress() {
        var d = Driver(choice: .leftOption)
        _ = d.flags(leftOption, at: 1)
        _ = d.flags(leftOption, at: 1.05)
        #expect(d.flags(none, at: 1.1) == ModifierTapMachine.Tap(pressedAt: 1, releasedAt: 1.1))
    }

    /// Every lone modifier reads by its own side bit.
    @Test func everyLoneModifierReadsItsOwnSide() {
        for key in LoneModifier.allCases {
            let choice = HotkeyChoice.lone(key)
            #expect(choice.loneModifier == key && choice.isModifierHold)
            let own = Self.flags(key.flag, bits: key.deviceBit)
            let other = Self.flags(key.flag, bits: key.otherSide.deviceBit)
            #expect(ModifierChordReading.read(own, for: choice) == .exact)
            // The other side's key is another key; the flag with no side
            // bits isn't known to be this one.
            #expect(ModifierChordReading.read(other, for: choice) == .extra)
            #expect(ModifierChordReading.read(key.flag, for: choice) == .partial)
            #expect(ModifierChordReading.read(Self.flags(key.flag, bits: key.deviceBit | key.otherSide.deviceBit), for: choice) == .extra)
        }
    }

    /// A key another app's hotkey swallowed (Raycast on ⌥Space) never
    /// reaches a monitor; the system's own «last key» time does.
    @Test func inputSwallowedOnlyBetweenPressAndRelease() {
        let tap = ModifierTapMachine.Tap(pressedAt: 100.0, releasedAt: 100.2)
        #expect(ModifierTapMachine.inputSwallowed(during: tap, secondsSinceLastInput: 0.15, now: 100.25))
        #expect(!ModifierTapMachine.inputSwallowed(during: tap, secondsSinceLastInput: 1.0, now: 100.25))
        #expect(!ModifierTapMachine.inputSwallowed(during: tap, secondsSinceLastInput: 0.01, now: 100.25))
    }

    /// And the Daisy key's own hold machine ignores a lone ⌥: it is part
    /// of ⌃⌥, never the chord itself.
    @Test func aLoneOptionIsNoDaisyKeyPress() {
        var daisy = ModifierHoldMachine()
        #expect(daisy.flags(ModifierChordReading.read(leftOption, for: .ctrlOpt)).isEmpty)
        #expect(daisy.flags(ModifierChordReading.read(none, for: .ctrlOpt)).isEmpty)
    }
}

// MARK: - The recorder takes a key on its own

@MainActor
struct HotkeyRecorderSingleKeyTests {
    @Test func oneModifierKeyIsThatKeyOnItsSide() {
        for key in LoneModifier.allCases {
            let flags = NSEvent.ModifierFlags(rawValue: key.flag.rawValue | key.deviceBit)
            #expect(HotkeyChoice.fromModifiers(flags) == .lone(key))
        }
        #expect(HotkeyChoice.fromModifiers(NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | ModifierChordReading.leftOptionBit)) == .leftOption)
        #expect(HotkeyChoice.leftOption.displayLabel == "Left ⌥")
    }

    @Test func severalModifiersAreTheChord() {
        let ctrlOpt = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags([.control, .option]).rawValue | 0x01 | ModifierChordReading.leftOptionBit)
        #expect(HotkeyChoice.fromModifiers(ctrlOpt) == .ctrlOpt)
        // Both ⌘ keys: the chord ⌘, either side.
        let bothCommands = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | ModifierChordReading.leftCommandBit | ModifierChordReading.rightCommandBit)
        let chord = HotkeyChoice.fromModifiers(bothCommands)
        #expect(chord?.keyCode == HotkeyChoice.modifiersOnlyKeyCode && chord?.label == "⌘")
    }

    @Test func fnAndNothingAreNotRecordedHere() {
        #expect(HotkeyChoice.fromModifiers([]) == nil)
        #expect(HotkeyChoice.fromModifiers([.function]) == nil)
        #expect(HotkeyChoice.fromModifiers([.capsLock]) == nil)
    }

    @Test func theRightKeysKeepTheirStoredLabels() {
        // Stored in prefs by label since 22.10 — must not change.
        #expect(HotkeyChoice.rightCommand.label == "Right ⌘")
        #expect(HotkeyChoice.rightOption.label == "Right ⌥")
        #expect(HotkeyChoice.layoutFixPresets.contains(.leftOption))
    }
}

// MARK: - Conflicts are warned about

@MainActor
struct HotkeyConflictTests {
    @Test func theSameKeysAreOneShortcutWhateverTheLabel() {
        let recorded = HotkeyChoice.fromKeyCode(UInt16(kVK_ANSI_R), modifierFlags: [.shift, .command])
        #expect(HotkeyWarnings.sameKeys(recorded, .shiftCmdR))
        #expect(!HotkeyWarnings.sameKeys(.leftOption, .rightOption))
        #expect(!HotkeyWarnings.sameKeys(.none, .none))
        let others: [(name: String, choice: HotkeyChoice)] = [("Dictation", .rightOption), ("Daisy key", .ctrlOpt)]
        #expect(HotkeyWarnings.owner(of: .rightOption, among: others) == "Dictation")
        #expect(HotkeyWarnings.owner(of: .leftOption, among: others) == nil)
        // A tap of ⌥ and the Daisy key's ⌃⌥ are different keys.
        #expect(HotkeyWarnings.owner(of: .ctrlOpt, among: others) == "Daisy key")
    }

    @Test func wellKnownShortcutsAreNamedAppOrSystem() {
        func use(_ key: Int, _ flags: NSEvent.ModifierFlags) -> (name: String, isSystem: Bool)? {
            HotkeyWarnings.systemUse(of: HotkeyChoice.fromKeyCode(UInt16(key), modifierFlags: flags))
        }
        #expect(use(kVK_ANSI_V, .command)?.isSystem == false)
        #expect(use(kVK_Space, .control)?.isSystem == true)
        #expect(use(kVK_ANSI_4, [.command, .shift])?.isSystem == true)
        #expect(use(kVK_ANSI_R, [.control, .option, .command]) == nil)
        #expect(HotkeyWarnings.systemUse(of: .fn) == nil)
        #expect(HotkeyWarnings.systemUse(of: .leftOption) == nil)
    }

    @Test func editingKeysAreWarnedAbout() {
        func choice(_ key: Int, _ flags: NSEvent.ModifierFlags = []) -> HotkeyChoice {
            HotkeyChoice.fromKeyCode(UInt16(key), modifierFlags: flags)
        }
        #expect(HotkeyWarnings.standing(for: choice(kVK_LeftArrow), on: .oneShot) == [.stopsEditing])
        #expect(HotkeyWarnings.standing(for: choice(kVK_RightArrow, [.shift, .option]), on: .daisyKey) == [.stopsEditing])
        #expect(HotkeyWarnings.standing(for: choice(kVK_Delete, .command), on: .oneShot) == [.stopsEditing])
        #expect(HotkeyWarnings.standing(for: choice(kVK_LeftArrow), on: .dictation) == [.alsoStartsDictation])
        // ⌃→ is macOS's own (Spaces), named as such instead.
        #expect(HotkeyWarnings.standing(for: choice(kVK_RightArrow, .control), on: .oneShot)
            == [.systemKeeps(String(localized: "Switch desktops"))])
        #expect(!HotkeyWarnings.editsText(.ctrlOptCmdR))
    }

    /// A tap costs the Mac nothing; a hold of a key people hold on the
    /// way to something else opens the microphone. The right ⌘ / ⌥
    /// presets and Fn are the keys chosen for not being held that way.
    @Test func heldModifiersThatOpenTheMicrophoneAreWarnedAbout() {
        #expect(HotkeyWarnings.standing(for: .leftOption, on: .oneShot).isEmpty)
        #expect(HotkeyWarnings.standing(for: .lone(.leftShift), on: .dictation) == [.holdOpensMicrophone])
        #expect(HotkeyWarnings.standing(for: .lone(.leftCommand), on: .daisyKey) == [.holdOpensMicrophone])
        #expect(HotkeyWarnings.standing(for: .lone(.rightControl), on: .dictation) == [.holdOpensMicrophone])
        #expect(HotkeyWarnings.standing(for: .rightCommand, on: .daisyKey).isEmpty)
        #expect(HotkeyWarnings.standing(for: .rightOption, on: .dictation).isEmpty)
        #expect(HotkeyWarnings.standing(for: .fn, on: .dictation).isEmpty)
        #expect(HotkeyWarnings.standing(for: .ctrlOpt, on: .daisyKey).isEmpty)
        // A recorded chord is held on the way to shortcuts just the same.
        let shiftCommand = HotkeyChoice.fromModifiers(NSEvent.ModifierFlags([.shift, .command]))!
        #expect(HotkeyWarnings.standing(for: shiftCommand, on: .dictation) == [.holdOpensMicrophone])
        #expect(HotkeyWarnings.standing(for: shiftCommand, on: .oneShot).isEmpty)
        // Fn tapped on a one-shot row: macOS acts on the tap too.
        #expect(HotkeyWarnings.standing(for: .fn, on: .oneShot) == [.fnDoesItsOwnToo])
    }

    /// The layout watcher's tap tells Daisy's own shortcut on a typing
    /// key from typing by this key: ⇧ is the only modifier it can carry
    /// there (chords never reach that check).
    @Test func carbonKeysPackKeyAndModifiers() {
        let r = HotkeyManager.carbonKey(keyCode: UInt32(kVK_ANSI_R), mods: 0)
        let shiftR = HotkeyManager.carbonKey(keyCode: UInt32(kVK_ANSI_R), mods: UInt32(shiftKey))
        let t = HotkeyManager.carbonKey(keyCode: UInt32(kVK_ANSI_T), mods: 0)
        #expect(Set([r, shiftR, t]).count == 3)
    }

    @Test func warningsSayWhatTheyMean() {
        #expect(HotkeyWarning.takenFrom("Dictation").text.contains("Dictation"))
        #expect(HotkeyWarning.appShortcutStops("Copy").text.contains("Copy"))
        #expect(HotkeyWarning.systemKeeps("Spotlight").text.contains("Spotlight"))
        #expect(HotkeyWarning.alsoDoes("Copy").text.contains("Copy"))
        for warning in [HotkeyWarning.stopsTyping, .stopsEditing, .alsoStartsDictation, .holdOpensMicrophone, .fnDoesItsOwnToo] {
            #expect(!warning.text.isEmpty)
        }
    }
}

// MARK: - The last word

@MainActor
struct LayoutFixLastWordTests {
    private func pick(_ text: String, start: Bool = true) -> LayoutFixLastWord.Pick? {
        LayoutFixLastWord.pick(before: text, reachesFieldStart: start)
    }

    @Test func theWordRightBeforeTheCaret() {
        #expect(pick("ghbdtn") == .init(word: "ghbdtn", trailing: ""))
        #expect(pick("rfr ltkf") == .init(word: "ltkf", trailing: ""))
        #expect(pick("Hello, ghbdtn") == .init(word: "ghbdtn", trailing: ""))
    }

    @Test func spacesAfterItAreKeptInOrder() {
        #expect(pick("ghbdtn ") == .init(word: "ghbdtn", trailing: " "))
        #expect(pick("rfr ltkf  ") == .init(word: "ltkf", trailing: "  "))
        #expect(pick("ghbdtn\u{00A0} ") == .init(word: "ghbdtn", trailing: "\u{00A0} "))
        #expect(pick("ghbdtn ")?.presses == 7)
    }

    /// On the wrong layout ж, б, ю, х, э are typed with ; , . [ ' — the
    /// whole run since the last space is the word.
    @Test func punctuationKeysArePartOfTheWord() {
        #expect(pick("lf;t") == .init(word: "lf;t", trailing: ""))
        #expect(pick("[jhjij") == .init(word: "[jhjij", trailing: ""))
        #expect(pick("ltkf? ") == .init(word: "ltkf?", trailing: " "))
    }

    @Test func noWordInFrontOfTheCaret() {
        #expect(pick("") == nil)
        #expect(pick("   ") == nil)
        // A caret at the start of a new line has no last word.
        #expect(pick("ghbdtn\n") == nil)
        #expect(pick("ghbdtn\n ") == nil)
        #expect(pick("ghbdtn\t") == nil)
        // Nothing a letter in it.
        #expect(pick("2026") == nil)
        #expect(pick("—") == nil)
    }

    @Test func aWordWhoseStartIsOutsideTheWindowIsRefused() {
        #expect(pick("dtn", start: false) == nil)
        #expect(pick("ghbdtn", start: true) != nil)
        #expect(pick("x ghbdtn", start: false) == .init(word: "ghbdtn", trailing: ""))
    }

    @Test func onlyCharactersOneBackspaceRemovesWhole() {
        // A combining mark: one Character, two scalars.
        #expect(pick("ftq" + "и\u{0306}") == nil)
        // An attachment in a rich-text field.
        #expect(pick("ab\u{FFFC}cd") == nil)
        // A surrogate cut in half by the read window.
        #expect(pick("\u{FFFD}bc", start: true) == nil)
    }

    @Test func tooLongToBeAWord() {
        let long = String(repeating: "f", count: LayoutFixLastWord.maxPresses + 1)
        #expect(pick(long) == nil)
        let fits = String(repeating: "f", count: LayoutFixLastWord.maxPresses - 1)
        #expect(pick(fits + " ") != nil)
        #expect(pick(fits + "  ") == nil)
    }

    @Test func aSingleLetterIsAWord() {
        // «d» → «в», «z» → «я»: one-letter Russian words are common.
        #expect(pick("d") == .init(word: "d", trailing: ""))
    }
}

// MARK: - Pressing again undoes

@MainActor
struct LayoutFixRepeatUndoTests {
    private func keyRecord(generation: UInt64? = nil, trailing: String = " ") -> LayoutFixUndo.Record {
        LayoutFixUndo.Record(
            originalWord: "ghbdtn",
            trailing: trailing,
            replacementWord: "привет",
            bundleID: "com.apple.Notes",
            restoreLayoutID: "com.apple.keylayout.US",
            generation: generation,
            byKey: true,
            at: Date()
        )
    }

    @Test func theRecordDescribesWhatIsOnScreenAndWhatComesBack() {
        let record = keyRecord()
        #expect(record.replacementText == "привет ")
        #expect(record.originalText == "ghbdtn ")
        #expect(keyRecord(trailing: "").replacementText == "привет")
    }

    @Test func theFieldShowingTheFixIsAnUndo() {
        #expect(LayoutFixUndo.confirms(keyRecord(), textBeforeCaret: "привет ", tapRunning: false, currentGeneration: 0, triggerKeystrokes: 1))
    }

    @Test func theFieldShowingSomethingElseVetoesEvenWithAQuietCounter() {
        #expect(!LayoutFixUndo.confirms(keyRecord(generation: 5), textBeforeCaret: "привет д", tapRunning: true, currentGeneration: 5, triggerKeystrokes: 1))
    }

    @Test func aSilentFieldNeedsTheTapsCounter() {
        // The tap counted all along and nothing was typed: undo.
        #expect(LayoutFixUndo.confirms(keyRecord(generation: 5), textBeforeCaret: nil, tapRunning: true, currentGeneration: 5, triggerKeystrokes: 1))
        #expect(LayoutFixUndo.confirms(keyRecord(generation: 5), textBeforeCaret: nil, tapRunning: true, currentGeneration: 6, triggerKeystrokes: 1))
        // Typing since.
        #expect(!LayoutFixUndo.confirms(keyRecord(generation: 5), textBeforeCaret: nil, tapRunning: true, currentGeneration: 7, triggerKeystrokes: 1))
        // Fixed with the watcher off: nobody counted.
        #expect(!LayoutFixUndo.confirms(keyRecord(generation: nil), textBeforeCaret: nil, tapRunning: true, currentGeneration: 0, triggerKeystrokes: 1))
        // Watcher off now.
        #expect(!LayoutFixUndo.confirms(keyRecord(generation: 5), textBeforeCaret: nil, tapRunning: false, currentGeneration: 5, triggerKeystrokes: 1))
    }

    /// A modifier on its own never reaches the tap as a keystroke, so
    /// nothing is forgiven: one letter typed after the fix vetoes it
    /// (review 31.10 — «привет d» + a tap of ⌥ ate the «d» and more).
    @Test func aModifierTriggerForgivesNoKeystroke() {
        #expect(LayoutFixUndo.confirms(keyRecord(generation: 5), textBeforeCaret: nil, tapRunning: true, currentGeneration: 5, triggerKeystrokes: 0))
        #expect(!LayoutFixUndo.confirms(keyRecord(generation: 5), textBeforeCaret: nil, tapRunning: true, currentGeneration: 6, triggerKeystrokes: 0))
        #expect(!LayoutFixUndo.generationAllowsUndo(recorded: 5, current: 6, triggerKeystrokes: 0))
    }

    /// An emptied field (the message went with Return) is a definite
    /// answer — "" — and vetoes, where silence would have let the
    /// counter decide.
    @Test func anEmptyFieldVetoes() {
        #expect(!LayoutFixUndo.confirms(keyRecord(generation: 5), textBeforeCaret: "", tapRunning: true, currentGeneration: 5, triggerKeystrokes: 1))
    }

    /// When the tap saw the word typed, the field must show it right
    /// before the caret — with what ended it — or the screen isn't used
    /// (editors that report per block or a keystroke late).
    @Test func theFieldMustAgreeWithTheTypedWord() {
        let pick = LayoutFixLastWord.Pick(word: "lf;t", trailing: "")
        // «t» in flight after «;» ended «lf» for the tap.
        #expect(LayoutFixLastWord.agrees(pick, withTyped: "t", boundary: nil))
        #expect(!LayoutFixLastWord.agrees(pick, withTyped: "te", boundary: nil))
        let spaced = LayoutFixLastWord.Pick(word: "ghbdtn", trailing: " ")
        #expect(LayoutFixLastWord.agrees(spaced, withTyped: "ghbdtn", boundary: " "))
        #expect(!LayoutFixLastWord.agrees(spaced, withTyped: "ghbdtn", boundary: nil))
        // The field lags a keystroke: it shows «ghbdt», the tap saw «ghbdtn».
        #expect(!LayoutFixLastWord.agrees(.init(word: "ghbdt", trailing: ""), withTyped: "ghbdtn", boundary: nil))
        // Smart quotes aside.
        #expect(LayoutFixLastWord.agrees(.init(word: "\u{2018}nj", trailing: ""), withTyped: "'nj", boundary: nil))
        // A web editor's no-break space after the word, and a native one
        // capitalising the first word of a sentence: the same word.
        #expect(LayoutFixLastWord.agrees(.init(word: "ghbdtn", trailing: "\u{00A0}"), withTyped: "ghbdtn", boundary: " "))
        #expect(LayoutFixLastWord.agrees(.init(word: "Ghbdtn", trailing: " "), withTyped: "ghbdtn", boundary: " "))
        // Two spaces where the tap saw one: refused, the safe way.
        #expect(!LayoutFixLastWord.agrees(.init(word: "ghbdtn", trailing: "  "), withTyped: "ghbdtn", boundary: " "))
    }

    @Test func smartQuotesAreStraightenedOneForOne() {
        #expect(LayoutFixLastWord.straighteningQuotes("\u{2018}nj") == "'nj")
        #expect(LayoutFixLastWord.straighteningQuotes("\u{201C}ok\u{201D}") == "\"ok\"")
        #expect(LayoutFixLastWord.straighteningQuotes("\u{2019}nj").count == 3)
    }

    @Test func aKeyFixIsOfferedForUndoLikeAnAutomaticOne() {
        let store = LayoutFixUndo.shared
        store.record(keyRecord())
        defer { store.clear() }
        #expect(store.fresh(bundleID: "com.apple.Notes")?.byKey == true)
        #expect(store.fresh(bundleID: "com.apple.Safari") == nil)
    }
}
