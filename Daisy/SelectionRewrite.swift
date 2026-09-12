//
//  SelectionRewrite.swift
//  Daisy
//
//  "Rewrite selection in my voice" — a global hotkey that grabs the
//  selected text in ANY app (simulated ⌘C), rewrites it through the
//  user's Voice Profile on the selected summary provider, and pastes the
//  result back over the selection (simulated ⌘V). Fully local when the
//  provider is local. Goldfish-style act-anywhere, but scoped to an
//  explicit selection + hotkey — no ambient capture.
//
//  Flow (all on MainActor):
//    1. Preconditions: Voice Profile exists, Accessibility granted.
//    2. Borrow the clipboard, read the selection through it.
//    3. Rewrite with the polish prompt under a hard deadline.
//    4. Paste the result back and return the clipboard.
//  Any failure gives the clipboard back and toasts — never leaves the
//  user with a trampled pasteboard.
//
//  The clipboard dance itself lives in `PasteboardProxy` (2026-07-30):
//  the layout fixer needs the same steps, and two features with their
//  own restore timers racing over one pasteboard is a bug that only
//  appears when someone uses both within a second and a half.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

@MainActor
final class SelectionRewrite {
    static let shared = SelectionRewrite()

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "SelectionRewrite")

    /// Provider deadline. A selection can be a whole email, and unlike a
    /// dictation nobody is standing there waiting for a paste — the
    /// person chose to wait when they hit the hotkey.
    private static let rewriteDeadlineSeconds: Double = 15
    /// Re-entrancy guard — a second hotkey press while a rewrite is in
    /// flight is ignored (the first one owns the clipboard).
    private var isRunning = false

    private init() {}

    // MARK: - Entry

    func trigger() async {
        guard !isRunning else { return }

        // Precondition 1: a voice profile to rewrite WITH. (Which one is
        // decided further down, once the selection is in hand and its
        // language is known — this only checks that any exists.)
        guard VoiceProfileStore.shared.hasProfile else {
            ToastCenter.shared.show(
                String(localized: "Generate your style profile first — open My style in the sidebar."),
                style: .warning
            )
            return
        }
        // Precondition 2: Accessibility (we synthesize ⌘C/⌘V).
        if !AXIsProcessTrusted() {
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            ToastCenter.shared.show(
                String(localized: "Rewriting needs Accessibility access — grant it in System Settings and try again."),
                style: .warning
            )
            return
        }

        isRunning = true
        defer { isRunning = false }

        // 2. Borrow the clipboard, then copy the selection through it.
        let borrow = PasteboardProxy.shared.borrow()
        guard let selection = await PasteboardProxy.shared.copySelection(borrow) else {
            PasteboardProxy.shared.giveBack(borrow)
            ToastCenter.shared.show(
                String(localized: "Select some text first, then press the rewrite shortcut."),
                style: .warning
            )
            return
        }

        // 3. Pick the profile by the language of the SELECTION — this is
        // the path most likely to cross languages (an English email
        // rewritten by someone whose corpus is Russian), and a selection
        // is usually long enough for the detector to be sure.
        let style = VoiceProfileStore.shared.resolveStyle(
            forTextIn: LanguageDetector.detect(selection)
        )
        guard let style else {
            PasteboardProxy.shared.giveBack(borrow)
            ToastCenter.shared.show(
                String(localized: "Generate your style profile first — open My style in the sidebar."),
                style: .warning
            )
            return
        }
        if style.isCrossLanguage {
            VoiceProfileStore.shared.noteCrossLanguagePolish(target: style.targetLanguage)
        }

        // 4. Rewrite under a deadline (never hang the user's flow).
        ToastCenter.shared.show(String(localized: "Rewriting in your voice…"), style: .info)
        let rewritten = await RecordingSession.polishWithDeadline(
            text: selection,
            instruction: style.promptInstruction,
            seconds: Self.rewriteDeadlineSeconds
        )
        guard let rewritten, !rewritten.isEmpty else {
            PasteboardProxy.shared.giveBack(borrow)
            ToastCenter.shared.show(
                String(localized: "Couldn’t rewrite that — check your summary provider in Settings."),
                style: .error
            )
            return
        }

        // Feed the "fixes made by Daisy" widget (words the rewrite changed).
        let before = selection.split(whereSeparator: { $0.isWhitespace })
        let after = rewritten.split(whereSeparator: { $0.isWhitespace })
        UsageStats.shared.recordFixes(polished: after.difference(from: before).insertions.count)

        // 5. Paste the result over the (still-active) selection; the
        //    proxy gives the user's clipboard back a beat later.
        PasteboardProxy.shared.pasteAndReturn(rewritten, borrow)

        // 6. Auto-suggest (Egor 2026-07-25): the rewrite just restored a
        //    Latin brand name we don't cover — not in the built-in table,
        //    not in the user's rules. Offer to save it as a permanent
        //    Vocabulary correction, after which it works on every engine
        //    with no rewrite in the loop. This used to hang off the
        //    always-on dictation polish; with that gone (2026-09-12) the
        //    hotkey is the only place an original and its rewrite meet.
        //
        //    ONE toast either way. ToastCenter is single-slot, so a
        //    success toast followed by a suggestion toast would just be
        //    the suggestion — the person would never see that their
        //    clipboard is coming back. When there is something to
        //    suggest, the suggestion carries the success line with it.
        let triggers = Set(
            DictationDictionary.shared.replacements.map { $0.from.lowercased() }
        )
        if let pair = BrandCorrections.suggestRestoredBrand(
            original: selection, polished: rewritten, userTriggers: triggers
        ) {
            ToastCenter.shared.showAction(
                String(localized: "Rewritten in your voice. Noticed “\(pair.from)” → “\(pair.to)” — save as a dictation correction?"),
                actionLabel: String(localized: "Save"),
                style: .success
            ) {
                DictationDictionary.shared.add(
                    DictationReplacement(kind: .correction, from: pair.from, to: pair.to)
                )
            }
        } else {
            ToastCenter.shared.show(
                String(localized: "Rewritten in your voice — your clipboard is coming right back."),
                style: .success
            )
        }
    }

}
