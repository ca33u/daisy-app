//
//  LayoutFixService.swift
//  Daisy
//
//  The fix key: press it and text typed in the wrong keyboard layout
//  becomes what you meant. «ghbdtn, rfr ltkf» → «привет, как дела».
//
//  Sources of text, in order:
//
//   1. A selection, read through PasteboardProxy. Works in any app that
//      answers ⌘C, which is nearly all of them, and lets the user fix
//      something they typed an hour ago.
//   2. Nothing selected: the last word before the caret (Egor, 31.10:
//      «переключение последнего слова без выделения») — the Punto
//      habit: type, notice, hit the key. First as the field shows it
//      through Accessibility, which works with the automatic watcher
//      off; then, for an app that won't show its text, the word the
//      watcher's tap saw typed.
//
//  Pressing again right away puts back what was there — the undo below,
//  for the automatic fixes and for the key's own last word alike.
//
//  With no answer from either, the honest answer is to say so — which
//  the toast does.
//

import AppKit
import ApplicationServices
import os

@MainActor
final class LayoutFixService {
    static let shared = LayoutFixService()

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "LayoutFix")
    /// A second press while the first is mid-flight would fight over the
    /// clipboard.
    private var isRunning = false
    /// A lone-modifier tap already asked for Accessibility this run.
    private var askedForAccessibilityOnTap = false

    private init() {}

    /// `key` is what was pressed — the fix shortcut or the Daisy key —
    /// and says whether the press itself reached the automatic
    /// watcher's tap as a keystroke: a key with or without modifiers
    /// does, a modifier alone or Fn (`.flagsChanged`) doesn't. That is
    /// how many keystrokes since a fix the undo may forgive.
    ///
    /// `quiet`: the fix shortcut is a modifier on its own (a tap of ⌥),
    /// a key people also brush by accident, so the «nothing to fix» kind
    /// of answer isn't worth a toast; only what needs the person's action
    /// is said. Not the Daisy key's tap, which nobody makes by accident.
    func trigger(settings: AppSettings, from key: HotkeyChoice, quiet: Bool = false) async {
        let triggerKeystrokes: UInt64 = key.isModifierHold || key.isFnOnly ? 0 : 1
        // Belt and braces: the shortcut isn't registered while the fixer
        // is off, but nothing re-types text past this line either.
        guard settings.layoutFixEnabled, !isRunning else { return }

        guard KeyboardLayouts.shared.installed.count > 1 else {
            if quiet { return }
            ToastCenter.shared.show(
                String(localized: "Add a second keyboard layout in System Settings — there's nothing to switch between."),
                style: .warning
            )
            return
        }
        // We synthesize ⌘C / ⌘V and backspaces.
        guard AXIsProcessTrusted() else {
            // A tap of a lone modifier asks once per run: with the grant
            // revoked, a system prompt and a toast on every brush of ⌥
            // would be the whole experience of the Mac (review 31.10).
            if quiet {
                guard !askedForAccessibilityOnTap else { return }
                askedForAccessibilityOnTap = true
            }
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            ToastCenter.shared.show(
                String(localized: "Fixing the layout needs Accessibility access — grant it in System Settings and try again."),
                style: .warning
            )
            return
        }

        // Same exclusions as the automatic watcher: ⌘C / ⌘V into a
        // terminal or a spreadsheet cell is its own kind of damage, and
        // the reasons don't change because the user asked.
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard !LayoutAutoFix.isExcluded(frontmost) else {
            if quiet { return }
            ToastCenter.shared.show(
                String(localized: "Daisy doesn't rewrite text in this app — it's on the excluded list."),
                style: .warning
            )
            return
        }

        isRunning = true
        defer { isRunning = false }

        // 0. Undo — checked before the selection/fix-key logic below.
        // Fires for a fix the automatic watcher made, and for the last
        // word this key fixed a moment ago (never for a selection — see
        // LayoutFixUndo).
        //
        // The asymmetry with `confirmBeforeCaret` elsewhere in this
        // feature is deliberate, and inverted on purpose: the fix
        // itself treats a silent app as "go ahead" (nil → allowed),
        // because refusing there breaks the feature everywhere outside
        // AppKit. Undo treats a silent app as "decline" (nil →
        // refused) — missing a fix costs a manual correction; missing
        // an undo costs erasing whatever the person typed AFTER it.
        if let record = LayoutFixUndo.shared.fresh(bundleID: frontmost) {
            // Same editable-text gate every other settle site uses,
            // mandatory for BOTH ways of confirming below — it answers
            // "can we send backspaces here at all", not "does the text
            // match", so neither check may skip it.
            if AXFocus.kind() == .editable,
               LayoutFixUndo.confirms(
                   record,
                   textBeforeCaret: AXFocus.textBeforeCaret(count: record.replacementText.utf16.count),
                   tapRunning: LayoutAutoFix.shared.isRunning,
                   currentGeneration: LayoutAutoFix.buffer.generation,
                   triggerKeystrokes: triggerKeystrokes
               ) {
                performUndo(record)
                return
            }
            // Not editable text, AX disagreed, or real typing happened
            // since the fix — either way this key press is not an undo
            // any more. Falls through to the ordinary fix-key behaviour
            // below.
            LayoutFixUndo.shared.clear()
        }

        // 1. A selection, if there is one. Not asked with ⌘C when the
        //    field itself says there is none: ⌘C empties and refills the
        //    clipboard (a clipboard manager records each), and waits for
        //    an answer that won't come — on every tap of a lone ⌥ too.
        //    Only where that answer is trustworthy: web editors report a
        //    caret per block and lag behind (review 31.10).
        let noSelectionReported = AXFocus.kind() == .editable && AXFocus.hasNoSelection() == true
        if !noSelectionReported || AXFocus.caretMayBeUnreliable() {
            if await fixSelection(settings: settings, quiet: quiet, lineCopyIsNoSelection: noSelectionReported) { return }
        }

        // 2. No selection — the last word before the caret. Both paths
        //    type the correction themselves, switch the source, count the
        //    fix and leave the undo, so there is nothing to finish here.
        //    The field's own answer first: it is what the backspaces will
        //    delete. The tap's word only when the field won't say — a
        //    definite answer (no word there, or one that already reads
        //    right) is not overruled by memory.
        var fieldAnswered = false
        var cantTrustField = false
        switch LayoutAutoFix.shared.fixLastWordOnScreen(settings: settings) {
        case .fixed:
            return
        case .alreadyRight:
            if !quiet {
                ToastCenter.shared.show(
                    String(localized: "That already looks like the layout you meant."),
                    style: .info
                )
            }
            return
        case .noWord:
            fieldAnswered = true
        case .unknown:
            if LayoutAutoFix.shared.fixWordInFlight(settings: settings) { return }
        case .unreliable:
            // The tap has no word either, or it would have been checked.
            cantTrustField = true
        }
        if quiet { return }

        // Two different truths, not one. With the watcher running, or
        // in a field that showed its text, there just wasn't a word.
        // With the watcher OFF in an app that won't show its text, the
        // key has nothing to read the word from — say WHY, instead of
        // leaving the user to discover that half the key is dead there.
        ToastCenter.shared.show(
            !cantTrustField && (fieldAnswered || LayoutAutoFix.shared.isRunning)
                ? String(localized: "Nothing to fix — select the text, or type a word first.")
                : String(localized: "Daisy can’t read the word before the cursor here reliably — select it, or turn on fixing as you type."),
            style: .warning
        )
    }

    /// The selection, through ⌘C. True when there was one — fixed, or
    /// already in the right layout (and said so) — so the caller stops.
    ///
    /// `lineCopyIsNoSelection`: the field said nothing is selected, and is
    /// asked anyway because it can't be trusted. Editors that copy the
    /// whole line on ⌘C with nothing selected answer with that line and
    /// its line break — which is no selection, and pasting its conversion
    /// would land beside the original (review 31.10).
    private func fixSelection(settings: AppSettings, quiet: Bool, lineCopyIsNoSelection: Bool) async -> Bool {
        let borrow = PasteboardProxy.shared.borrow()
        guard let selection = await PasteboardProxy.shared.copySelection(borrow),
              !(lineCopyIsNoSelection && selection.last?.isNewline == true) else {
            PasteboardProxy.shared.giveBack(borrow)
            return false
        }
        guard let fix = LayoutFix.deliberate(selection) else {
            PasteboardProxy.shared.giveBack(borrow)
            if !quiet {
                ToastCenter.shared.show(
                    String(localized: "That already looks like the layout you meant."),
                    style: .info
                )
            }
            return true
        }
        PasteboardProxy.shared.pasteAndReturn(fix.text, borrow)
        finish(with: fix, settings: settings)
        return true
    }

    /// Shared tail: switch the input source if asked, count the fix, and
    /// say what happened. Switching is the difference between fixing one
    /// word and fixing the sentence — without it the next word goes
    /// wrong the same way.
    private func finish(with fix: LayoutFix.Fix, settings: AppSettings) {
        ImprovementStats.record(.layoutFixed)
        if settings.layoutFixSwitchesSource {
            KeyboardLayouts.shared.select(fix.target)
        }
        UsageStats.shared.recordFixes(polished: 1)
        log.info("Layout fix → \(fix.target.id, privacy: .public)")
    }

    /// Delete the fix's output and retype what the person actually
    /// typed — one keypress to reverse a correction they didn't want.
    /// For an automatic one, also a lesson `LayoutFixExceptions`
    /// remembers so it doesn't happen again on the same word; the key's
    /// own fix just goes back, quietly, as Punto's second press does.
    private func performUndo(_ record: LayoutFixUndo.Record) {
        guard LayoutAutoFix.shared.replace(
            presses: record.replacementText.count,
            with: record.originalText
        ) else {
            LayoutFixUndo.shared.clear()
            ToastCenter.shared.show(
                String(localized: "Couldn't undo that — try fixing it by hand."),
                style: .error
            )
            return
        }
        if let restoreLayoutID = record.restoreLayoutID,
           let layout = KeyboardLayouts.shared.installed.first(where: { $0.id == restoreLayoutID }) {
            KeyboardLayouts.shared.select(layout)
        }
        LayoutAutoFix.buffer.discard()
        // Second press in a row is ordinary key work, not an undo of
        // the undo.
        LayoutFixUndo.shared.clear()
        ImprovementStats.record(.layoutUndo)
        guard !record.byKey else {
            log.info("Layout fix undone (fix key)")
            return
        }
        LayoutFixExceptions.shared.add(record.originalWord)
        log.info("Layout fix undone")
        ToastCenter.shared.show(
            String(localized: "Undone — Daisy won't auto-fix that word again."),
            style: .info
        )
    }
}

// MARK: - The last word before the caret

/// Which text the fix key takes for «the last word» when nothing is
/// selected. Pure: the caller reads the text in front of the caret.
nonisolated enum LayoutFixLastWord {
    struct Pick: Equatable, Sendable {
        /// The run of characters to convert, as typed.
        let word: String
        /// The spaces between it and the caret, put back as they were.
        let trailing: String
        /// Backspaces that remove both — one per `Character`, which is
        /// why a word whose characters aren't single scalars is refused.
        var presses: Int { word.count + trailing.count }
    }

    /// The most the key deletes and retypes at once — the same ceiling
    /// as the tap's word.
    static let maxPresses = WordBuffer.maxPresses

    /// The last word in `text` (what sits before the caret), or nil when
    /// there isn't one to touch:
    ///
    ///  - the word is everything back to the previous whitespace —
    ///    punctuation included, because on the wrong layout it IS
    ///    letters (see `LayoutAutoFix.fixLastWordOnScreen`);
    ///  - spaces after it are skipped and kept; a line break is not
    ///    skipped — a caret on a new line has no last word;
    ///  - the word's start has to be in `text`: a run that reaches the
    ///    start of a window that doesn't reach the start of the field
    ///    may begin further back;
    ///  - at least one letter, and only characters one backspace
    ///    removes whole (no combining marks, no attachments).
    static func pick(before text: String, reachesFieldStart: Bool) -> Pick? {
        var characters = Array(text)
        var trailing = ""
        while let last = characters.last, last == " " || last == "\u{00A0}" {
            trailing.insert(characters.removeLast(), at: trailing.startIndex)
        }
        guard let end = characters.indices.last else { return nil }
        var start = end
        while start > characters.startIndex, !characters[start - 1].isWhitespace {
            start -= 1
        }
        guard !characters[end].isWhitespace else { return nil }
        if start == characters.startIndex, !reachesFieldStart { return nil }
        let word = characters[start...end]
        guard word.contains(where: \.isLetter),
              word.allSatisfy(isWholeKeystroke),
              word.count + trailing.count <= maxPresses
        else { return nil }
        return Pick(word: String(word), trailing: trailing)
    }

    /// Whether the field shows, right before the caret, the word the tap
    /// saw typed and what ended it — smart quotes aside.
    ///
    /// Only which word it is, not how it looks: a web editor keeps the
    /// space after it as a no-break space, and a native one capitalised
    /// the first word of the sentence on that space (review 31.10). The
    /// conversion itself still uses what the field shows.
    static func agrees(_ pick: Pick, withTyped word: String, boundary: Character?) -> Bool {
        func normalized(_ text: String) -> String {
            straighteningQuotes(text).replacingOccurrences(of: "\u{00A0}", with: " ").lowercased()
        }
        return normalized(pick.word + pick.trailing).hasSuffix(normalized(word + (boundary.map(String.init) ?? "")))
    }

    /// Typographic quotes back to the ASCII ones the keys typed —
    /// smart quotes rewrite them as you type. One for one.
    static func straighteningQuotes(_ word: String) -> String {
        String(word.map { character -> Character in
            switch character {
            case "\u{2018}", "\u{2019}": "'"
            case "\u{201C}", "\u{201D}": "\""
            default: character
            }
        })
    }

    private static func isWholeKeystroke(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        // U+FFFC stands in for an attachment, U+FFFD for a surrogate cut
        // in half by the read window.
        if scalar == "\u{FFFC}" || scalar == "\u{FFFD}" { return false }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned: return false
        default: return true
        }
    }
}
