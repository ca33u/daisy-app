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
//   • what it does to the rest of the Mac, by how the row registers it
//     (`HotkeyRowKind`): a Carbon row takes a typing key, ⌘C or an arrow
//     from every app; macOS keeps its own (⌘Space) whatever Daisy asks;
//     dictation only listens, so the key goes on working and opens the
//     microphone besides; a held modifier people hold on the way to
//     something else opens the microphone too.
//

import AppKit
import Carbon.HIToolbox

/// How a row's shortcut is registered, which decides what a key on it
/// does to the rest of the Mac.
nonisolated enum HotkeyRowKind: Sendable {
    /// Acts once (record, the layout fix, mark a moment, paste the last
    /// dictation): a Carbon hotkey, which takes its key from every app;
    /// a modifier on its own is a tap.
    case oneShot
    /// The Daisy key: a Carbon hotkey too, held; a modifier on its own is
    /// a hold that opens the microphone.
    case daisyKey
    /// Dictation: an event monitor, which only listens — the key goes on
    /// doing what it did — held; the microphone opens.
    case dictation
}

nonisolated enum HotkeyWarning: Hashable, Sendable {
    /// This row took the combination from another one, named here.
    case takenFrom(String)
    /// A key that types, taken from every app.
    case stopsTyping
    /// A key that moves the caret or edits text, taken from every app.
    case stopsEditing
    /// An app's own shortcut (Copy…), taken from every app.
    case appShortcutStops(String)
    /// The system's own shortcut (Spotlight…), which it doesn't give up.
    case systemKeeps(String)
    /// Dictation on a key that types or edits: it still does, and the
    /// microphone opens too.
    case alsoStartsDictation
    /// Dictation on an app's shortcut: it still does that too.
    case alsoDoes(String)
    /// A hold on a modifier people hold on the way to something else.
    case holdOpensMicrophone
    /// Fn on a row that acts on a tap: macOS acts on that tap as well.
    case fnDoesItsOwnToo

    var text: String {
        switch self {
        case .takenFrom(let other):
            String(format: String(localized: "Was the shortcut for “%@” — that one has none now."), other)
        case .stopsTyping:
            String(localized: "While it’s set here, this key stops typing in every app.")
        case .stopsEditing:
            String(localized: "While it’s set here, this key stops moving the cursor or editing text in every app.")
        case .appShortcutStops(let use):
            String(format: String(localized: "“%@” stops working in every app while this is set here."), use)
        case .systemKeeps(let use):
            String(format: String(localized: "macOS keeps this for “%@” — Daisy’s shortcut may never fire."), use)
        case .alsoStartsDictation:
            String(localized: "Pressing it also starts dictation — the microphone opens.")
        case .alsoDoes(let use):
            String(format: String(localized: "It still does “%@” in apps — and starts dictation as well."), use)
        case .holdOpensMicrophone:
            String(localized: "Held a moment on the way to a shortcut or a capital letter, it starts recording — the microphone opens.")
        case .fnDoesItsOwnToo:
            String(localized: "A tap of Fn also does what macOS has it do — change the input source, show emoji or start its dictation.")
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

    /// What the choice will do to the rest of the Mac on a row of this
    /// kind — said plainly, not refused (Egor 31.10).
    static func standing(for choice: HotkeyChoice, on row: HotkeyRowKind) -> [HotkeyWarning] {
        guard choice.keyCode != nil else { return [] }
        if choice.isFnOnly {
            // Held for dictation, Fn is the default and macOS stays out of
            // the way; tapped, macOS does its own Fn action too.
            return row == .oneShot ? [.fnDoesItsOwnToo] : []
        }
        if choice.isModifierHold {
            // A tap of a modifier costs the Mac nothing. A hold does: on
            // the way to ⇧-capitals, ⌘-shortcuts, ⌥-letters the hold arms
            // and the microphone opens — a lone key or a chord like ⇧⌘
            // alike. The presets (⌃⌥, the right ⌘ / ⌥) were chosen for
            // being the keys nobody holds that way.
            guard row != .oneShot else { return [] }
            if let key = choice.loneModifier, key == .rightCommand || key == .rightOption { return [] }
            if choice.loneModifier == nil, choice.modifiers == UInt32(controlKey | optionKey) { return [] }
            return [.holdOpensMicrophone]
        }
        let takesKey = row != .dictation
        if let use = systemUse(of: choice) {
            if use.isSystem { return [.systemKeeps(use.name)] }
            return [takesKey ? .appShortcutStops(use.name) : .alsoDoes(use.name)]
        }
        if choice.typesText { return [takesKey ? .stopsTyping : .alsoStartsDictation] }
        if editsText(choice) { return [takesKey ? .stopsEditing : .alsoStartsDictation] }
        return []
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
    /// shortcuts everybody has, and whether the SYSTEM keeps it (it beats
    /// any app's hotkey) or an app's menu answers it (Daisy's Carbon
    /// hotkey beats that, in every app).
    static func systemUse(of choice: HotkeyChoice) -> (name: String, isSystem: Bool)? {
        guard let keyCode = choice.keyCode else { return nil }
        let mods = choice.modifiers ?? 0
        let cmd = UInt32(cmdKey), shift = UInt32(shiftKey), ctrl = UInt32(controlKey), opt = UInt32(optionKey)
        func app(_ name: String) -> (String, Bool) { (name, false) }
        func system(_ name: String) -> (String, Bool) { (name, true) }
        switch (Int(keyCode), mods) {
        case (kVK_ANSI_C, cmd): return app(String(localized: "Copy"))
        case (kVK_ANSI_V, cmd): return app(String(localized: "Paste"))
        case (kVK_ANSI_X, cmd): return app(String(localized: "Cut"))
        case (kVK_ANSI_Z, cmd): return app(String(localized: "Undo the last change"))
        case (kVK_ANSI_Z, cmd | shift): return app(String(localized: "Redo"))
        case (kVK_ANSI_A, cmd): return app(String(localized: "Select All"))
        case (kVK_ANSI_S, cmd): return app(String(localized: "Save"))
        case (kVK_ANSI_Q, cmd): return app(String(localized: "Quit"))
        case (kVK_ANSI_W, cmd): return app(String(localized: "Close Window"))
        case (kVK_ANSI_N, cmd): return app(String(localized: "New document or window"))
        case (kVK_ANSI_T, cmd): return app(String(localized: "New Tab"))
        case (kVK_ANSI_F, cmd): return app(String(localized: "Find"))
        case (kVK_ANSI_P, cmd): return app(String(localized: "Print"))
        case (kVK_ANSI_O, cmd): return app(String(localized: "Open"))
        case (kVK_ANSI_H, cmd): return app(String(localized: "Hide"))
        case (kVK_ANSI_M, cmd): return app(String(localized: "Minimize"))
        case (kVK_ANSI_Comma, cmd): return app(String(localized: "Settings"))
        case (kVK_ANSI_Grave, cmd): return app(String(localized: "Switch windows"))
        case (kVK_Tab, cmd): return system(String(localized: "Switch apps"))
        case (kVK_Space, cmd): return system("Spotlight")
        case (kVK_Space, ctrl), (kVK_Space, ctrl | opt): return system(String(localized: "Change input source"))
        case (kVK_Space, ctrl | cmd): return system(String(localized: "Emoji & Symbols"))
        case (kVK_ANSI_Q, ctrl | cmd): return system(String(localized: "Lock Screen"))
        case (kVK_Escape, opt | cmd): return system(String(localized: "Force Quit"))
        case (kVK_ANSI_3, cmd | shift), (kVK_ANSI_4, cmd | shift), (kVK_ANSI_5, cmd | shift):
            return system(String(localized: "Screenshot"))
        case (kVK_UpArrow, ctrl): return system("Mission Control")
        case (kVK_DownArrow, ctrl): return system(String(localized: "App windows"))
        case (kVK_LeftArrow, ctrl), (kVK_RightArrow, ctrl): return system(String(localized: "Switch desktops"))
        default: return nil
        }
    }
}
