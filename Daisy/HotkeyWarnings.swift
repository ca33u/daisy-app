//
//  HotkeyWarnings.swift
//  Daisy
//
//  What Settings says under a shortcut instead of refusing it (Egor,
//  31.10.2026: «не будем ограничивать пользователей по хоткеям, хотят
//  одну — пускай ставят, просто можно предупреждать, что какие-то уже
//  заложены»). Any key or combination can be recorded now; these are the
//  things worth knowing about the one picked:
//
//   • it was another of Daisy's shortcuts — the newer one wins and the
//     other is left without one (`takenFrom`, said once, by the row that
//     took it). Two actions on one key never both worked: Fn on both
//     dictation and «paste my last dictation» fired only one of them;
//   • macOS already uses it (⌘C, ⌘Space, ⌃Space…);
//   • it is a key that types — set as a shortcut, typing it anywhere
//     fires it.
//

import AppKit
import Carbon.HIToolbox

nonisolated enum HotkeyWarning: Hashable, Sendable {
    /// This row took the combination from another one, named here.
    case takenFrom(String)
    /// macOS uses the combination for this.
    case system(String)
    /// A key that types something.
    case typesText
    /// A key that moves the caret or edits text.
    case editsText

    var text: String {
        switch self {
        case .takenFrom(let other):
            String(format: String(localized: "Was the shortcut for “%@” — that one has none now."), other)
        case .system(let use):
            String(format: String(localized: "macOS uses this for “%@”. Set here, only one of the two happens — Daisy’s action or that."), use)
        case .typesText:
            String(localized: "A key that types: while it’s a shortcut, typing it anywhere triggers this.")
        case .editsText:
            String(localized: "A key that moves the cursor or edits text: while it’s a shortcut, it may stop doing that everywhere.")
        }
    }
}

nonisolated enum HotkeyWarnings {
    /// The same keys — what makes two shortcuts one. Labels don't count:
    /// a preset and the same combination recorded are one.
    static func sameKeys(_ a: HotkeyChoice, _ b: HotkeyChoice) -> Bool {
        guard let keyCode = a.keyCode else { return false }
        return keyCode == b.keyCode && (a.modifiers ?? 0) == (b.modifiers ?? 0)
    }

    /// The first of `others` (name, current choice) with the same keys.
    static func owner(of choice: HotkeyChoice, among others: [(name: String, choice: HotkeyChoice)]) -> String? {
        others.first { sameKeys(choice, $0.choice) }?.name
    }

    /// What is worth saying about the choice by itself.
    static func standing(for choice: HotkeyChoice) -> [HotkeyWarning] {
        var warnings: [HotkeyWarning] = []
        if let use = systemUse(of: choice) { warnings.append(.system(use)) }
        if choice.typesText { warnings.append(.typesText) }
        if editsText(choice) { warnings.append(.editsText) }
        return warnings
    }

    /// Arrows, Home/End, Page up/down, Delete — alone or with ⇧/⌥/⌘
    /// (selection, word and line moves). ⌃ with them is macOS's own
    /// (`systemUse`).
    static func editsText(_ choice: HotkeyChoice) -> Bool {
        guard let keyCode = choice.keyCode, systemUse(of: choice) == nil else { return false }
        guard (choice.modifiers ?? 0) & UInt32(controlKey) == 0 else { return false }
        let editing: Set<Int> = [
            kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End,
            kVK_PageUp, kVK_PageDown, kVK_ForwardDelete, kVK_Delete,
        ]
        return editing.contains(Int(keyCode))
    }

    /// What macOS does with the combination, when it is one of the
    /// shortcuts everybody has. Not every app's menu — the ones that
    /// work everywhere, or that the system itself takes.
    static func systemUse(of choice: HotkeyChoice) -> String? {
        guard let keyCode = choice.keyCode else { return nil }
        if choice.isFnOnly { return String(localized: "Change input source, emoji or dictation") }
        let mods = choice.modifiers ?? 0
        let cmd = UInt32(cmdKey), shift = UInt32(shiftKey), ctrl = UInt32(controlKey), opt = UInt32(optionKey)
        switch (Int(keyCode), mods) {
        case (kVK_ANSI_C, cmd): return String(localized: "Copy")
        case (kVK_ANSI_V, cmd): return String(localized: "Paste")
        case (kVK_ANSI_X, cmd): return String(localized: "Cut")
        case (kVK_ANSI_Z, cmd): return String(localized: "Undo the last change")
        case (kVK_ANSI_Z, cmd | shift): return String(localized: "Redo")
        case (kVK_ANSI_A, cmd): return String(localized: "Select All")
        case (kVK_ANSI_S, cmd): return String(localized: "Save")
        case (kVK_ANSI_Q, cmd): return String(localized: "Quit")
        case (kVK_ANSI_W, cmd): return String(localized: "Close Window")
        case (kVK_ANSI_N, cmd): return String(localized: "New document or window")
        case (kVK_ANSI_T, cmd): return String(localized: "New Tab")
        case (kVK_ANSI_F, cmd): return String(localized: "Find")
        case (kVK_ANSI_P, cmd): return String(localized: "Print")
        case (kVK_ANSI_O, cmd): return String(localized: "Open")
        case (kVK_ANSI_H, cmd): return String(localized: "Hide")
        case (kVK_ANSI_M, cmd): return String(localized: "Minimize")
        case (kVK_ANSI_Comma, cmd): return String(localized: "Settings")
        case (kVK_Tab, cmd): return String(localized: "Switch apps")
        case (kVK_ANSI_Grave, cmd): return String(localized: "Switch windows")
        case (kVK_Space, cmd): return "Spotlight"
        case (kVK_Space, ctrl), (kVK_Space, ctrl | opt): return String(localized: "Change input source")
        case (kVK_Space, ctrl | cmd): return String(localized: "Emoji & Symbols")
        case (kVK_ANSI_Q, ctrl | cmd): return String(localized: "Lock Screen")
        case (kVK_Escape, opt | cmd): return String(localized: "Force Quit")
        case (kVK_ANSI_3, cmd | shift), (kVK_ANSI_4, cmd | shift), (kVK_ANSI_5, cmd | shift):
            return String(localized: "Screenshot")
        case (kVK_UpArrow, ctrl): return "Mission Control"
        case (kVK_DownArrow, ctrl): return String(localized: "App windows")
        case (kVK_LeftArrow, ctrl), (kVK_RightArrow, ctrl): return String(localized: "Switch desktops")
        default: return nil
        }
    }
}
