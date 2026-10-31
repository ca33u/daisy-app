//
//  HotkeyManager.swift
//  Daisy
//
//  Global hotkey for start / stop recording. Uses Carbon's
//  `RegisterEventHotKey` — modern Swift has no first-party replacement,
//  and Carbon hotkeys work without requiring Accessibility / Input
//  Monitoring permissions (unlike `CGEventTap` / `NSEvent` global
//  monitors). The trade-off is a small amount of `@convention(c)`
//  glue to bridge the system callback back into Swift.
//
//  Usage:
//      HotkeyManager.shared.register(choice: .ctrlOptCmdR) {
//          Task { await session.toggleByHotkey() }
//      }
//
//  Call `unregister()` to disable. Calling `register` again replaces
//  any previous registration.
//

import AppKit
import Carbon.HIToolbox
import Foundation
import os

// MARK: - HotkeyChoice (struct, supports presets + custom)

/// A keyboard shortcut. Used to be a fixed enum of presets; now a
/// struct so users can record any combination via Settings →
/// HotkeyRecorder.
///
/// `keyCode == nil` means "disabled" (no global shortcut registered).
struct HotkeyChoice: Hashable, Codable, Sendable, Identifiable {
    /// Carbon virtual keycode (`kVK_*` from `HIToolbox.Events`).
    /// `nil` for `.none` (disabled).
    let keyCode: UInt32?
    /// Carbon modifier flags bitmask. `0` is legal (e.g. F-keys).
    let modifiers: UInt32?
    /// Human-readable string like "⌃⌥⌘R" — used as picker label and
    /// `id`. For custom combos this is computed from keyCode + mods.
    let label: String

    var id: String { label }

    // MARK: Presets

    static let none = HotkeyChoice(keyCode: nil, modifiers: nil, label: "Disabled")
    static let ctrlOptCmdR = HotkeyChoice(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        label: "⌃⌥⌘R"
    )
    static let ctrlOptCmdD = HotkeyChoice(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        label: "⌃⌥⌘D"
    )
    static let ctrlOptSpace = HotkeyChoice(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey),
        label: "⌃⌥Space"
    )
    static let shiftCmdR = HotkeyChoice(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(shiftKey | cmdKey),
        label: "⇧⌘R"
    )
    // V-presets for the paste-flavoured action (re-paste last
    // dictation). V is the paste mnemonic users already know from
    // ⌘V / Wispr Flow; R and D read as "record"/"dictate" and are
    // wrong hints for this row. ⇧⌘V is deliberately absent — many
    // apps bind it to "Paste and Match Style".
    static let ctrlOptCmdV = HotkeyChoice(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        label: "⌃⌥⌘V"
    )
    static let ctrlOptV = HotkeyChoice(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(controlKey | optionKey),
        label: "⌃⌥V"
    )
    /// «Mark this moment» default on a fresh install (backlog 34 K-4).
    static let ctrlOptCmdM = HotkeyChoice(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        label: "⌃⌥⌘M"
    )
    static let f5 = HotkeyChoice(
        keyCode: UInt32(kVK_F5),
        modifiers: 0,
        label: "F5"
    )
    /// Fn / globe key. Bare, no modifiers. Carbon
    /// RegisterEventHotKey can't bind this — Fn is a modifier flag,
    /// not a regular key event — so `HotkeyManager` routes it
    /// through `NSEvent.addGlobalMonitorForEvents(.flagsChanged)`
    /// instead, which requires Input Monitoring permission. macOS
    /// will prompt the first time the user binds Fn.
    ///
    /// Label is plain "Fn" — UI layers render the SF Symbol
    /// `globe` icon next to it (see `isFnOnly` consumers in
    /// SettingsView + HotkeyRecorder).
    static let fn = HotkeyChoice(
        keyCode: UInt32(kVK_Function),
        modifiers: 0,
        label: "Fn"
    )

    /// Modifiers held on their own, no letter — the Daisy key's presets
    /// (Egor 22.10: «вариант Ctrl Option»). Carbon can't bind these and
    /// nothing reaches the front app, so `HotkeyManager` watches
    /// `.flagsChanged` and lets a press through only once the chord has
    /// stood alone for a beat — ⌃⌥⌘R, ⌃⌥⌘M and ⌃⌥-arrows all start
    /// with ⌃⌥ (see `ModifierHoldMachine`).
    nonisolated static let modifiersOnlyKeyCode: UInt32 = 0xFFFF
    static let ctrlOpt = HotkeyChoice(
        keyCode: modifiersOnlyKeyCode,
        modifiers: UInt32(controlKey | optionKey),
        label: "⌃⌥"
    )
    /// One modifier key on its own, this side only (Egor 31.10: «не будем
    /// ограничивать пользователей по хоткеям»). Held, it is a hold — the
    /// Daisy key, dictation; on a shortcut that acts once, a clean tap
    /// fires it (see `ModifierTapMachine`).
    nonisolated static func lone(_ key: LoneModifier) -> HotkeyChoice {
        HotkeyChoice(keyCode: key.keyCode, modifiers: 0, label: key.label)
    }
    /// The right ⌘ alone; the left one goes on working as ⌘. Apple
    /// keyboards all have it, unlike a right ⌃.
    static let rightCommand = lone(.rightCommand)
    /// The right ⌥ alone, like the right ⌘ — a dictation key in the
    /// tour's picker (Egor 23.10).
    static let rightOption = lone(.rightOption)
    /// The left ⌥ alone — a tap of it fixes the keyboard layout, the
    /// lone-⇧ habit of Punto and Caramba (Egor 31.10: «исправление
    /// раскладки одной клавишей Option»).
    static let leftOption = lone(.leftOption)
    /// ⌃Space held — the tour's fourth dictation key.
    static let ctrlSpace = HotkeyChoice(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey),
        label: "⌃Space"
    )

    /// The dictation keys the first-run tour offers (Egor 23.10): fn,
    /// the right ⌘, the right ⌥, ⌃Space. Anything else is a recording
    /// away in Settings.
    static let dictationPresets: [HotkeyChoice] = [.fn, .rightCommand, .rightOption, .ctrlSpace]

    /// Preset list shown in Settings picker. Custom recorder lives
    /// alongside — see `HotkeyRecorder` view.
    static let allPresets: [HotkeyChoice] = [.none, .ctrlOptCmdR, .ctrlOptCmdD, .ctrlOptCmdM, .ctrlOptSpace, .shiftCmdR, .f5, .fn]

    /// D for Daisy with two modifiers: no macOS shortcut uses either
    /// (⌃D deletes forward, ⌥D types a letter, ⌥⌘D hides the Dock, ⌃⌘D
    /// looks a word up, ⇧⌘D is taken by Finder and Mail — research 22.10).
    static let ctrlOptD = HotkeyChoice(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(controlKey | optionKey),
        label: "⌃⌥D"
    )
    static let ctrlShiftD = HotkeyChoice(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(controlKey | shiftKey),
        label: "⌃⇧D"
    )

    /// The Daisy key's row (Egor 22.10): held modifiers first, then the
    /// D pairs. Anything else is still a recording away.
    static let daisyKeyPresets: [HotkeyChoice] = [.none, .ctrlOpt, .rightCommand, .ctrlOptD, .ctrlShiftD]

    /// Modifiers with no key — routed through the flags monitor: a hold
    /// for the Daisy key and dictation, a tap for the rest.
    nonisolated var isModifierHold: Bool {
        (keyCode == Self.modifiersOnlyKeyCode && (modifiers ?? 0) != 0)
            || loneModifier != nil
    }

    /// The one modifier key this choice is, when it is one on its own.
    nonisolated var loneModifier: LoneModifier? {
        guard (modifiers ?? 0) == 0, let keyCode else { return nil }
        return LoneModifier(keyCode: keyCode)
    }

    /// What the UI shows. `label` is also the stored id, so a word in it
    /// stays English there and is translated here.
    var displayLabel: String {
        if let loneModifier { return loneModifier.displayLabel }
        return label
    }

    nonisolated var isRightCommand: Bool { loneModifier == .rightCommand }

    nonisolated var isRightOption: Bool { loneModifier == .rightOption }

    /// Paste-flavoured preset list — used by the "Paste my last
    /// dictation" row instead of `allPresets`.
    static let pastePresets: [HotkeyChoice] = [.none, .ctrlOptCmdV, .ctrlOptV, .fn]

    /// True when this choice is the bare Fn / globe key — handled
    /// by the NSEvent global-monitor path, not Carbon. Read by
    /// `HotkeyManager.register` to pick the right registration
    /// strategy.
    nonisolated var isFnOnly: Bool {
        keyCode == UInt32(kVK_Function) && (modifiers ?? 0) == 0
    }

    /// Fn alone may not fix the layout: in macOS the 🌐/Fn key itself
    /// switches the keyboard layout, so every switch re-typed whatever
    /// was selected. A user got it by pressing 🌐 while onboarding's key
    /// recorder was listening (log report 07.10.2026).
    nonisolated static func allowedForLayoutFix(_ choice: HotkeyChoice) -> Bool { !choice.isFnOnly }

    /// …and either ⌥ on its own, tapped (Egor 31.10).
    static var layoutFixPresets: [HotkeyChoice] { allPresets.filter(allowedForLayoutFix) + [.leftOption, .rightOption] }

    /// Whether this choice is one of the canonical presets above.
    /// UI uses this to mark presets in the menu (vs custom recordings).
    var isPreset: Bool {
        Self.allPresets.contains(self) || Self.pastePresets.contains(self) || Self.daisyKeyPresets.contains(self)
            || Self.dictationPresets.contains(self) || Self.layoutFixPresets.contains(self)
    }

    // MARK: Custom recording

    /// Build a HotkeyChoice from an NSEvent.keyDown event.
    static func fromNSEvent(_ event: NSEvent) -> HotkeyChoice {
        fromKeyCode(event.keyCode, modifierFlags: event.modifierFlags)
    }

    /// Same shape as `fromNSEvent` but takes raw keyCode + flags so
    /// callers can override the modifier source. Used by
    /// HotkeyRecorder which tracks modifiers via `.flagsChanged`
    /// separately — on some macOS / keyboard combos the keyDown
    /// event's `modifierFlags` arrive empty even when the user is
    /// holding ⌘/⌃/⌥.
    ///
    /// Any key, with or without modifiers (Egor 31.10: «хотят одну —
    /// пускай ставят, просто можно предупреждать»). Until then a bare key
    /// or ⌘ without ⌃/⌥ was refused: Carbon registers ⌘C happily and
    /// then eats Copy everywhere — one did get recorded as "rewrite in my
    /// voice" in testing. Now Settings says so under the recorder
    /// (`HotkeyWarnings`) and lets the person decide.
    static func fromKeyCode(_ keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> HotkeyChoice {
        let carbonKey = UInt32(keyCode)
        let carbonMods = nsToCarbonModifiers(modifierFlags)
        let label = humanLabel(keyCode: carbonKey, modifiers: carbonMods)
        return HotkeyChoice(keyCode: carbonKey, modifiers: carbonMods, label: label)
    }

    /// Modifiers pressed and let go with no key — what the recorder saw
    /// at the most held down (device bits included). One modifier key is
    /// that key, this side (`lone`); several are the chord, either side,
    /// like the Daisy key's ⌃⌥. Nil for Fn (recorded on its own path)
    /// or nothing.
    nonisolated static func fromModifiers(_ flags: NSEvent.ModifierFlags) -> HotkeyChoice? {
        let down = flags.intersection([.control, .option, .shift, .command])
        guard !flags.contains(.function), !down.isEmpty else { return nil }
        let raw = flags.rawValue
        let keys = LoneModifier.allCases.filter { raw & $0.deviceBit != 0 }
        if keys.count == 1, keys[0].flag == down { return lone(keys[0]) }
        let carbonMods = nsToCarbonModifiers(down)
        return HotkeyChoice(
            keyCode: modifiersOnlyKeyCode,
            modifiers: carbonMods,
            label: humanLabel(keyCode: modifiersOnlyKeyCode, modifiers: carbonMods)
        )
    }

    /// A key that types something when pressed with no modifier but ⇧ —
    /// as a shortcut it fires while someone types. Function keys, Fn,
    /// modifier keys and navigation keys don't type.
    nonisolated var typesText: Bool {
        guard let keyCode, keyCode != Self.modifiersOnlyKeyCode, loneModifier == nil, !isFnOnly else { return false }
        let mods = modifiers ?? 0
        guard mods & ~UInt32(shiftKey) == 0 else { return false }
        return !Self.functionKeyCodes.contains(keyCode) && !Self.nonTypingKeyCodes.contains(keyCode)
    }

    nonisolated private static let nonTypingKeyCodes: Set<UInt32> = [
        UInt32(kVK_Escape), UInt32(kVK_LeftArrow), UInt32(kVK_RightArrow), UInt32(kVK_UpArrow),
        UInt32(kVK_DownArrow), UInt32(kVK_Home), UInt32(kVK_End), UInt32(kVK_PageUp),
        UInt32(kVK_PageDown), UInt32(kVK_Help), UInt32(kVK_CapsLock),
        UInt32(kVK_Delete), UInt32(kVK_ForwardDelete),
    ]

    /// kVK_F1 … kVK_F20 — virtual keycodes for the function row.
    /// Allowed as bare hotkeys because nobody types them as
    /// ordinary characters, so binding e.g. F5 as Daisy's toggle
    /// won't hijack normal typing the way bare "K" would.
    nonisolated private static let functionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F1),  UInt32(kVK_F2),  UInt32(kVK_F3),  UInt32(kVK_F4),
        UInt32(kVK_F5),  UInt32(kVK_F6),  UInt32(kVK_F7),  UInt32(kVK_F8),
        UInt32(kVK_F9),  UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20),
    ]

    /// NSEvent.ModifierFlags → Carbon modifier bitmask.
    nonisolated private static func nsToCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command)  { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift)    { carbon |= UInt32(shiftKey) }
        if flags.contains(.option)   { carbon |= UInt32(optionKey) }
        if flags.contains(.control)  { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// Compose a "⌃⌥⌘R"-style display label from key + modifiers.
    /// Internal because HotkeyManager's NSEvent hold-monitor path
    /// uses it to compose the permission-prompt toast label.
    nonisolated static func humanLabel(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += keyName(for: keyCode)
        return s
    }

    /// Map a Carbon keyCode to its on-screen glyph. Falls back to
    /// `<keyCode>` for keys we haven't mapped.
    nonisolated private static func keyName(for code: UInt32) -> String {
        if let key = LoneModifier(keyCode: code) { return key.label }
        // Punctuation + named keys
        switch Int(code) {
        case kVK_Space:     return "Space"
        case kVK_Return:    return "⏎"
        case kVK_Tab:       return "⇥"
        case kVK_Escape:    return "⎋"
        case kVK_Delete:    return "⌫"
        case kVK_F1:        return "F1"
        case kVK_F2:        return "F2"
        case kVK_F3:        return "F3"
        case kVK_F4:        return "F4"
        case kVK_F5:        return "F5"
        case kVK_F6:        return "F6"
        case kVK_F7:        return "F7"
        case kVK_F8:        return "F8"
        case kVK_F9:        return "F9"
        case kVK_F10:       return "F10"
        case kVK_F11:       return "F11"
        case kVK_F12:       return "F12"
        case kVK_Function:  return "Fn"
        case Int(modifiersOnlyKeyCode): return ""
        case kVK_LeftArrow:  return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow:    return "↑"
        case kVK_DownArrow:  return "↓"
        default: break
        }
        // ANSI letters/digits
        let ansiMap: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
            kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
            kVK_ANSI_Grave: "`",
        ]
        return ansiMap[Int(code)] ?? "<\(code)>"
    }
}

// MARK: - One modifier key

/// A modifier key on its own, by side — what a lone-modifier shortcut is
/// bound to. The device bits are IOLLEvent.h's NX_DEVICE*KEYMASK, which
/// AppKit passes through in `NSEvent.ModifierFlags.rawValue`.
nonisolated enum LoneModifier: CaseIterable, Sendable {
    case leftControl, rightControl, leftShift, rightShift, leftOption, rightOption, leftCommand, rightCommand

    init?(keyCode: UInt32) {
        guard let key = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = key
    }

    var keyCode: UInt32 {
        switch self {
        case .leftControl: UInt32(kVK_Control)
        case .rightControl: UInt32(kVK_RightControl)
        case .leftShift: UInt32(kVK_Shift)
        case .rightShift: UInt32(kVK_RightShift)
        case .leftOption: UInt32(kVK_Option)
        case .rightOption: UInt32(kVK_RightOption)
        case .leftCommand: UInt32(kVK_Command)
        case .rightCommand: UInt32(kVK_RightCommand)
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .leftControl, .rightControl: .control
        case .leftShift, .rightShift: .shift
        case .leftOption, .rightOption: .option
        case .leftCommand, .rightCommand: .command
        }
    }

    var deviceBit: UInt {
        switch self {
        case .leftControl: 0x01
        case .rightControl: 0x2000
        case .leftShift: 0x02
        case .rightShift: 0x04
        case .leftOption: ModifierChordReading.leftOptionBit
        case .rightOption: ModifierChordReading.rightOptionBit
        case .leftCommand: ModifierChordReading.leftCommandBit
        case .rightCommand: ModifierChordReading.rightCommandBit
        }
    }

    /// The same modifier on the other side of the keyboard.
    var otherSide: LoneModifier {
        switch self {
        case .leftControl: .rightControl
        case .rightControl: .leftControl
        case .leftShift: .rightShift
        case .rightShift: .leftShift
        case .leftOption: .rightOption
        case .rightOption: .leftOption
        case .leftCommand: .rightCommand
        case .rightCommand: .leftCommand
        }
    }

    var glyph: String {
        switch self {
        case .leftControl, .rightControl: "⌃"
        case .leftShift, .rightShift: "⇧"
        case .leftOption, .rightOption: "⌥"
        case .leftCommand, .rightCommand: "⌘"
        }
    }

    var isRight: Bool {
        switch self {
        case .rightControl, .rightShift, .rightOption, .rightCommand: true
        default: false
        }
    }

    /// The stored label (English, it is also the choice's id).
    var label: String { (isRight ? "Right " : "Left ") + glyph }

    var displayLabel: String {
        switch self {
        case .leftControl: String(localized: "Left ⌃")
        case .rightControl: String(localized: "Right ⌃")
        case .leftShift: String(localized: "Left ⇧")
        case .rightShift: String(localized: "Right ⇧")
        case .leftOption: String(localized: "Left ⌥")
        case .rightOption: String(localized: "Right ⌥")
        case .leftCommand: String(localized: "Left ⌘")
        case .rightCommand: String(localized: "Right ⌘")
        }
    }

    /// Under the keycap in What's New.
    var capName: String {
        switch self {
        case .leftControl: String(localized: "left control")
        case .rightControl: String(localized: "right control")
        case .leftShift: String(localized: "left shift")
        case .rightShift: String(localized: "right shift")
        case .leftOption: String(localized: "left option")
        case .rightOption: String(localized: "right option")
        case .leftCommand: String(localized: "left command")
        case .rightCommand: String(localized: "right command")
        }
    }
}

// MARK: - Manager

/// One of the three recording modes Daisy supports a hotkey for.
/// The rawValue doubles as the Carbon `EventHotKeyID.id` so the C
/// callback can disambiguate which slot fired without a lookup
/// table. Keep raw values stable — they're the wire format between
/// the kernel-side event tap and our action map.
nonisolated enum HotkeySlot: UInt32, CaseIterable, Sendable {
    case record    = 1   // mode = .meeting
    case voiceNote = 2   // mode = .voiceNote
    case dictation = 3   // mode = .dictation
    case rewrite   = 4   // rewrite selection in the user's voice
    case fixLayout = 5   // re-type text in the keyboard layout it belonged to
    case markMoment = 6  // "this bit matters" during a recording
    case repasteLast = 7 // paste the most recent dictation (last hour) at the caret
    case noteOnly  = 8   // the old voice-note toggle, without the Daisy key's hold
}

/// How the slot's hotkey reacts to a key press:
///
///   - `.toggle` — single fire on press. Carbon `RegisterEventHotKey`
///     handles this and requires NO permission. Meeting recorder uses
///     this — recording a 60-minute call by holding a key down would
///     be cruel.
///
///   - `.hold` — fires `onPress` on key-down edge and `onRelease`
///     on key-up edge. Push-to-talk semantics, the natural fit for
///     dictation and quick voice notes. Carbon doesn't deliver
///     key-up events, so we use `NSEvent.addGlobalMonitorForEvents`
///     instead — which requires Input Monitoring permission. macOS
///     prompts on first use.
///
/// The mode is chosen by the call site (`ServiceWiring`), not by
/// the user's choice of key — meeting can be Fn (toggle), voice
/// note can be ⌃⌥V (hold). They're orthogonal.
nonisolated enum HotkeyAction: Sendable {
    case toggle(@MainActor @Sendable () -> Void)
    /// `onCancel` is for held modifiers only: another key or modifier
    /// joined the hold, so it was the start of some other shortcut.
    /// Without one, a cancel is an ordinary release.
    case hold(
        onPress: @MainActor @Sendable () -> Void,
        onRelease: @MainActor @Sendable () -> Void,
        onCancel: (@MainActor @Sendable () -> Void)? = nil
    )
}

// MARK: - Held modifiers

/// What the modifiers down right now are, against a held-modifier
/// choice (`HotkeyChoice.isModifierHold`).
nonisolated enum ModifierChordReading: Equatable, Sendable {
    /// Exactly the chord.
    case exact
    /// Something the chord doesn't have is down too — another modifier,
    /// or the left ⌘ beside the right one.
    case extra
    /// Part of the chord, nothing else.
    case partial
    /// No modifier at all.
    case none

    /// The device-dependent bits of the two ⌘ keys (IOLLEvent.h
    /// NX_DEVICELCMDKEYMASK / NX_DEVICERCMDKEYMASK).
    static let leftCommandBit: UInt = 0x08
    static let rightCommandBit: UInt = 0x10
    /// NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK.
    static let leftOptionBit: UInt = 0x20
    static let rightOptionBit: UInt = 0x40

    static func read(_ flags: NSEvent.ModifierFlags, for choice: HotkeyChoice) -> ModifierChordReading {
        let watched: NSEvent.ModifierFlags = [.control, .option, .shift, .command, .function]
        let down = flags.intersection(watched)
        if down.isEmpty { return .none }
        if let key = choice.loneModifier {
            let raw = flags.rawValue
            // That key alone — but an old event source may set the flag
            // without side bits; that isn't known to be this key.
            if down != key.flag { return .extra }
            if raw & key.otherSide.deviceBit != 0 { return .extra }
            return raw & key.deviceBit != 0 ? .exact : .partial
        }
        var chord: NSEvent.ModifierFlags = []
        let mods = choice.modifiers ?? 0
        if mods & UInt32(controlKey) != 0 { chord.insert(.control) }
        if mods & UInt32(optionKey) != 0 { chord.insert(.option) }
        if mods & UInt32(shiftKey) != 0 { chord.insert(.shift) }
        if mods & UInt32(cmdKey) != 0 { chord.insert(.command) }
        if !down.subtracting(chord).isEmpty { return .extra }
        return down == chord ? .exact : .partial
    }
}

/// Press, release and cancel for held modifiers, out of `.flagsChanged`
/// and key-down events. Pure — the manager feeds it and runs the timer.
///
/// The chord has to stand alone for `armDelay` before it's a press:
/// Daisy's own ⌃⌥⌘R and ⌃⌥⌘M, and window managers' ⌃⌥-arrows, all go
/// through ⌃⌥ on the way. Let go sooner and it was a tap (press and
/// release at once). Once pressed, a key or another modifier joining is
/// a cancel. After anything extra, nothing fires until every modifier
/// is up — letting go of ⌘ out of ⌃⌥⌘ must not leave a ⌃⌥ press.
nonisolated struct ModifierHoldMachine: Sendable {
    static let armDelay: TimeInterval = 0.12

    enum Output: Equatable, Sendable {
        case press, release, cancel
        /// Call `armElapsed(generation)` after `armDelay`.
        case scheduleArm(Int)
    }

    private enum State: Equatable {
        case idle
        case arming(Int)
        case held
        /// Waiting for every modifier to be up.
        case spoiled
    }

    private var state: State = .idle
    private var generation = 0
    /// Whether any modifier was down at the last flags event.
    private var anyDown = false

    mutating func flags(_ reading: ModifierChordReading) -> [Output] {
        anyDown = reading != .none
        switch state {
        case .idle:
            switch reading {
            case .exact:
                generation += 1
                state = .arming(generation)
                return [.scheduleArm(generation)]
            case .extra:
                state = .spoiled
            case .partial, .none:
                break
            }
        case .arming:
            switch reading {
            case .exact:
                break
            case .extra:
                state = .spoiled
            case .partial, .none:
                state = .idle
                return [.press, .release]
            }
        case .held:
            switch reading {
            case .exact:
                break
            case .extra:
                state = .spoiled
                return [.cancel]
            case .partial, .none:
                state = .idle
                return [.release]
            }
        case .spoiled:
            if reading == .none { state = .idle }
        }
        return []
    }

    mutating func keyDown() -> [Output] {
        switch state {
        case .idle:
            // ⌃ held for ⌃C, then ⌥ added: not a Daisy press.
            if anyDown { state = .spoiled }
        case .arming:
            state = .spoiled
        case .held:
            state = .spoiled
            return [.cancel]
        case .spoiled:
            break
        }
        return []
    }

    mutating func armElapsed(_ generation: Int) -> [Output] {
        guard state == .arming(generation) else { return [] }
        state = .held
        return [.press]
    }
}

/// A modifier-only shortcut that acts once (record, mark a moment, fix
/// the layout…) fires on a clean TAP, the lone-⇧ habit of Punto and
/// Caramba: the chord down and up again with nothing else — no other
/// modifier, key, click or scroll in between, and briefly. ⌥ is a typing
/// key (⌥-letters), a click modifier and half of the Daisy key's ⌃⌥;
/// none of those is a tap. Modifiers don't autorepeat, so a second tap
/// is a second press. Pure — the manager feeds it.
nonisolated struct ModifierTapMachine: Sendable {
    /// Longer than this and it wasn't a tap but the start of something
    /// that didn't happen, or a look at the ⌥-items of a menu.
    static let maxHold: TimeInterval = 0.4

    /// When the chord stood complete and when it was let go, on the
    /// events' clock (system uptime).
    struct Tap: Equatable, Sendable {
        let pressedAt: TimeInterval
        let releasedAt: TimeInterval
    }

    private enum State: Equatable {
        case idle
        case down(at: TimeInterval)
        /// Something else happened; nothing fires until every modifier
        /// is up.
        case spoiled
    }

    private var state: State = .idle
    private var anyDown = false

    /// The flags changed. Returns the tap when the chord was just let go.
    mutating func flags(_ reading: ModifierChordReading, at time: TimeInterval) -> Tap? {
        anyDown = reading != .none
        switch state {
        case .idle:
            switch reading {
            case .exact: state = .down(at: time)
            case .extra: state = .spoiled
            case .partial, .none: break
            }
        case .down(let pressedAt):
            switch reading {
            case .exact:
                break
            case .extra:
                state = .spoiled
            case .partial, .none:
                // Let go — the rest of a chord may still be on its way up.
                state = reading == .none ? .idle : .spoiled
                guard time >= pressedAt, time - pressedAt <= Self.maxHold else { return nil }
                return Tap(pressedAt: pressedAt, releasedAt: time)
            }
        case .spoiled:
            if reading == .none { state = .idle }
        }
        return nil
    }

    /// A key, a click or a scroll — or another of Daisy's shortcuts.
    /// Typing with no modifier down is just typing; with one down it is
    /// a chord (⌥E, ⌃C then ⌥).
    mutating func otherInput() {
        switch state {
        case .down: state = .spoiled
        case .idle: if anyDown { state = .spoiled }
        case .spoiled: break
        }
    }

    /// Whether the system saw a key or a click between press and release
    /// that the monitors didn't — one another app's hotkey swallowed
    /// (Raycast on ⌥Space). The latest such input happened
    /// `secondsSinceLastInput` before `now`. Strictly between the two: a
    /// key typed right after the release is the next thing someone does.
    static func inputSwallowed(during tap: Tap, secondsSinceLastInput: TimeInterval, now: TimeInterval) -> Bool {
        let lastInputAt = now - secondsSinceLastInput
        return lastInputAt > tap.pressedAt && lastInputAt < tap.releasedAt
    }
}

/// The machine behind a lock — the monitors' closures are `@Sendable`.
nonisolated private final class ModifierHoldBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<ModifierHoldMachine>(initialState: ModifierHoldMachine())
    /// When the chord last stood alone — the start of the arm — on the
    /// events' own clock (system uptime), not when Daisy got round to
    /// them: a fast ⌃⌥Space's Space would otherwise land «before» the arm
    /// and not count (review 22.10).
    private let since = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)
    /// The latest `.flagsChanged` event's timestamp.
    private let lastFlags = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)
    func run(_ step: @Sendable (inout ModifierHoldMachine) -> [ModifierHoldMachine.Output]) -> [ModifierHoldMachine.Output] {
        lock.withLock { step(&$0) }
    }
    var armedAt: TimeInterval? {
        get { since.withLock { $0 } }
        set { since.withLock { $0 = newValue } }
    }
    var lastFlagsAt: TimeInterval {
        get { lastFlags.withLock { $0 } }
        set { lastFlags.withLock { $0 = newValue } }
    }
}

/// Thread-safe per-slot storage of the currently-registered action.
/// The Carbon `@convention(c)` callback and the NSEvent global
/// monitors all read from this map outside MainActor. Actions
/// inside the action enum are pre-typed `@MainActor` so the only
/// legal invocation site is a hop back to the main actor.
nonisolated private final class HotkeyActionMap: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[HotkeySlot: HotkeyAction]>(initialState: [:])

    func set(slot: HotkeySlot, action: HotkeyAction?) {
        lock.withLock { state in
            if let action {
                state[slot] = action
            } else {
                state.removeValue(forKey: slot)
            }
        }
    }

    func get(slot: HotkeySlot) -> HotkeyAction? {
        lock.withLock { $0[slot] }
    }
}

/// Mutable bool for press-state tracking inside event-monitor
/// closures. Closures capture `var` immutably, so we hide the
/// flip-flop state inside a thread-safe reference instead.
nonisolated private final class HoldPressState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Set `next` and return the *previous* value — used to detect
    /// rising / falling edges without an extra check.
    func swap(_ next: Bool) -> Bool {
        lock.withLock { prev in
            let was = prev
            prev = next
            return was
        }
    }
}

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// EventHotKeyRef per slot — kept so we can `UnregisterEventHotKey`
    /// individually when a single hotkey is re-bound without tearing
    /// the other two down.
    private var refs: [HotkeySlot: EventHotKeyRef] = [:]
    /// What each Carbon slot is registered as — kept through a pause.
    private var carbonCombos: [HotkeySlot: (keyCode: UInt32, mods: UInt32)] = [:]
    /// The shortcut recorder is listening: Carbon hotkeys are
    /// unregistered so their keys reach it (`setCarbonPaused`).
    private var carbonPaused = false

    /// Daisy's Carbon combinations (key code << 16 | Carbon modifiers),
    /// for the layout watcher's tap: a shortcut on a key that types (a
    /// bare letter, `, Space) reaches the tap as typing, and must count
    /// as the command it is — see `LayoutAutoFix.handle`.
    nonisolated static let carbonKeys = OSAllocatedUnfairLock<Set<UInt32>>(initialState: [])

    nonisolated static func carbonKey(keyCode: UInt32, mods: UInt32) -> UInt32 {
        (keyCode << 16) | (mods & 0xFFFF)
    }

    /// NSEvent global monitors per slot — used when the bound choice
    /// is `.fn` (or any other case `.isFnOnly` matches). Stored
    /// alongside refs/actionMap so unregister can tear the right
    /// path down.
    private var fnMonitors: [HotkeySlot: Any] = [:]
    /// The same hold monitors for events sent to Daisy itself: a global
    /// monitor never sees keys pressed while Daisy is the front app, and
    /// a hold key that does nothing over Daisy's own window reads as
    /// broken (backlog 34 review — the Carbon voice-note key worked there).
    private var localMonitors: [HotkeySlot: Any] = [:]

    /// One shared event handler for all 3 slots — installed lazily
    /// on first `register(...)`, reused thereafter, torn down only
    /// when all 3 slots are unregistered.
    private var eventHandler: EventHandlerRef?

    /// `nonisolated` so the C callback can reach it via the manager
    /// pointer without crossing MainActor isolation. The map itself
    /// is thread-safe; actions are `@MainActor`-typed so they can
    /// only run after a MainActor hop.
    nonisolated fileprivate let actionMap = HotkeyActionMap()

    /// Per held-modifier slot: what to do when another Daisy shortcut
    /// fires mid-chord. ⌃⌥Space (rewrite) or ⌃⌥V (paste last) go through
    /// the Daisy key's ⌃⌥, and their Carbon hotkey swallows the Space or
    /// V before any monitor sees it — the press then read as a tap and
    /// started a long note as well (Egor 22.10). Daisy knows its own
    /// shortcut fired, so it says so.
    nonisolated private let modifierInterrupts = OSAllocatedUnfairLock<[HotkeySlot: @Sendable () -> Void]>(initialState: [:])
    /// When each of Daisy's shortcuts last fired (system uptime) — for a
    /// hold whose interrupt came before its own ⌃⌥ was seen: the Carbon
    /// event and the flags reach the run loop by different routes. Per
    /// slot, so the Daisy key's own press can't overwrite ⌃⌥Space's.
    nonisolated private let lastHotkeyFire = OSAllocatedUnfairLock<[HotkeySlot: TimeInterval]>(initialState: [:])

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Hotkey")

    private init() {}

    /// Register or replace the hotkey for `slot`. Passing a `.none`
    /// choice unregisters the slot. Other slots keep their existing
    /// bindings.
    ///
    /// `action` picks the registration strategy:
    ///   - `.toggle` + non-Fn → Carbon RegisterEventHotKey, zero
    ///     permission, single-fire-on-press.
    ///   - `.toggle` + Fn → NSEvent .flagsChanged monitor (Fn alone
    ///     isn't a Carbon-bindable key), Input Monitoring required.
    ///   - `.hold` + anything → NSEvent global monitor (.keyDown +
    ///     .keyUp for regular keys, .flagsChanged for Fn). Input
    ///     Monitoring required, push-to-talk semantics.
    func register(slot: HotkeySlot, choice: HotkeyChoice, action: HotkeyAction) {
        unregister(slot: slot)
        guard let keyCode = choice.keyCode, let mods = choice.modifiers else { return }
        actionMap.set(slot: slot, action: action)

        switch action {
        case .toggle:
            if choice.isFnOnly {
                installFnFlagsMonitor(slot: slot, isHold: false)
            } else if choice.isModifierHold {
                installModifierTapMonitor(slot: slot, choice: choice)
            } else {
                installCarbonToggle(slot: slot, keyCode: keyCode, mods: mods)
            }
        case .hold:
            if choice.isFnOnly {
                installFnFlagsMonitor(slot: slot, isHold: true)
            } else if choice.isModifierHold {
                installModifierHoldMonitor(slot: slot, choice: choice, isHold: true)
            } else if slot == .voiceNote {
                installCarbonHold(slot: slot, keyCode: keyCode, mods: mods)
            } else {
                installKeyHoldMonitor(slot: slot, keyCode: keyCode, mods: mods)
            }
        }
    }

    /// Backward-compatible single-slot API. Treats the action as
    /// `.toggle` (the original Daisy hotkey contract). Kept so
    /// pre-multi-slot call sites in tests / experiments keep working.
    func register(choice: HotkeyChoice, action: @escaping @MainActor @Sendable () -> Void) {
        register(slot: .record, choice: choice, action: .toggle(action))
    }

    /// Combinations we've already complained about this launch — see the
    /// failure path in `installCarbonToggle`.
    private static var reportedRegistrationFailures: Set<String> = []

    /// Carbon path — single fire on press, no permission required.
    /// Used by `.toggle` mode for any non-Fn key.
    private func installCarbonToggle(slot: HotkeySlot, keyCode: UInt32, mods: UInt32) {
        carbonCombos[slot] = (keyCode, mods)
        publishCarbonKeys()
        guard !carbonPaused else { return }
        ensureEventHandlerInstalled()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(
            signature: fourCharCode("DAIS"),
            id: slot.rawValue
        )
        let status = RegisterEventHotKey(
            keyCode,
            mods,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if let ref, status == noErr {
            refs[slot] = ref
            return
        }
        // The status used to be discarded, so a combination already held
        // by another app (Raycast, Alfred, Keyboard Maestro, a system
        // shortcut) failed with `eventHotKeyExistsErr` and NOTHING said
        // so: Settings kept showing the shortcut as assigned, the key
        // did nothing, and no line reached the log either. The hold path
        // right below has always handled its own permission failure
        // properly; this was the one silent one (audit 2026-09-01).
        let label = HotkeyChoice.humanLabel(keyCode: keyCode, modifiers: mods)
        log.warning("RegisterEventHotKey failed for \(label, privacy: .public) (slot \(slot.rawValue, privacy: .public)) — OSStatus \(status, privacy: .public)")
        // Only `eventHotKeyExistsErr` means "taken"; anything else is
        // our own bug and shouldn't accuse another app of it.
        // The row that holds this slot's shortcut, so the toast names it
        // and lands on it; the two slots without a row of their own land
        // on the tab.
        let row = Self.settingsRow(for: slot)
        let place = row?.path ?? SettingsTab.shortcuts.path
        let message = status == OSStatus(eventHotKeyExistsErr)
            ? String(localized: "Another app is already using \(label) — Daisy can't use it as a shortcut. Pick a different one in \(place).")
            : String(localized: "Daisy couldn't register \(label) as a shortcut. Try a different combination in \(place).")
        // One toast per combination per launch. `applyAllHotkeys`
        // re-registers all seven slots on every settings change, so a
        // standing conflict would otherwise fire on each keystroke in
        // the shortcut recorder and evict every other toast — the
        // ToastCenter has one slot too.
        guard Self.reportedRegistrationFailures.insert(label).inserted else { return }
        ToastCenter.shared.showAction(
            message,
            actionLabel: String(localized: "Open Settings"),
            style: .warning,
            duration: .seconds(15)
        ) {
            // Land on the slot's own row (its tab wins) in the Settings
            // window, which comes up over whatever is open.
            AppNavigation.shared.openInSettings(.shortcuts, row: row)
        }
    }

    /// The Settings row a slot's shortcut is set on. Rewrite and «note
    /// only» have none: they follow the Daisy key.
    private static func settingsRow(for slot: HotkeySlot) -> SettingsRow? {
        switch slot {
        case .record: .recordHotkey
        case .voiceNote: .daisyKey
        case .dictation: .dictationHotkey
        case .fixLayout: .layoutFixHotkey
        case .markMoment: .markMomentHotkey
        case .repasteLast: .repasteHotkey
        case .rewrite, .noteOnly: nil
        }
    }

    /// The Daisy key on an ordinary key (⌃⌥D, ⌃⇧D, ⌃⌥⌘D): a Carbon hotkey
    /// with its released event, so the key and its autorepeat never reach
    /// the front app — a monitor only listens, and a held ⌃⇧D typed ^D
    /// (EOF) into Terminal over and over (review 22.10). A key-up monitor
    /// stands behind the released event; a second release is ignored.
    private func installCarbonHold(slot: HotkeySlot, keyCode: UInt32, mods: UInt32) {
        installCarbonToggle(slot: slot, keyCode: keyCode, mods: mods)
        guard refs[slot] != nil || carbonPaused else { return }
        let handle: @Sendable (NSEvent) -> Void = { [weak self] event in
            guard let self, UInt32(event.keyCode) == keyCode else { return }
            self.fireOnRelease(slot: slot)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp, handler: handle) {
            fnMonitors[slot] = monitor
        }
        localMonitors[slot] = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            handle(event)
            return event
        }
    }

    /// NSEvent .flagsChanged monitor for Fn / 🌐 globe key.
    /// `isHold` switches between toggle (fire on rising edge only)
    /// and push-to-talk (fire onPress on rising edge, onRelease on
    /// falling edge).
    private func installFnFlagsMonitor(slot: HotkeySlot, isHold: Bool) {
        let state = HoldPressState()
        let handle: @Sendable (NSEvent) -> Void = { [weak self, state] event in
            guard let self else { return }
            // .function covers both legacy Fn and modern 🌐 globe.
            let isDown = event.modifierFlags.contains(.function)
            let wasDown = state.swap(isDown)
            if isDown && !wasDown {
                self.fireOnPress(slot: slot)
            } else if !isDown && wasDown && isHold {
                self.fireOnRelease(slot: slot)
            }
        }
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handle)
        guard let monitor else {
            promptForInputMonitoring(label: "Fn / 🌐 key")
            return
        }
        fnMonitors[slot] = monitor
        localMonitors[slot] = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handle(event)
            return event
        }
    }

    /// Held modifiers (⌃⌥, the right ⌘): `.flagsChanged` for the chord,
    /// `.keyDown` for a key that joins it — see `ModifierHoldMachine`. A
    /// toggle fires on the press and ignores the rest.
    private func installModifierHoldMonitor(slot: HotkeySlot, choice: HotkeyChoice, isHold: Bool) {
        let box = ModifierHoldBox()
        // ⌃⌥ is VoiceOver's own modifier; while VoiceOver runs it's left alone.
        let yieldsToVoiceOver = !choice.isRightCommand && (choice.modifiers ?? 0) & UInt32(controlKey | optionKey) == UInt32(controlKey | optionKey)
        let perform: @Sendable ([ModifierHoldMachine.Output]) -> Void = { [weak self] produced in
            guard let self else { return }
            var outputs = produced
            // A key or click the system keeps for itself (⌘Tab, Spotlight's
            // ⌘Space) never reaches a monitor, but the system's own counters
            // saw it: the hold was that shortcut's, not Daisy's (review 22.10).
            if outputs.contains(.release), let since = box.armedAt, self.inputArrived(since: since, besides: slot) {
                outputs = outputs == [.press, .release] ? [] : outputs.map { $0 == .release ? .cancel : $0 }
            }
            for output in outputs {
                switch output {
                case .press: self.fireOnPress(slot: slot)
                case .release: if isHold { self.fireOnRelease(slot: slot) }
                case .cancel: if isHold { self.fireOnCancel(slot: slot) }
                case .scheduleArm(let generation):
                    let flagsAt = box.lastFlagsAt
                    box.armedAt = flagsAt > 0 ? flagsAt : ProcessInfo.processInfo.systemUptime
                    DispatchQueue.main.asyncAfter(deadline: .now() + ModifierHoldMachine.armDelay) { [weak self] in
                        guard let self else { return }
                        // Only a press comes out of an elapsed arm.
                        if box.run({ $0.armElapsed(generation) }).contains(.press) { self.fireOnPress(slot: slot) }
                    }
                }
            }
        }
        let handle: @Sendable (NSEvent) -> Void = { event in
            // A key or a click joining the chord — ⌘-click, ⌃⌥-arrows.
            guard event.type == .flagsChanged else {
                perform(box.run { $0.keyDown() })
                return
            }
            box.lastFlagsAt = event.timestamp
            let read = ModifierChordReading.read(event.modifierFlags, for: choice)
            let reading = yieldsToVoiceOver && read != .none && NSWorkspace.shared.isVoiceOverEnabled ? .extra : read
            perform(box.run { $0.flags(reading) })
        }
        modifierInterrupts.withLock { $0[slot] = { perform(box.run { $0.keyDown() }) } }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle)
        guard let monitor else {
            promptForInputMonitoring(label: choice.displayLabel)
            return
        }
        fnMonitors[slot] = monitor
        localMonitors[slot] = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handle(event)
            return event
        }
    }

    /// Modifiers on their own for a shortcut that acts once: a clean tap
    /// fires it — see `ModifierTapMachine`. Not in secure input: a ⌥
    /// brushed while typing a password is nobody's request.
    private func installModifierTapMonitor(slot: HotkeySlot, choice: HotkeyChoice) {
        let machine = OSAllocatedUnfairLock(initialState: ModifierTapMachine())
        // ⌃⌥ is VoiceOver's own modifier; while VoiceOver runs it's left alone.
        let yieldsToVoiceOver = (choice.modifiers ?? 0) & UInt32(controlKey | optionKey) == UInt32(controlKey | optionKey)
        let handle: @Sendable (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            guard event.type == .flagsChanged else {
                machine.withLock { $0.otherInput() }
                return
            }
            let read = ModifierChordReading.read(event.modifierFlags, for: choice)
            let reading = yieldsToVoiceOver && read != .none && NSWorkspace.shared.isVoiceOverEnabled ? .extra : read
            let time = event.timestamp
            guard let tap = machine.withLock({ $0.flags(reading, at: time) }) else { return }
            // Asked now, at the release: a key typed right after it must
            // not read as one typed during the press.
            guard !self.inputArrived(during: tap, besides: slot), !IsSecureEventInputEnabled() else { return }
            // A drag that began before the press (⌥-copy in Finder) is
            // still going: its click never reached the machine.
            guard NSEvent.pressedMouseButtons == 0 else { return }
            self.fireOnPress(slot: slot)
        }
        modifierInterrupts.withLock { $0[slot] = { machine.withLock { $0.otherInput() } } }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle)
        guard let monitor else {
            promptForInputMonitoring(label: choice.displayLabel)
            return
        }
        fnMonitors[slot] = monitor
        localMonitors[slot] = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handle(event)
            return event
        }
    }

    /// `inputArrived(since:besides:)` for a tap: only what came between
    /// its press and its release counts.
    nonisolated func inputArrived(during tap: ModifierTapMachine.Tap, besides slot: HotkeySlot) -> Bool {
        if lastHotkeyFire.withLock({ $0 }).contains(where: {
            // Handled before this release reached us, so any since the
            // press came during it.
            $0.key != slot && $0.value > tap.pressedAt
        }) { return true }
        let now = ProcessInfo.processInfo.systemUptime
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types.contains {
            ModifierTapMachine.inputSwallowed(
                during: tap,
                secondsSinceLastInput: CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0),
                now: now
            )
        }
    }

    /// Whether a key went down or a mouse button was pressed since
    /// `start` (system uptime), anywhere — including what a system
    /// shortcut swallowed — or another shortcut of Daisy's fired.
    /// Hardware only: Daisy's own posted ⌘C / ⌘V aren't the person's.
    /// Scrolling isn't counted: a trackpad's momentum outlives the swipe.
    nonisolated func inputArrived(since start: TimeInterval, besides slot: HotkeySlot) -> Bool {
        if lastHotkeyFire.withLock({ $0 }).contains(where: { $0.key != slot && $0.value >= start }) { return true }
        let held = ProcessInfo.processInfo.systemUptime - start
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types.contains { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) < held }
    }

    /// NSEvent .keyDown + .keyUp monitor for hold-to-talk bindings
    /// on regular (non-Fn) keys. Filters autorepeat key-downs so
    /// the press action fires exactly once per physical press.
    private func installKeyHoldMonitor(slot: HotkeySlot, keyCode: UInt32, mods: UInt32) {
        let state = HoldPressState()
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp]
        let handle: @Sendable (NSEvent) -> Void = { [weak self, state] event in
            guard let self else { return }
            // Match keyCode + Carbon-equivalent modifier bits. The
            // NSEvent modifierFlags can carry extra OS-level bits
            // (capsLock, deviceIndependentFlagsMask) we don't care
            // about — mask down before comparison.
            guard UInt32(event.keyCode) == keyCode else { return }

            switch event.type {
            case .keyDown:
                guard matchesCarbonMods(event.modifierFlags, carbonMods: mods) else { return }
                if event.isARepeat { return }
                if state.swap(true) { return }  // already-down race
                self.fireOnPress(slot: slot)
            case .keyUp:
                // The key going up ends the hold whatever the modifiers
                // are by then: people let go of ⌃⌥⌘ a beat before the
                // letter, and that key-up used to be dropped, leaving the
                // hold running (backlog 34, the Daisy key on ⌃⌥⌘D).
                if !state.swap(false) { return }  // already-up race
                self.fireOnRelease(slot: slot)
            default:
                break
            }
        }
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle)
        guard let monitor else {
            promptForInputMonitoring(label: HotkeyChoice.humanLabel(keyCode: keyCode, modifiers: mods))
            return
        }
        fnMonitors[slot] = monitor
        localMonitors[slot] = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handle(event)
            return event
        }
    }

    /// Dispatch the press half of the slot's current action.
    /// Crosses MainActor for the actual closure invocation.
    nonisolated private func fireOnPress(slot: HotkeySlot) {
        // Another shortcut of Daisy's went through a held chord: not a
        // Daisy-key press after all.
        lastHotkeyFire.withLock { $0[slot] = ProcessInfo.processInfo.systemUptime }
        for (other, interrupt) in modifierInterrupts.withLock({ $0 }) where other != slot { interrupt() }
        guard let action = actionMap.get(slot: slot) else { return }
        switch action {
        case .toggle(let f):
            Task { @MainActor in
                // Only while Daisy is in front: a recorder left listening behind
                // another app must not mute every shortcut.
                guard !(KeyCaptureBox.isListening && NSApp.isActive) else { return }
                f()
            }
        case .hold(let onPress, _, _):
            Task { @MainActor in
                // Only while Daisy is in front: a recorder left listening behind
                // another app must not mute every shortcut.
                guard !(KeyCaptureBox.isListening && NSApp.isActive) else { return }
                onPress()
            }
        }
    }

    /// Dispatch the release half — only relevant for `.hold`
    /// actions. `.toggle` slots ignore release edges.
    nonisolated private func fireOnRelease(slot: HotkeySlot) {
        guard case .hold(_, let onRelease, _) = actionMap.get(slot: slot) else { return }
        Task { @MainActor in onRelease() }
    }

    /// Dispatch a held-modifier cancel — `.hold` only; one without an
    /// `onCancel` gets its release.
    nonisolated private func fireOnCancel(slot: HotkeySlot) {
        guard case .hold(_, let onRelease, let onCancel) = actionMap.get(slot: slot) else { return }
        Task { @MainActor in (onCancel ?? onRelease)() }
    }

    /// Show a once-per-failure toast nudging the user to Privacy &
    /// Security → Input Monitoring. The actual Settings deeplink
    /// jumps straight to the right pane.
    @MainActor
    private func promptForInputMonitoring(label: String) {
        log.warning("NSEvent.addGlobalMonitorForEvents returned nil — Input Monitoring denied for \(label, privacy: .public)")
        ToastCenter.shared.showAction(
            String(localized: "Daisy needs Input Monitoring to use the \(label) hotkey."),
            actionLabel: String(localized: "Open Settings"),
            style: .warning,
            perform: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
            }
        )
    }

    /// Unregister a single slot. Idempotent. Removes the shared
    /// event handler only when no slot remains registered.
    func unregister(slot: HotkeySlot) {
        modifierInterrupts.withLock { _ = $0.removeValue(forKey: slot) }
        if carbonCombos.removeValue(forKey: slot) != nil { publishCarbonKeys() }
        if let ref = refs[slot] {
            UnregisterEventHotKey(ref)
            refs.removeValue(forKey: slot)
        }
        if let monitor = fnMonitors[slot] {
            NSEvent.removeMonitor(monitor)
            fnMonitors.removeValue(forKey: slot)
        }
        if let monitor = localMonitors[slot] {
            NSEvent.removeMonitor(monitor)
            localMonitors.removeValue(forKey: slot)
        }
        actionMap.set(slot: slot, action: nil)
        if refs.isEmpty, let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    /// While the shortcut recorder listens, Daisy's Carbon hotkeys are
    /// off: Carbon takes their key before any monitor sees it, so
    /// pressing ⇧⌘R to record it recorded «⇧⌘» instead, and a
    /// combination could never be moved from one row to another
    /// (review 31.10). Back on when it stops. A change registered
    /// meanwhile waits for the resume too.
    func setCarbonPaused(_ paused: Bool) {
        guard paused != carbonPaused else { return }
        carbonPaused = paused
        if paused {
            for (slot, ref) in refs {
                UnregisterEventHotKey(ref)
                refs.removeValue(forKey: slot)
            }
        } else {
            for (slot, combo) in carbonCombos where refs[slot] == nil {
                installCarbonToggle(slot: slot, keyCode: combo.keyCode, mods: combo.mods)
            }
        }
    }

    private func publishCarbonKeys() {
        let keys = Set(carbonCombos.values.map { Self.carbonKey(keyCode: $0.keyCode, mods: $0.mods) })
        Self.carbonKeys.withLock { $0 = keys }
    }

    /// Unregister every slot. Used at app shutdown / `applyAll` rewiring.
    func unregister() {
        for slot in HotkeySlot.allCases {
            unregister(slot: slot)
        }
    }

    /// Install the Carbon event handler that dispatches by
    /// `EventHotKeyID.id`. Lazy — runs once, persists until the
    /// last slot unregisters.
    private func ensureEventHandlerInstalled() {
        guard eventHandler == nil else { return }
        // Released too, for the Daisy key's Carbon hold; a toggle's
        // release is dropped in `fireOnRelease`.
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let userData, let eventRef else { return noErr }
                // Extract the EventHotKeyID so we know which slot
                // fired. Without this the manager couldn't tell
                // record vs voiceNote vs dictation apart.
                var hkID = EventHotKeyID()
                let size = MemoryLayout<EventHotKeyID>.size
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    size,
                    nil,
                    &hkID
                )
                guard status == noErr else { return noErr }
                guard let slot = HotkeySlot(rawValue: hkID.id) else { return noErr }
                let manager = Unmanaged<HotkeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                // Toggles, and the Daisy key's hold on an ordinary key
                // (`installCarbonHold`); other holds live in monitor land.
                if GetEventKind(eventRef) == UInt32(kEventHotKeyReleased) {
                    manager.fireOnRelease(slot: slot)
                } else {
                    manager.fireOnPress(slot: slot)
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            userData,
            &eventHandler
        )
    }
}

// MARK: - FourCharCode helper

private func fourCharCode(_ string: String) -> OSType {
    var code: OSType = 0
    for char in string.unicodeScalars.prefix(4) {
        code = (code << 8) | (OSType(char.value) & 0xFF)
    }
    return code
}

/// Compare an NSEvent's `modifierFlags` against a Carbon modifier
/// bitmask. NSEvent includes a number of OS-level flag bits we
/// don't care about (capsLock state, deviceIndependentFlagsMask
/// internals); mask the comparison down to the four we register
/// hotkeys against — ⌘ / ⌃ / ⌥ / ⇧.
private func matchesCarbonMods(_ ns: NSEvent.ModifierFlags, carbonMods: UInt32) -> Bool {
    var fromNS: UInt32 = 0
    if ns.contains(.command)  { fromNS |= UInt32(cmdKey) }
    if ns.contains(.control)  { fromNS |= UInt32(controlKey) }
    if ns.contains(.option)   { fromNS |= UInt32(optionKey) }
    if ns.contains(.shift)    { fromNS |= UInt32(shiftKey) }
    return fromNS == carbonMods
}
