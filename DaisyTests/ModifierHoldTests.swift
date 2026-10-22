//
//  ModifierHoldTests.swift
//  DaisyTests
//
//  The Daisy key on held modifiers (Egor 22.10): ⌃⌥ or the right ⌘ on
//  their own, and the shortcuts that only pass through them.
//

import AppKit
import Testing
@testable import Daisy

@MainActor
struct ModifierHoldTests {
    private let right = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | ModifierChordReading.rightCommandBit)
    private let left = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | ModifierChordReading.leftCommandBit)

    @Test func readingCtrlOption() {
        let choice = HotkeyChoice.ctrlOpt
        #expect(ModifierChordReading.read([], for: choice) == .none)
        #expect(ModifierChordReading.read([.control], for: choice) == .partial)
        #expect(ModifierChordReading.read([.control, .option], for: choice) == .exact)
        #expect(ModifierChordReading.read([.control, .option, .command], for: choice) == .extra)
        #expect(ModifierChordReading.read([.control, .option, .shift], for: choice) == .extra)
        #expect(ModifierChordReading.read([.shift], for: choice) == .extra)
        // Caps Lock is not a modifier of the chord.
        #expect(ModifierChordReading.read([.control, .option, .capsLock], for: choice) == .exact)
    }

    @Test func readingTheRightCommand() {
        let choice = HotkeyChoice.rightCommand
        #expect(ModifierChordReading.read(right, for: choice) == .exact)
        #expect(ModifierChordReading.read(left, for: choice) == .extra)
        #expect(ModifierChordReading.read(right.union(left), for: choice) == .extra)
        #expect(ModifierChordReading.read(right.union(.option), for: choice) == .extra)
        #expect(ModifierChordReading.read([], for: choice) == .none)
    }

    @Test func aHoldPressesOnceArmedAndReleases() {
        var m = ModifierHoldMachine()
        #expect(m.flags(.partial) == [])
        #expect(m.flags(.exact) == [.scheduleArm(1)])
        #expect(m.armElapsed(1) == [.press])
        #expect(m.flags(.partial) == [.release])
        #expect(m.flags(.none) == [])
    }

    @Test func aQuickTapIsPressAndReleaseAtOnce() {
        var m = ModifierHoldMachine()
        _ = m.flags(.exact)
        #expect(m.flags(.none) == [.press, .release])
        // The arm that was scheduled finds nothing to press.
        #expect(m.armElapsed(1) == [])
    }

    @Test func daisysOwnShortcutsThroughCtrlOptionDontPress() {
        // ⌃⌥⌘R typed quickly: ⌘ joins before the arm.
        var m = ModifierHoldMachine()
        _ = m.flags(.partial)
        _ = m.flags(.exact)
        #expect(m.flags(.extra) == [])
        #expect(m.armElapsed(1) == [])
        _ = m.keyDown()
        // Letting go of ⌘ first leaves ⌃⌥ — still nothing.
        #expect(m.flags(.exact) == [])
        #expect(m.flags(.partial) == [])
        #expect(m.flags(.none) == [])
        // And the next clean ⌃⌥ works.
        #expect(m.flags(.exact) == [.scheduleArm(2)])
        #expect(m.armElapsed(2) == [.press])
    }

    @Test func aKeyJoiningAPressCancelsIt() {
        // ⌃⌥ held a beat, then an arrow for the window manager.
        var m = ModifierHoldMachine()
        _ = m.flags(.exact)
        _ = m.armElapsed(1)
        #expect(m.keyDown() == [.cancel])
        #expect(m.flags(.none) == [])
        // A modifier joining is a cancel too.
        _ = m.flags(.exact)
        _ = m.armElapsed(2)
        #expect(m.flags(.extra) == [.cancel])
    }

    @Test func aKeyBeforeTheArmMeansNoPress() {
        var m = ModifierHoldMachine()
        _ = m.flags(.exact)
        #expect(m.keyDown() == [])
        #expect(m.armElapsed(1) == [])
        #expect(m.flags(.none) == [])
    }

    @Test func aModifierHeldForAnotherShortcutSpoilsTheChord() {
        // ⌃ for ⌃C, then ⌥ added while still down.
        var m = ModifierHoldMachine()
        _ = m.flags(.partial)
        _ = m.keyDown()
        #expect(m.flags(.exact) == [])
        #expect(m.flags(.none) == [])
    }

    @Test func presetsAndDefault() {
        #expect(HotkeyChoice.daisyKeyPresets == [.none, .ctrlOpt, .rightCommand, .ctrlOptD, .ctrlShiftD])
        // The D pairs are ordinary keys, held through the key monitor.
        #expect(!HotkeyChoice.ctrlOptD.isModifierHold && !HotkeyChoice.ctrlShiftD.isModifierHold)
        #expect(HotkeyChoice.fromKeyCode(2, modifierFlags: [.control, .shift]) == .ctrlShiftD)
        #expect(HotkeyChoice.fromKeyCode(2, modifierFlags: [.control, .option]) == .ctrlOptD)
        #expect(HotkeyChoice.ctrlOpt.isModifierHold && HotkeyChoice.rightCommand.isModifierHold)
        #expect(!HotkeyChoice.ctrlOptCmdD.isModifierHold && !HotkeyChoice.fn.isModifierHold && !HotkeyChoice.none.isModifierHold)
        #expect(HotkeyChoice.ctrlOpt.isPreset && HotkeyChoice.rightCommand.isPreset)
        // A stored choice comes back as the same preset.
        let data = try? JSONEncoder().encode(HotkeyChoice.rightCommand)
        #expect(data.flatMap { try? JSONDecoder().decode(HotkeyChoice.self, from: $0) } == .rightCommand)
    }
}
