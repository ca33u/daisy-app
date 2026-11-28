// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  KeyboardLayoutTests.swift
//  DaisyTests
//
//  Regression locks for the layout fixer's one pure, testable core:
//  `KeyboardLayout.converting(_:to:)`. Everything above it needs a real
//  keyboard, a real pasteboard or a real focused text field; this
//  function is characters in, characters out, and it is where both bugs
//  found in review actually live.
//
//  WHAT IS DELIBERATELY NOT HERE, so nobody reads green as covered:
//  building layouts from a live `uchr` table (needs the machine's
//  installed layouts), `LayoutFix.judge` (needs the system spell
//  checker and whichever dictionaries the user has), the ⌘C/⌘V round
//  trip, and the event tap. Those are the device-QA list, not unit tests.
//

import Testing
import Foundation
@testable import Daisy

@Suite("Keyboard layout conversion")
struct KeyboardLayoutTests {

    // MARK: - Fixtures

    /// A layout over synthetic key codes 1…n. Real key codes don't matter
    /// to `converting` — only that both layouts agree on which key is
    /// which, which is exactly what the uchr tables give us on device.
    private func layout(
        id: String,
        language: String?,
        unshifted: String,
        shifted: String
    ) -> KeyboardLayout {
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
        return KeyboardLayout(
            id: id,
            name: id,
            language: language,
            charByPress: charByPress,
            pressByChar: pressByChar
        )
    }

    /// Enough of QWERTY and ЙЦУКЕН to type "ghbdtn" / "привет" — the
    /// canonical case, and the one every Russian-speaking Mac user has
    /// typed by accident.
    private var qwerty: KeyboardLayout {
        layout(id: "test.QWERTY", language: "en", unshifted: "ghbdtn", shifted: "GHBDTN")
    }

    private var russian: KeyboardLayout {
        layout(id: "test.Russian", language: "ru", unshifted: "привет", shifted: "ПРИВЕТ")
    }

    // MARK: - The happy path

    @Test("Latin typed on QWERTY reads as the Cyrillic it should have been")
    func convertsWord() {
        #expect(qwerty.converting("ghbdtn", to: russian) == "привет")
    }

    @Test("Converting back is the same operation in reverse")
    func convertsBothWays() {
        #expect(russian.converting("привет", to: qwerty) == "ghbdtn")
    }

    @Test("Case survives, because the key press carries shift")
    func keepsCase() {
        #expect(qwerty.converting("Ghbdtn", to: russian) == "Привет")
        #expect(qwerty.converting("GHBDTN", to: russian) == "ПРИВЕТ")
    }

    // MARK: - Whitespace (the selection bug, at the layer it lives in)

    // Selecting a word WITH its trailing space and getting the word back
    // without it glues the next word on. Found in review of the manual
    // fix path; the pasteboard half of that fix can't be unit-tested, so
    // this locks the half that can.

    @Test("A trailing space stays a trailing space")
    func keepsTrailingSpace() {
        #expect(qwerty.converting("ghbdtn ", to: russian) == "привет ")
    }

    @Test("Leading and inner whitespace survive untouched")
    func keepsSurroundingWhitespace() {
        #expect(qwerty.converting("  ghbdtn  ", to: russian) == "  привет  ")
        #expect(qwerty.converting("ghbdtn ghbdtn", to: russian) == "привет привет")
    }

    @Test("Newlines and tabs survive, so a multi-line selection stays multi-line")
    func keepsNewlines() {
        #expect(qwerty.converting("ghbdtn\nghbdtn", to: russian) == "привет\nпривет")
        #expect(qwerty.converting("ghbdtn\n", to: russian) == "привет\n")
        #expect(qwerty.converting("ghbdtn\tghbdtn", to: russian) == "привет\tпривет")
    }

    // MARK: - Refusals

    @Test("Nothing to convert into itself")
    func refusesSameLayout() {
        #expect(qwerty.converting("ghbdtn", to: qwerty) == nil)
    }

    @Test("Empty text converts to nothing")
    func refusesEmpty() {
        #expect(qwerty.converting("", to: russian) == nil)
    }

    @Test("Text whose characters sit on the same keys in both layouts is left alone")
    func refusesWhenNothingWouldChange() {
        // Digits and whitespace only: no character maps to a different
        // one, so reporting a "fix" would be reporting a no-op.
        #expect(qwerty.converting("1234", to: russian) == nil)
        #expect(qwerty.converting("   ", to: russian) == nil)
    }

    @Test("Characters neither layout can type pass through instead of vanishing")
    func passesThroughUnknownCharacters() {
        // "ж" is on no key of either fixture. The mapped letters still
        // convert; the stranger is preserved, not dropped.
        #expect(qwerty.converting("ghbdtnж", to: russian) == "приветж")
    }

    @Test("Digits ride along with a real conversion")
    func keepsDigitsAlongsideLetters() {
        #expect(qwerty.converting("ghbdtn42", to: russian) == "привет42")
    }
}

@Suite("Screenshot frame ordering")
struct ScreenshotFileTests {

    private func urls(_ names: [String]) -> [URL] {
        let base = URL(fileURLWithPath: "/tmp/daisy-test/screenshots", isDirectory: true)
        return names.map { base.appendingPathComponent($0) }
    }

    private func names(_ result: [URL]) -> [String] {
        result.map(\.lastPathComponent)
    }

    @Test("Frames order by number, not by name")
    func ordersNumerically() {
        // "1000.jpg" sorts before "999.jpg" lexically, which put a long
        // session's tail at its head — every frame then paired with
        // someone else's timecode.
        let ordered = ScreenshotFile.ordered(urls(["1000.jpg", "999.jpg", "1001.jpg"]))
        #expect(names(ordered) == ["999.jpg", "1000.jpg", "1001.jpg"])
    }

    @Test("A session that started as PNG and resumed as JPEG stays in order")
    func ordersMixedFormats() {
        let ordered = ScreenshotFile.ordered(urls(["008.jpg", "007.png", "009.jpg"]))
        #expect(names(ordered) == ["007.png", "008.jpg", "009.jpg"])
    }

    @Test("Only files named as just their number count as frames")
    func rejectsStrangers() {
        // What comes back from a round trip through an Obsidian vault or
        // a network share.
        let ordered = ScreenshotFile.ordered(urls([
            "001.jpg", "001 copy.jpg", "._001.jpg", "index.json",
            "highlights.json", "thumbnail.jpg", "002.jpg",
        ]))
        #expect(names(ordered) == ["001.jpg", "002.jpg"])
    }

    @Test("Sidecars and unknown image types are not frames")
    func rejectsNonFrames() {
        #expect(ScreenshotFile.isFrame(urls(["001.jpg"])[0]))
        #expect(ScreenshotFile.isFrame(urls(["001.png"])[0]))
        #expect(!ScreenshotFile.isFrame(urls(["001.heic"])[0]))
        #expect(!ScreenshotFile.isFrame(urls(["index.json"])[0]))
    }

    @Test("New frames are named as zero-padded JPEGs")
    func namesNewFrames() {
        #expect(ScreenshotFile.name(number: 1) == "001.jpg")
        #expect(ScreenshotFile.name(number: 42) == "042.jpg")
        // Past three digits the padding stops — which is why ordering is
        // numeric rather than lexical.
        #expect(ScreenshotFile.name(number: 1000) == "1000.jpg")
    }
}
