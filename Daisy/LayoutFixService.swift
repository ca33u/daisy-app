//
//  LayoutFixService.swift
//  Daisy
//
//  The fix key: press it and text typed in the wrong keyboard layout
//  becomes what you meant. «ghbdtn, rfr ltkf» → «привет, как дела».
//
//  Two sources of text, in order:
//
//   1. A selection, read through PasteboardProxy. Works in any app that
//      answers ⌘C, which is nearly all of them, and lets the user fix
//      something they typed an hour ago.
//   2. The word being typed right now — but only when the automatic
//      watcher is running, because it is the thing that already has that
//      word. This is the Punto Switcher habit (type, notice, hit the
//      key) and it costs us nothing extra: no Accessibility text
//      inspection, no per-app quirks, just the buffer the tap already
//      keeps.
//
//  With the watcher off and nothing selected, the honest answer is to
//  say so — which the toast does.
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

    private init() {}

    func trigger(settings: AppSettings) async {
        // Belt and braces: the shortcut isn't registered while the fixer
        // is off, but nothing re-types text past this line either.
        guard settings.layoutFixEnabled, !isRunning else { return }

        guard KeyboardLayouts.shared.installed.count > 1 else {
            ToastCenter.shared.show(
                String(localized: "Add a second keyboard layout in System Settings — there's nothing to switch between."),
                style: .warning
            )
            return
        }
        // We synthesize ⌘C / ⌘V and backspaces.
        guard AXIsProcessTrusted() else {
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
            ToastCenter.shared.show(
                String(localized: "Daisy doesn't rewrite text in this app — it's on the excluded list."),
                style: .warning
            )
            return
        }

        isRunning = true
        defer { isRunning = false }

        // 0. Undo — checked before the selection/fix-key logic below.
        // Only fires for a fix the AUTOMATIC watcher made: LayoutFixUndo
        // is never populated from this same key's OWN work (the fix key
        // and a mouse selection are things the user asked for, and
        // pressing the key again already flips them back).
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
            if AXFocus.kind() == .editable {
                // AX has THREE possible answers here, not two, and they
                // are not interchangeable:
                //
                //  - Matches → confirmed, undo.
                //  - A DIFFERENT string → confirmed WRONG. This is
                //    positive proof the caret or the text moved (a
                //    focus change with no keystroke: a timer-driven UI
                //    update, JS moving focus in a web view, another
                //    automation tool's own AX call), and it must veto
                //    outright — falling back to the generation counter
                //    here would let a definite "no" be overruled by a
                //    heuristic that only proves "no keystroke", not
                //    "the caret didn't move".
                //  - No answer (nil) → AX can't help either way, which
                //    is Telegram, Slack, Electron and most web editors,
                //    exactly where this feature earns its keep. THIS is
                //    the one case the generation counter is for: the
                //    tap sees every keystroke on the machine regardless
                //    of which app is in front, so it can stand in for
                //    AX being silent — never for AX being wrong.
                switch AXFocus.textBeforeCaret(count: record.replacementText.utf16.count) {
                case record.replacementText:
                    performUndo(record)
                    return
                case .some:
                    break   // definite mismatch — no generation fallback
                case nil:
                    if LayoutFixUndo.generationAllowsUndo(
                        recorded: record.generation,
                        current: LayoutAutoFix.buffer.generation
                    ) {
                        performUndo(record)
                        return
                    }
                }
            }
            // Not editable text, AX disagreed, or real typing happened
            // since the fix — either way this key press is not an undo
            // any more. Falls through to the ordinary fix-key behaviour
            // below.
            LayoutFixUndo.shared.clear()
        }

        // 1. A selection, if there is one.
        let borrow = PasteboardProxy.shared.borrow()
        if let selection = await PasteboardProxy.shared.copySelection(borrow) {
            guard let fix = LayoutFix.deliberate(selection) else {
                PasteboardProxy.shared.giveBack(borrow)
                ToastCenter.shared.show(
                    String(localized: "That already looks like the layout you meant."),
                    style: .info
                )
                return
            }
            PasteboardProxy.shared.pasteAndReturn(fix.text, borrow)
            finish(with: fix, settings: settings)
            return
        }
        PasteboardProxy.shared.giveBack(borrow)

        // 2. No selection — the word in flight, if anyone is watching.
        //    That path types the correction itself, switches the source
        //    and counts the fix, so there is nothing to finish here.
        if LayoutAutoFix.shared.fixWordInFlight() != nil { return }

        // Two different truths, not one. With the watcher running the
        // key really can fix the word in flight — there just wasn't
        // one. With the watcher OFF the key can only ever fix a
        // selection, because the word-in-flight buffer lives inside the
        // tap — so say WHY, instead of leaving the user to discover
        // that half the key is dead.
        ToastCenter.shared.show(
            LayoutAutoFix.shared.isRunning
                ? String(localized: "Nothing to fix — select the text, or type a word first.")
                : String(localized: "Select the text you want fixed — without automatic fixing, Daisy doesn't see the word you just typed."),
            style: .warning
        )
    }

    /// Shared tail: switch the input source if asked, count the fix, and
    /// say what happened. Switching is the difference between fixing one
    /// word and fixing the sentence — without it the next word goes
    /// wrong the same way.
    private func finish(with fix: LayoutFix.Fix, settings: AppSettings) {
        if settings.layoutFixSwitchesSource {
            KeyboardLayouts.shared.select(fix.target)
        }
        UsageStats.shared.recordFixes(polished: 1)
        log.info("Layout fix → \(fix.target.id, privacy: .public)")
    }

    /// Delete the fix's output and retype what the person actually
    /// typed — one keypress to reverse an automatic correction they
    /// didn't want, and a lesson `LayoutFixExceptions` remembers so it
    /// doesn't happen again on the same word.
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
        LayoutFixExceptions.shared.add(record.originalWord)
        // Second press in a row is ordinary key work, not an undo of
        // the undo.
        LayoutFixUndo.shared.clear()
        log.info("Layout fix undone")
        ToastCenter.shared.show(
            String(localized: "Undone — Daisy won't auto-fix that word again."),
            style: .info
        )
    }
}
