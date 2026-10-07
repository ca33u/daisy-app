//
//  KeyboardLayout.swift
//  Daisy
//
//  Layout conversion for the "I typed this in the wrong layout" fixer:
//  «ghbdtn» → «привет», «руддщ» → «hello».
//
//  The conversion works in KEY PRESS space, not character space. For
//  each character we ask "which physical key, with or without shift,
//  produces this on the layout it was typed with", then ask the other
//  layout what THAT key press produces. Two consequences worth the
//  indirection:
//
//   1. It works for every pair of layouts the user actually has, not
//      just ЙЦУКЕН↔QWERTY. Ukrainian, the PC variant of the Russian
//      layout, Hebrew, Dvorak — a hard-coded table would be wrong for
//      each of them in a different way, and our users are multilingual
//      by definition.
//   2. Shift comes along for free, so case survives: «Ghbdtn» is
//      «Привет», not «привет».
//
//  The tables come from the layout's own `uchr` data via
//  `UCKeyTranslate` — the same data the system uses to draw Keyboard
//  Viewer, so a layout Daisy has never heard of still converts
//  correctly.
//

import AppKit
import Carbon.HIToolbox
import os

/// One physical key press: virtual key code plus shift. The unit of
/// conversion — see this file's header for why this and not characters.
nonisolated struct KeyPress: Hashable, Sendable {
    let keyCode: UInt16
    let shift: Bool
}

/// An installed keyboard layout with both directions of its key map.
nonisolated struct KeyboardLayout: Identifiable, Sendable {
    /// Input-source id, e.g. `com.apple.keylayout.Russian`.
    let id: String
    let name: String
    /// Primary language of the layout ("ru", "en", "he"), used to ask
    /// the system spell checker whether a candidate is a real word.
    /// Nil for layouts that don't declare one.
    let language: String?
    let charByPress: [KeyPress: Character]
    let pressByChar: [Character: KeyPress]

    /// Every letter of `text` sits on this layout's keys — the text could
    /// have been typed on it. Punctuation doesn't count: on US the keys
    /// of «, . ; '» are «б ю ж э» on Russian, so Cyrillic with a comma
    /// still "converts" out of US, and only letters say where it was
    /// typed.
    func typesAllLetters(of text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        return !letters.isEmpty && letters.allSatisfy { pressByChar[$0] != nil }
    }

    /// This text as it WOULD have come out had `other` been active.
    ///
    /// Returns nil when nothing would change — same layout, or every
    /// character sits on the same key in both (digits, most
    /// punctuation). Deliberately NOT a "how different is it" ratio:
    /// US↔UK and QWERTY↔QWERTZ differ by a handful of keys, and a ratio
    /// would refuse to fix exactly those pairs.
    func converting(_ text: String, to other: KeyboardLayout) -> String? {
        guard id != other.id, !text.isEmpty else { return nil }
        var out = String()
        out.reserveCapacity(text.count)
        var changed = 0
        for character in text {
            if character.isWhitespace || character.isNumber {
                out.append(character)
                continue
            }
            if let press = pressByChar[character],
               let replacement = other.charByPress[press] {
                out.append(replacement)
                if replacement != character { changed += 1 }
            } else {
                // Not typeable on this layout (or not on the other one) —
                // pass it through rather than dropping it.
                out.append(character)
            }
        }
        guard changed > 0 else { return nil }
        return out
    }
}

/// The layouts this Mac has enabled, with their key maps built once and
/// cached. Rebuilt when the user adds or removes one — macOS posts a
/// distributed notification for that, and a stale table would silently
/// convert into a layout that is no longer there.
@MainActor
final class KeyboardLayouts {
    static let shared = KeyboardLayouts()

    private var cached: [KeyboardLayout]?
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "KeyboardLayout")

    private init() {
        // The ENABLED-set notification is the one that matters — a
        // layout added or removed in System Settings. The selection
        // notification is observed too because it is the reliable one,
        // and re-reading costs a few milliseconds once.
        for case let name? in [
            kTISNotifyEnabledKeyboardInputSourcesChanged,
            kTISNotifySelectedKeyboardInputSourceChanged,
        ] {
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(name as String),
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in KeyboardLayouts.shared.invalidate() }
            }
        }
    }

    /// Every enabled keyboard LAYOUT (input methods — Japanese, Pinyin —
    /// are excluded: they have no `uchr` table and no fixed key mapping
    /// to convert through).
    var installed: [KeyboardLayout] {
        if let cached { return cached }
        let built = Self.buildAll()
        cached = built
        log.info("Keyboard layouts: \(built.count, privacy: .public) usable")
        return built
    }

    /// The layout currently typing. `TISCopyCurrentKeyboardLayoutInputSource`
    /// (not `…KeyboardInputSource`) so an active input method still
    /// reports the ASCII layout underneath it.
    var current: KeyboardLayout? {
        guard let unmanaged = TISCopyCurrentKeyboardLayoutInputSource() else { return nil }
        let source = unmanaged.takeRetainedValue()
        guard let id = Self.string(source, kTISPropertyInputSourceID) else { return nil }
        return installed.first { $0.id == id }
    }

    /// Whether an input METHOD (Japanese, Pinyin, Hangul) is composing
    /// rather than a plain layout typing. Their keystrokes don't map to
    /// the characters that land, so anything built on "what key produced
    /// this" has to stand down. Detected by the current input source
    /// differing from the ASCII layout underneath it.
    var isInputMethodActive: Bool {
        guard let selected = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return false }
        return Self.string(selected, kTISPropertyInputSourceID) != Self.string(layout, kTISPropertyInputSourceID)
    }

    /// Make `layout` the active one — so the next word the user types
    /// lands in the layout they meant, instead of needing a second fix.
    func select(_ layout: KeyboardLayout) {
        for source in Self.enabledSources() where Self.string(source, kTISPropertyInputSourceID) == layout.id {
            TISSelectInputSource(source)
            return
        }
    }

    func invalidate() { cached = nil }

    // MARK: - Building

    private static func buildAll() -> [KeyboardLayout] {
        // A closure, not an unapplied `layout(from:)`: the method is
        // MainActor-isolated by default in this target, and passing that
        // function value where a plain one is expected loses isolation.
        enabledSources().compactMap { layout(from: $0) }
    }

    private static func enabledSources() -> [TISInputSource] {
        // Filter by TYPE, not category: the category includes input
        // methods and input modes, which have no key table to convert
        // through. `includeAllInstalled: false` leaves only the ones the
        // user has actually enabled.
        let filter = [
            kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String
        ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false) else { return [] }
        return (list.takeRetainedValue() as NSArray) as? [TISInputSource] ?? []
    }

    private static func layout(from source: TISInputSource) -> KeyboardLayout? {
        guard boolean(source, kTISPropertyInputSourceIsEnabled),
              let id = string(source, kTISPropertyInputSourceID),
              let data = layoutData(source) else { return nil }

        var charByPress: [KeyPress: Character] = [:]
        var pressByChar: [Character: KeyPress] = [:]
        // Unshifted first, so a character that can be typed both ways
        // maps back to the simpler press.
        for shift in [false, true] {
            for keyCode in UInt16(0)...UInt16(127) {
                guard let character = character(keyCode: keyCode, shift: shift, layoutData: data) else { continue }
                let press = KeyPress(keyCode: keyCode, shift: shift)
                charByPress[press] = character
                if pressByChar[character] == nil { pressByChar[character] = press }
            }
        }
        guard charByPress.count > 20 else { return nil }   // not a real text layout

        return KeyboardLayout(
            id: id,
            name: string(source, kTISPropertyLocalizedName) ?? id,
            language: languages(source).first,
            charByPress: charByPress,
            pressByChar: pressByChar
        )
    }

    /// What one key press produces on one layout, straight out of the
    /// layout's own `uchr` table. Dead keys are resolved to the
    /// character they display rather than left pending — a fixer that
    /// half-composed an umlaut would be worse than no fixer.
    private static func character(keyCode: UInt16, shift: Bool, layoutData: Data) -> Character? {
        var deadKeyState: UInt32 = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        var length = 0
        let modifiers = UInt32(shift ? (shiftKey >> 8) : 0)
        let status: OSStatus = layoutData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return OSStatus(-50) }
            return UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                keyCode,
                UInt16(kUCKeyActionDisplay),
                modifiers,
                UInt32(LMGetKbdType()),
                // Mask, not Bit: `kUCKeyTranslateNoDeadKeysBit` is a bit
                // INDEX and happens to be 0, so passing it means "no
                // options" and dead keys stay live — every dead key on
                // German / French / US-International would then report no
                // character and drop out of the table.
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                buffer.count,
                &length,
                &buffer
            )
        }
        guard status == noErr, length == 1 else { return nil }
        // Printable only: control characters, tabs and the like are not
        // things anyone "typed in the wrong layout".
        guard buffer[0] >= 0x20, buffer[0] != 0x7F,
              let scalar = Unicode.Scalar(buffer[0]) else { return nil }
        // With dead keys resolved, some layouts hand back a bare
        // combining mark. It can never match a grapheme from real text,
        // so it would only pollute the reverse map.
        guard !scalar.properties.isDefaultIgnorableCodePoint,
              scalar.properties.generalCategory != .nonspacingMark,
              scalar.properties.generalCategory != .spacingMark,
              scalar.properties.generalCategory != .enclosingMark else { return nil }
        let character = Character(scalar)
        guard !character.isWhitespace else { return nil }
        return character
    }

    // MARK: - TIS property helpers

    private static func string(_ source: TISInputSource, _ key: CFString!) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func boolean(_ source: TISInputSource, _ key: CFString!) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }

    private static func languages(_ source: TISInputSource) -> [String] {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
        let array = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue()
        return ((array as NSArray) as? [String]) ?? []
    }

    private static func layoutData(_ source: TISInputSource) -> Data? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }
}
