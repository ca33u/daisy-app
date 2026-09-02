//
//  DictationPaste.swift
//  Daisy
//
//  Glue between dictation-mode end-of-recording and the user's
//  active text field. Three jobs:
//
//   1. Save the current clipboard contents (text + any other
//      pasteboard types) before we trample them.
//   2. Write the transcript and (if Accessibility permission is
//      granted) simulate ⌘V so the text lands in whatever field
//      the user has focused — true "Wispr Flow parity". When
//      permission is missing or the user denies, fall back to a
//      toast prompting manual ⌘V.
//   3. After a 10 s grace window, restore the previous clipboard
//      so the user's existing copy/paste state isn't permanently
//      clobbered by a one-off dictation. Skipped if the user has
//      already copied something else (detected via the pasteboard
//      change counter) or dictated again (cancellable timer).
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// Singleton coordinator for the dictation paste flow.
///
/// `@MainActor` because every operation touches `NSPasteboard`,
/// `NSWorkspace`, and our shared `ToastCenter`. Held by
/// `RecordingSession` (via shared instance) so the 10 s restore
/// timer survives across the brief window where Daisy might
/// release its session reference and pick a new one up.
@MainActor
final class DictationPaste {
    static let shared = DictationPaste()

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "DictationPaste")

    /// Snapshot of the items in the pasteboard at the moment we
    /// started writing the transcript. Restored 10 s later if
    /// nothing else has been copied in the meantime.
    private struct ClipboardSnapshot: Sendable {
        let items: [[String: Data]]    // [type-string → raw data]
        let changeCountAfterOurWrite: Int
    }

    private var pendingSnapshot: ClipboardSnapshot?
    private var restoreTimer: Timer?

    /// Total seconds the transcript stays on the clipboard before
    /// we (optionally) restore the previous contents. Long enough
    /// that the user can switch apps, find the right field, and
    /// hit ⌘V without rushing. Short enough that the previous
    /// clipboard isn't permanently lost.
    static let retentionSeconds: TimeInterval = 10

    /// Restore delay when the AUTO-paste succeeded: the ⌘V has already
    /// landed, so the transcript only needs to survive in the pasteboard
    /// long enough for the frontmost app to service the keystroke. Short
    /// on purpose — the user's prior clipboard (logs, a link, …) comes
    /// back almost immediately instead of being held hostage for 10 s
    /// (Egor, 2026-07-14: "надиктовал команду → иду вставлять логи, а их
    /// уже нет").
    static let quickRestoreSeconds: TimeInterval = 1.5

    private init() {}

    // MARK: - Public entry

    /// Run the full post-dictation flow:
    ///   1. Snapshot current clipboard
    ///   2. Write transcript
    ///   3. Try auto-paste via simulated ⌘V (needs Accessibility)
    ///   4. Schedule restore-previous-clipboard in 10 s
    ///
    /// `transcript` is trimmed by the caller — pass empty string
    /// to skip clipboard work entirely (still shows a "nothing
    /// transcribed" toast).
    /// Corrections + bookkeeping that every dictation gets, whatever it
    /// lands in: the user's vocabulary, the built-in brand layer, the
    /// fixes counter, the 24-hour history and the voice-profile corpus.
    ///
    /// Extracted from `handle` (2026-08-12) because dictation now has a
    /// second destination — a screenshot note (see
    /// `ScreenshotNoteCapture`). Routing around `handle` used to mean
    /// routing around ALL of this: the note would have stored raw text
    /// with brand names still transliterated, and the dictation wouldn't
    /// have counted toward the voice-profile unlock.
    ///
    /// `corpusText` splits ONE of those apart: what gets pasted and what
    /// the voice profile learns from are the same text everywhere except
    /// on the polish path, where `finishDictation` has already rewritten
    /// `input` in the user's own (previous) profile. Feeding that back in
    /// makes the profile learn from the model's taste rather than the
    /// person's — invisible today, fatal for anything that measures
    /// filler words, since the polish prompt removes them by name. Pass
    /// the RAW transcript here; leave it nil when no polish happened.
    /// Do not collapse this fork back into one argument.
    @discardableResult
    func prepare(_ input: String, corpusText: String? = nil) -> String {
        var transcript = input
        var dictionaryFixes: Int
        (transcript, dictionaryFixes) = DictationDictionary.shared.applyCounting(to: transcript)
        // Built-in brand layer AFTER the user's rules (Egor 2026-07-25):
        // restore transliterated product names to Latin («фигма» →
        // Figma) on every engine — Parakeet can't be biased, so this is
        // its only route to correct brand spelling. User rules stay
        // authoritative: applied first above, and BrandCorrections
        // additionally skips any entry whose stem collides with a user
        // trigger. Gated by Settings → Transcription → Fix product
        // names (default ON).
        if UserDefaults.standard.object(forKey: BrandCorrections.defaultsKey) as? Bool ?? true {
            let triggers = Set(
                DictationDictionary.shared.replacements.map { $0.from.lowercased() }
            )
            let brand = BrandCorrections.apply(to: transcript, userTriggers: triggers)
            transcript = brand.text
            dictionaryFixes += brand.fixes
        }
        // Feed the Home "fixes made by Daisy" widget.
        UsageStats.shared.recordFixes(dictionary: dictionaryFixes)

        // Log the final, about-to-be-pasted text to the rolling 24-hour
        // dictation history so the user can glance back / re-copy it later.
        // Placed AFTER `apply(to:)` so the record matches exactly what
        // lands in the user's field (dictionary already applied). Like
        // `DictationDictionary`, `DictationHistory` is `@MainActor` and
        // we're already on the MainActor here, so this is a plain
        // synchronous same-actor call — no await, no hop. `record` ignores
        // empty/whitespace-only input, so a stray blank transcript that
        // slips past the early guard above still won't pollute the log.
        DictationHistory.shared.record(transcript)

        // Grow the persistent voice-profile corpus (Wispr-style: the
        // profile unlocks once enough real dictation has accumulated).
        // Placed before the AX/clipboard fork so every successful
        // dictation counts regardless of how it lands in the field.
        //
        // The corpus still gets the user's own vocabulary and the brand
        // layer — those are spelling, and "Figma" is how this person
        // writes it. What it must NOT get is the LLM polish, which is
        // style: hence the raw text in, corrections re-applied here.
        var forCorpus = transcript
        if let corpusText {
            forCorpus = DictationDictionary.shared.apply(to: corpusText)
            if UserDefaults.standard.object(forKey: BrandCorrections.defaultsKey) as? Bool ?? true {
                let triggers = Set(
                    DictationDictionary.shared.replacements.map { $0.from.lowercased() }
                )
                forCorpus = BrandCorrections.apply(to: forCorpus, userTriggers: triggers).text
            }
        }
        VoiceProfileStore.shared.appendDictation(forCorpus)
        return transcript
    }

    func handle(transcript: String, corpusText: String? = nil) {
        guard !transcript.isEmpty else {
            // Say WHY when we know why (2026-07-26). "Nothing was
            // transcribed" after a full-volume dictation reads like the
            // app is broken; if the mic delivered digital silence the
            // user needs to go to System Settings, not retry.
            if RecordingSession.current?.recorder.sawDigitalSilence == true {
                ToastCenter.shared.showAction(
                    String(localized: "Nothing was recorded — macOS sent Daisy an empty microphone signal. Check Privacy & Security → Microphone."),
                    actionLabel: String(localized: "Open Microphone settings"),
                    style: .warning,
                    duration: .seconds(30)
                ) {
                    SystemPermissions.shared.openMicrophoneSettings()
                }
            } else {
                ToastCenter.shared.show(
                    String(localized: "Dictation stopped — nothing was transcribed."),
                    style: .warning
                )
            }
            return
        }

        // `prepare` applies the user's vocabulary + brand corrections and
        // does the once-per-dictation bookkeeping (fixes counter, 24h
        // history, voice-profile corpus); `deliver` puts the result where
        // the caret is. Both are MainActor-isolated same-actor calls.
        deliver(prepare(transcript, corpusText: corpusText), context: .freshDictation)
    }

    /// Where a `deliver` call came from — only a FRESH dictation shows
    /// the "landed nowhere" bubble. A re-paste that lands nowhere needs
    /// no prompt: the user explicitly asked to paste and can just ask
    /// again.
    private enum DeliveryContext { case freshDictation, repaste }

    /// Re-paste the most recent dictation at the current caret — Wispr's
    /// "paste last transcript". The words a dictation put nowhere (no
    /// field focused, ⌘V landed in the void) are still in
    /// `DictationHistory`; this hands the newest one back to the same
    /// delivery path, at wherever the caret is NOW.
    ///
    /// Skips `prepare`: the history already holds post-correction text
    /// that was counted, logged and fed to the voice profile once. Re-
    /// pasting is not a new dictation — running it through `prepare`
    /// again would double-count fixes and re-grow the profile corpus
    /// from the same words.
    func repasteLast() {
        guard let last = DictationHistory.shared.entries.first,
              !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ToastCenter.shared.show(
                String(localized: "No recent dictation to paste."),
                style: .info
            )
            return
        }
        deliver(last.text, context: .repaste)
    }

    /// Put `transcript` where the caret is: straight into the focused
    /// field via Accessibility when we can, else onto the clipboard with
    /// an auto-paste and a timed restore of the user's prior clipboard.
    /// Assumes the text is already corrected — callers that start from a
    /// raw dictation run `prepare` first.
    private func deliver(_ transcript: String, context: DeliveryContext) {
        // 0. Best path: insert DIRECTLY into the focused text field via
        //    the Accessibility API — the pasteboard is never touched, so
        //    whatever the user had copied (logs, a link…) survives
        //    untouched. Works in most native apps; web views / Electron
        //    and secure fields often refuse, in which case we fall through
        //    to the clipboard route below.
        let axOutcome = attemptAXInsert(transcript)
        if axOutcome == .inserted {
            ToastCenter.shared.show(
                String(localized: "Dictation inserted — clipboard untouched."),
                style: .success
            )
            return
        }

        // 1. Snapshot the user's real prior clipboard, BEFORE we write.
        //
        //    Back-to-back clipboard-route deliveries (a dictation that
        //    landed nowhere, then a re-paste; or two re-pastes) need care:
        //    the pasteboard right now may still hold OUR previous
        //    transcript, with a restore pending. Snapshotting it blindly
        //    would capture that transcript as "the user's clipboard" and
        //    lose their genuine pre-dictation contents forever. So if a
        //    restore is pending AND nothing has touched the pasteboard
        //    since our last write (changeCount unchanged), carry the
        //    ORIGINAL snapshot forward instead of re-capturing.
        let snapshot: [[String: Data]]
        if let pending = pendingSnapshot,
           NSPasteboard.general.changeCount == pending.changeCountAfterOurWrite {
            snapshot = pending.items
        } else {
            snapshot = captureClipboard()
        }
        cancelPendingRestore()

        // 2. Write the transcript.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
        let postWriteChangeCount = NSPasteboard.general.changeCount

        // 3. Try to auto-paste. If Accessibility permission is
        //    missing, fall back to the manual-paste toast.
        let autoPaste = attemptAutoPaste()
        let didAutoPaste = (autoPaste == .pasted)
        // 4. Schedule restore. Auto-paste already landed → the transcript
        //    only needs to outlive the keystroke (quick restore, prior
        //    clipboard back in ~1.5 s). Manual-paste fallback → the
        //    transcript must stay around long enough to ⌘V by hand.
        let restoreAfter = didAutoPaste ? Self.quickRestoreSeconds : Self.retentionSeconds
        switch autoPaste {
        case .pasted:
            ToastCenter.shared.show(
                String(localized: "Dictation pasted — your previous clipboard is coming right back."),
                style: .success
            )
        case .needsAccessibility:
            // Not a success, and not a mystery either: name the missing
            // permission and offer the pane. Announced as success, this
            // is how a person concludes that manual ⌘V is simply how
            // Daisy works.
            ToastCenter.shared.showAction(
                String(localized: "Daisy can't paste for you without Accessibility access — the text is on your clipboard, press ⌘V. Reverts in \(Int(Self.retentionSeconds))s."),
                actionLabel: String(localized: "Open Accessibility settings"),
                style: .warning,
                // Never outlive the clipboard it points at: the toast
                // says "press ⌘V", and after `retentionSeconds` the
                // previous clipboard is back, so a later ⌘V would paste
                // the wrong thing.
                duration: .seconds(Self.retentionSeconds)
            ) {
                SystemPermissions.shared.openAccessibilitySettings()
            }
        case .failed:
            ToastCenter.shared.show(
                String(localized: "Dictation copied — press ⌘V to paste. Clipboard reverts in \(Int(Self.retentionSeconds))s."),
                style: .warning
            )
        }

        pendingSnapshot = ClipboardSnapshot(
            items: snapshot,
            changeCountAfterOurWrite: postWriteChangeCount
        )
        restoreTimer = Timer.scheduledTimer(
            withTimeInterval: restoreAfter,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restoreClipboardIfUnchanged()
            }
        }

        // Dictated into the void: no field had focus, so the ⌘V landed
        // nowhere and the clipboard is about to revert. Surface a bubble
        // from the widget (Wispr's "copy last transcript") offering to
        // keep the text — only for a fresh dictation, and only when we're
        // sure there was no target.
        //
        // `.refused` means a field exists but won't take an AX write; ⌘V
        // almost certainly reached it, so no prompt there. And
        // `.noFocusedField` LIES in Chromium/Electron apps — they don't
        // build an AX focus tree without AXManualAccessibility, so Claude
        // / Slack / Notion always look focus-less even though ⌘V lands
        // fine (see the Electron-AX class of bug). So additionally
        // require that nothing app-like is in front: only the desktop
        // (Finder), Daisy itself, or no frontmost app is a true "nowhere".
        if context == .freshDictation, axOutcome == .noFocusedField,
           Self.frontmostIsVoid() {
            let text = transcript
            // With the re-paste hotkey bound, the recovery is one
            // keypress away — the pill just names it. Without it, fall
            // back to the question + Copy button.
            if let label = Self.repasteHotkeyLabel() {
                WidgetBubbleCenter.shared.present(
                    WidgetBubbleContent(
                        text: String(
                            format: String(localized: "Paste the text: %@"),
                            label
                        )
                    ),
                    notificationTitle: String(localized: "Dictation saved"),
                    notificationBody: String(
                        format: String(localized: "Paste the text: %@"),
                        label
                    )
                )
                return
            }
            WidgetBubbleCenter.shared.present(
                WidgetBubbleContent(
                    text: String(localized: "Dictation had nowhere to land. Keep it?"),
                    actionTitle: String(localized: "Copy"),
                    action: { [weak self] in
                        // Re-write it fresh (the restore may already have
                        // fired) and cancel any pending revert so it stays.
                        self?.cancelPendingRestore()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        ToastCenter.shared.show(
                            String(localized: "Copied — ⌘V to paste."),
                            style: .success
                        )
                    }
                ),
                notificationTitle: String(localized: "Dictation saved"),
                // No Copy button on a banner — point at the durable
                // recovery instead of asking a question it can't answer.
                notificationBody: String(localized: "It's in your dictation history — use “Paste my last dictation” to place it.")
            )
        }
    }

    /// Outcome of the direct-insert attempt. The three cases drive
    /// different follow-ups: `.inserted` is done; `.refused` means there
    /// IS a focused field but it won't take a programmatic write (web
    /// views, Electron, secure fields), so clipboard + ⌘V will still land
    /// there; `.noFocusedField` means nothing had keyboard focus, so ⌘V
    /// lands nowhere — the "dictated into the void" case the widget
    /// bubble exists to catch.
    private enum AXInsertOutcome { case inserted, refused, noFocusedField }

    /// Label of the bound "paste my last dictation" hotkey, or nil when
    /// none is set. Read straight from defaults (same key `AppSettings`
    /// persists to) — this singleton has no settings reference and the
    /// one call site doesn't justify plumbing one through.
    private static func repasteHotkeyLabel() -> String? {
        guard let data = UserDefaults.standard.data(forKey: "daisy.repasteLastHotkey"),
              let choice = try? JSONDecoder().decode(HotkeyChoice.self, from: data),
              choice != .none else { return nil }
        return choice.label
    }

    /// True when nothing that could have received a paste is in front:
    /// the desktop (Finder), Daisy itself, or no frontmost app. Used to
    /// keep the "landed nowhere" bubble from firing in Electron apps,
    /// whose missing AX focus tree reads as `.noFocusedField` even though
    /// the ⌘V pasted fine.
    private static func frontmostIsVoid() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let id = front.bundleIdentifier else { return true }
        return id == "com.apple.finder" || id == Bundle.main.bundleIdentifier
    }

    /// Insert `text` at the caret of the system-wide focused UI element
    /// (replacing any selection) via the Accessibility API — no
    /// pasteboard involvement at all.
    private func attemptAXInsert(_ text: String) -> AXInsertOutcome {
        // Permission missing → we can't tell whether a field is focused,
        // so don't claim "nowhere"; take the clipboard path and let
        // `attemptAutoPaste` prompt for Accessibility as it always has.
        guard AXIsProcessTrusted() else { return .refused }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else { return .noFocusedField }
        // AXUIElement is a CoreFoundation type — an unconditional
        // downcast from CFTypeRef is the sanctioned bridge.
        let element = focusedRef as! AXUIElement

        // Only proceed when the element explicitly supports setting the
        // selected text — writing blindly can beep or mangle state in
        // apps that expose the attribute read-only.
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else { return .refused }

        // Read the field's value BEFORE the write so we can tell whether
        // the write actually took. On macOS 27 Claude (Electron) and
        // Facebook (web) began exposing a settable `AXSelectedText`, so
        // this path is now REACHED for them — but the write is a no-op:
        // `AXUIElementSetAttributeValue` returns `.success` and the DOM
        // input never changes. Trusting that success dropped the text on
        // the floor AND left the clipboard untouched, so ⌘V couldn't even
        // recover it. (Field report, 1.0.7.55, 2026-08-13.)
        let before = Self.axStringValue(of: element)

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        guard result == .success else { return .refused }

        // Verify by value change, and LOG which branch we took — the
        // next field report must be able to say, unambiguously, whether
        // this engaged in Claude / Facebook or slipped through:
        //   • readable + changed   → verified insert, trust it.
        //   • readable + unchanged → the web/Electron no-op → refuse, so
        //                            the caller falls back to clipboard.
        //   • unreadable           → can't disprove success; keep the old
        //                            trust rather than regress native
        //                            fields that expose no AXValue. If a
        //                            report shows THIS branch for a field
        //                            that lost text, the next lever is to
        //                            force clipboard for web/Electron.
        let after = Self.axStringValue(of: element)
        if let before, let after {
            if after == before, !text.isEmpty {
                log.warning("AX write reported success but the field is unchanged — clipboard + ⌘V fallback (web/Electron no-op)")
                return .refused
            }
            log.info("Dictation inserted via AX (verified by value change) — clipboard untouched")
            return .inserted
        }
        log.info("Dictation inserted via AX (unverified — field exposes no readable value) — clipboard untouched")
        return .inserted
    }

    /// Best-effort read of an element's text value, for the write-took-
    /// effect check. `nil` when the element doesn't expose a string
    /// `AXValue` (which the caller treats as "can't verify", not
    /// "failed").
    private static func axStringValue(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &ref
        ) == .success else { return nil }
        return ref as? String
    }

    // MARK: - Auto-paste

    /// Synthesise a ⌘V keystroke against the current frontmost
    /// app. Returns `true` on success, `false` when Accessibility
    /// permission is denied (the keystroke would post to nowhere)
    /// or when CGEvent construction fails.
    ///
    /// Two-phase permission check:
    ///   1. Silent check via `AXIsProcessTrusted()` — no prompt.
    ///   2. Prompt only if step 1 returns false. The system
    ///      dialog appears AND we return false (permission
    ///      doesn't become true mid-call). Next dictation will
    ///      see step 1 succeed and auto-paste will work.
    ///
    /// First-dictation UX: the very first dictation pastes
    /// nothing because Accessibility wasn't granted yet, but the
    /// user now has the system dialog open and can grant. Second
    /// dictation works. The 10s clipboard hold means even the
    /// failed first attempt is recoverable via manual ⌘V.
    ///
    /// Returns WHICH failure, not just that there was one: the caller
    /// used to announce every outcome as a success ("Dictation copied —
    /// press ⌘V"), so someone whose Accessibility grant was missing (or
    /// reset by an OS update) concluded that manual ⌘V is simply how
    /// Daisy works, and lived with it (audit 2026-09-01).
    private func attemptAutoPaste() -> AutoPasteOutcome {
        // Silent check first — avoids re-showing the system dialog
        // on every call when permission is granted.
        if !AXIsProcessTrusted() {
            // Permission missing — prompt once (system dedups the
            // dialog if user already saw it), but report the miss
            // because the dialog is non-modal and we'd be racing
            // against the user's click.
            let promptOption = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options: NSDictionary = [promptOption: true]
            _ = AXIsProcessTrustedWithOptions(options)
            log.warning("Accessibility permission missing — prompted user, falling back to manual ⌘V for this dictation")
            return .needsAccessibility
        }

        // Build a ⌘ down + V down + V up + ⌘ up sequence and post
        // it to the session-wide event tap. macOS dispatches it
        // to whichever app has frontmost focus.
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            log.error("Couldn't create CGEventSource for paste keystroke")
            return .failed
        }

        let vKeyCode = CGKeyCode(kVK_ANSI_V)
        let cmdKeyCode = CGKeyCode(kVK_Command)

        guard
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: true),
            let vDown   = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let vUp     = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false),
            let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: false)
        else {
            log.error("CGEvent construction returned nil")
            return .failed
        }

        // V events need the Command flag set so apps see them as
        // ⌘V (paste) rather than a plain "v" character.
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        // Brief settle delay BEFORE posting — when the user
        // releases the hotkey, focus may not have fully resolved
        // to their text-field-of-choice yet (the OS posts our
        // keyUp event last, after which it can briefly re-rank
        // app activation). 80 ms is well below "noticeable lag"
        // (the eye misses anything under ~100 ms) but plenty
        // for the focus chain to settle.
        //
        // Empirically without this delay, pasting into Claude
        // desktop / Cursor / VS Code sometimes lands in the
        // wrong window (or nowhere) because they re-render
        // their input field state on focus-acquired.
        Thread.sleep(forTimeInterval: 0.08)

        // 2026-05-27 — bundleIdentifier is `.private`. Not strictly
        // PII but a precise fingerprint of which apps the user
        // dictates into; not something we want in the public unified
        // log stream long-term.
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "<unknown>"
        log.info("Posting ⌘V — frontmost app: \(frontmostBefore, privacy: .private)")

        let tap = CGEventTapLocation.cgSessionEventTap
        cmdDown.post(tap: tap)
        vDown.post(tap: tap)
        vUp.post(tap: tap)
        cmdUp.post(tap: tap)
        return .pasted
    }

    /// Why the automatic ⌘V did or didn't happen. `.needsAccessibility`
    /// is separated from `.failed` because only it has an action the
    /// person can take.
    private enum AutoPasteOutcome {
        case pasted
        case needsAccessibility
        case failed
    }

    // MARK: - Snapshot + restore

    /// Capture every pasteboard type the user currently has so
    /// we can put it all back later. Covers plain text, RTF, file
    /// URLs, images, anything custom an app dropped on the
    /// pasteboard.
    private func captureClipboard() -> [[String: Data]] {
        guard let items = NSPasteboard.general.pasteboardItems else {
            return []
        }
        return items.map { item in
            var typeMap: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typeMap[type.rawValue] = data
                }
            }
            return typeMap
        }
    }

    /// Put the captured items back on the pasteboard IF the user
    /// hasn't copied anything else in the meantime. The pasteboard
    /// changeCount monotonically increases on every write — we
    /// recorded the count right after writing the transcript, and
    /// if it's still that number now, nothing else has touched
    /// the pasteboard.
    private func restoreClipboardIfUnchanged() {
        defer {
            pendingSnapshot = nil
            restoreTimer = nil
        }
        guard let snapshot = pendingSnapshot else { return }
        let currentCount = NSPasteboard.general.changeCount
        if currentCount != snapshot.changeCountAfterOurWrite {
            log.info("Pasteboard changed during retention window — skipping restore (\(currentCount, privacy: .public) vs \(snapshot.changeCountAfterOurWrite, privacy: .public))")
            return
        }
        NSPasteboard.general.clearContents()
        if snapshot.items.isEmpty {
            log.info("Restored empty pasteboard (no prior contents)")
            return
        }
        let nsItems: [NSPasteboardItem] = snapshot.items.map { typeMap in
            let item = NSPasteboardItem()
            for (typeString, data) in typeMap {
                item.setData(data, forType: NSPasteboard.PasteboardType(typeString))
            }
            return item
        }
        NSPasteboard.general.writeObjects(nsItems)
        log.info("Restored pasteboard with \(nsItems.count, privacy: .public) item(s) after dictation grace window")
    }

    /// Cancel any pending restore — used when a NEW dictation
    /// happens before the previous one's 10 s window expired.
    /// The new transcript stays in clipboard, the new restore
    /// timer runs against the NEW snapshot.
    private func cancelPendingRestore() {
        restoreTimer?.invalidate()
        restoreTimer = nil
        pendingSnapshot = nil
    }
}
