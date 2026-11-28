// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  DictationPaste.swift
//  Daisy
//
//  Glue between dictation-mode end-of-recording and the user's
//  active text field. Three jobs:
//
//   0. Insert straight into the focused field via Accessibility, or —
//      when the field refuses (web views, Electron) — TYPE the text as
//      synthetic key events. Neither touches the clipboard. This is the
//      normal path (2026-09-18: "if I have something copied, dictation
//      must not replace it" — Egor).
//   1. Only when neither is possible (no Accessibility permission, or the
//      person opted into the clipboard route for an app that autocompletes
//      as you type): save the current clipboard contents (text + any
//      other pasteboard types) before we trample them.
//   2. Write the transcript and simulate ⌘V so the text lands in whatever
//      field the user has focused. When permission is missing, fall back
//      to a toast prompting manual ⌘V.
//   3. After a grace window (4 s when Daisy pasted, 10 s when the person
//      is asked to), restore the previous clipboard
//      so the user's existing copy/paste state isn't permanently
//      clobbered by a one-off dictation. Skipped if the user has
//      already copied something else (detected via the pasteboard
//      change counter) or dictated again (cancellable timer). Sooner
//      than that when the person presses ⌘V themselves
//      (`ClipboardReturnWatch`).
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
    private var returnWatch: UUID?

    /// Total seconds the transcript stays on the clipboard before
    /// we (optionally) restore the previous contents. Long enough
    /// that the user can switch apps, find the right field, and
    /// hit ⌘V without rushing. Short enough that the previous
    /// clipboard isn't permanently lost.
    static let retentionSeconds: TimeInterval = 10

    /// Restore delay when the AUTO-paste succeeded: the ⌘V has already
    /// been POSTED, so the transcript only needs to survive in the
    /// pasteboard long enough for the frontmost app to service the
    /// keystroke. Short on purpose — the user's prior clipboard (logs, a
    /// link, …) comes back quickly instead of being held hostage for
    /// 10 s (Egor, 2026-07-14: "надиктовал команду → иду вставлять логи,
    /// а их уже нет").
    ///
    /// 4 s, not the original 1.5. `attemptAutoPaste` posts CGEvents and
    /// returns immediately; delivery is asynchronous, and an app that
    /// takes longer than this to handle the keystroke — Electron waking
    /// up, a heavy page, an IDE under load — pastes whatever is on the
    /// pasteboard by then. Restoring too early doesn't just lose the
    /// dictation: it puts the person's PREVIOUS clipboard into the
    /// field, which can be a password manager's payload. The failure is
    /// asymmetric, so the delay errs on the side of holding our own text
    /// a little longer (audit 2026-09-01).
    static let quickRestoreSeconds: TimeInterval = 4

    /// The first-run tour's practice field (`OnboardingTourController`).
    /// While set and Daisy is in front, a fresh dictation lands there
    /// instead of at the system's focused element — no Accessibility
    /// needed, which the tour asks for only later. Returning false falls
    /// back to the usual delivery.
    var practiceSink: ((String) -> Bool)?
    /// The tour's style step: the person reads a given passage, which is
    /// not their style — while Daisy is in front it stays out of the
    /// voice-profile corpus (history and corrections as usual).
    var practiceKeepsOutOfCorpus = false

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
    /// fixes counter, the dictation history and the voice-profile corpus.
    ///
    /// Extracted from `handle` (2026-08-12) because dictation now has a
    /// second destination — a screenshot note (see
    /// `ScreenshotNoteCapture`). Routing around `handle` used to mean
    /// routing around ALL of this: the note would have stored raw text
    /// with brand names still transliterated, and the dictation wouldn't
    /// have counted toward the voice-profile unlock.
    ///
    /// What gets pasted and what the voice profile learns from were the
    /// same text from 2026-09-12, when the «in my voice» rewrite left this
    /// path, until 28.11.2026. Since then a dictation may be corrected by
    /// its context before it lands (`DictationCleanup`), and the two part
    /// again: the history gets what was pasted — it is what a re-paste
    /// puts back — and the corpus gets the text as it was BEFORE the
    /// model, so the profile learns the person's words and not a model's
    /// taste. `prepare` is all of it for a text no model touches;
    /// `DictationSteps` is the order of it for one that may be.
    @discardableResult
    func prepare(_ input: String) -> String {
        let transcript = correct(input)
        DictationHistory.shared.record(transcript)
        appendToCorpus(transcript)
        return transcript
    }

    /// The person's vocabulary and the built-in brand layer. `counting`
    /// false: nothing goes to the «fixes made by Daisy» count (the bench).
    func correct(_ input: String, counting: Bool = true) -> String {
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
            let brand = BrandCorrections.apply(to: transcript, userTriggers: brandTriggers())
            transcript = brand.text
            dictionaryFixes += brand.fixes
        }
        // Feed the Home "fixes made by Daisy" widget.
        if counting { UsageStats.shared.recordFixes(dictionary: dictionaryFixes) }
        return transcript
    }

    private func brandTriggers() -> Set<String> {
        Set(DictationDictionary.shared.replacements.map { $0.from.lowercased() })
    }

    /// The person's spellings put back into a text a model wrote from
    /// `corrected`: a model may write a term its own way, and the
    /// vocabulary has the last word. Not `correct` again — a rule that
    /// finds its needle in its own replacement («Jira → Jira Cloud») would
    /// apply to what it had already written (`DictationDictionary.respell`).
    /// The brand layer goes by the same rule: only if it leaves the text
    /// it has been through alone.
    func respell(_ cleaned: String, afterModelFrom corrected: String) -> String {
        var text = DictationDictionary.respell(cleaned, afterModelFrom: corrected,
                                               rules: DictationDictionary.shared.replacements)
        if UserDefaults.standard.object(forKey: BrandCorrections.defaultsKey) as? Bool ?? true {
            let triggers = brandTriggers()
            if BrandCorrections.apply(to: corrected, userTriggers: triggers).text == corrected {
                text = BrandCorrections.apply(to: text, userTriggers: triggers).text
            }
        }
        return text
    }

    /// Grow the persistent voice-profile corpus (Wispr-style: the
    /// profile unlocks once enough real dictation has accumulated).
    /// Every successful dictation counts regardless of how it lands in
    /// the field.
    ///
    /// The corpus gets the user's own vocabulary and the brand layer
    /// applied — those are spelling, and "Figma" is how this person
    /// writes it. Nothing else touches the text before it lands here,
    /// so the profile learns from the person's own words.
    private func appendToCorpus(_ text: String) {
        if !(practiceKeepsOutOfCorpus && NSApp.isActive) {
            VoiceProfileStore.shared.appendDictation(text)
        }
    }

    /// `micSawDigitalSilence` — the recorder of the session that held
    /// this dictation (`CoreAudioMicRecorder.sawDigitalSilence`). Passed
    /// in since 14.11: a dictation held over a live recording runs on a
    /// side session, and `RecordingSession.current` is the recording.
    func handle(transcript: String, micSawDigitalSilence: Bool) async {
        guard !transcript.isEmpty else {
            // Say WHY when we know why (2026-07-26). "Nothing was
            // transcribed" after a full-volume dictation reads like the
            // app is broken; if the mic delivered digital silence the
            // user needs to go to System Settings, not retry.
            if micSawDigitalSilence {
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
                    String(localized: "Didn’t hear anything"),
                    style: .warning
                )
            }
            return
        }

        // One after another, in the order they were said (`DictationOrder`).
        let steps = dictationSteps()
        await order.run { await steps.run(transcript) }
    }

    private let order = DictationOrder()

    /// The steps of a dictation with the app's own effects: the
    /// vocabulary, the history file, the voice-profile corpus, the cleanup
    /// and the field. All MainActor-isolated same-actor calls.
    private func dictationSteps() -> DictationSteps {
        DictationSteps(
            correct: { [self] in correct($0) },
            // The final, about-to-be-pasted text, so the user can glance
            // back / re-copy it later; `record` ignores a blank one.
            recordHistory: { DictationHistory.shared.record($0) },
            replaceHistory: { DictationHistory.shared.replace($0, with: $1) },
            appendCorpus: { [self] in appendToCorpus($0) },
            clean: { [self] in await cleanedByContext($0) },
            respell: { [self] in respell($0, afterModelFrom: $1) },
            // Feed the Home "fixes made by Daisy" widget.
            countCleanup: { UsageStats.shared.recordFixes(polished: 1) },
            deliver: { [self] text, moved in await deliver(text, context: .freshDictation, targetMoved: moved) },
            began: { [order] in order.began($0) },
            landed: { [order] in order.landed($0) })
    }

    // MARK: - Cleanup by context

    /// Whose dictation it is: the person's, or a line of the bench's file.
    enum CleanupMode {
        case dictation
        /// `DictationCleanupBench`: the same way a dictation goes, without
        /// what belongs to a person at a keyboard — the switch and the
        /// stored yes (the bench's flag is its yes), the field, the
        /// flower, the breaker. `route`: the provider and address the flag
        /// was given for; `terms`: the vocabulary words to send.
        case bench(route: DictationCleanup.Route, deadline: Duration?, terms: [String], provider: (any SummaryProvider)?)
    }

    /// The text corrected by its context, or the text itself: whenever the
    /// cleanup is off, not allowed, not possible, late or not believed,
    /// `text` comes back and the dictation goes on as it always did.
    func cleanedByContext(_ text: String, mode: CleanupMode = .dictation) async -> DictationSteps.Cleaned {
        let summarizer = Summarizer.shared
        // The provider and where it sends text, read once: the yes is
        // checked against this, and the request refuses to go anywhere
        // else (`Summarizer.cleanDictation`), so a provider changed in
        // Settings while this dictation is on its way gets none of it.
        let route = summarizer.dictationCleanupRoute
        func skipped(_ reason: DictationCleanup.SkipReason) -> DictationSteps.Cleaned {
            DictationCleanup.logSkip(reason, kind: route?.kind, chars: text.count)
            return DictationSteps.Cleaned(text: text, outcome: .skipped(reason))
        }
        var isDictation = false
        if case .dictation = mode {
            isDictation = true
            // The switch, the provider, the subscription, the yes, and
            // what is known of the provider: the same answer the caption
            // in Settings is written from.
            if let reason = DictationCleanup.standingSkip(DictationCleanup.standing()) {
                if reason == .consent, let route,
                   DictationCleanupConsent().shouldShowNotice(route.kind, destination: route.destination) {
                    tellCleanupNeedsConsent()
                }
                if reason == .noSubscription { refreshSubscriptionStatus() }
                return skipped(reason)
            }
            // A password is never sent anywhere. Secure input says so even
            // where Accessibility can't see the field (or isn't granted).
            if IsSecureEventInputEnabled() || AXFocus.kind() == .secure { return skipped(.secureField) }
        }
        guard let route else { return skipped(.provider) }
        // The bench's yes was for one provider at one address.
        if case .bench(let allowed, _, _, _) = mode, allowed != route { return skipped(.consent) }
        if let length = DictationCleanup.lengthSkip(text, kind: route.kind) { return skipped(length) }
        let language = await DictationCleanup.language(of: text)
        // Apple's on-device model is asked only for a language it is known
        // to write: one it doesn't, it refuses or answers in another, and
        // a text whose language couldn't be told may be either.
        if route.kind == .appleIntelligence {
            guard let language, #available(macOS 26.0, *), AppleIntelligenceSummarizer.supportsLanguage(language) else {
                return skipped(.language)
            }
        }

        let terms: [String]
        let deadline: Duration?
        let permission: DictationCleanup.Permission
        var provider: (any SummaryProvider)?
        switch mode {
        case .dictation:
            terms = Array(DictationDictionary.shared.biasTerms().prefix(SummaryPrompt.dictationCleanupTermLimit))
            deadline = DictationCleanup.deadline
            permission = .stored(.standard)
        case .bench(_, let limit, let benchTerms, let benchProvider):
            terms = benchTerms
            deadline = limit
            permission = .granted
            provider = benchProvider
        }
        let context = DictationCleanupContext(terms: terms, language: language)
        // Where the text was going when the wait began, and the widget's
        // flower turning while the answer is awaited — only if it was at
        // rest, and only that turn is ended: a Daisy-key command's own
        // stage is not this dictation's to show or to end. No words: the
        // text arriving says it.
        let target = isDictation ? insertionTarget() : nil
        let working = isDictation ? DaisyKeyIndicator.shared.showWorking() : nil
        defer { DaisyKeyIndicator.shared.endWorking(working) }
        let cleaner = provider
        let result = await DictationCleanup.run(text, kind: route.kind, deadline: deadline) { text in
            try await Summarizer.shared.cleanDictation(text, context: context, route: route,
                                                       permission: permission, using: cleaner)
        }
        guard isDictation else { return DictationSteps.Cleaned(text: result.text, outcome: result.outcome) }
        DictationCleanupStatus.shared.record(result.outcome, for: route.kind)
        if result.outcome == .skipped(.noSubscription) { refreshSubscriptionStatus() }
        // The person may have clicked into another field, or another app,
        // while the answer was on its way.
        let moved = target.map { DictationCleanup.targetMoved(from: $0, to: insertionTarget()) } ?? false
        if moved { log.notice("Focus moved while the cleanup was awaited — clipboard only, no typing") }
        return DictationSteps.Cleaned(text: result.text, outcome: result.outcome, targetMoved: moved)
    }

    /// The subscription's status read again, for the next dictation: this
    /// one went by what was last known and never waits for the account.
    /// Asked of the server each time, not taken from a status under a
    /// minute old: a subscription paid for a moment ago is seen by the
    /// very next dictation.
    private func refreshSubscriptionStatus() {
        let account = DaisyAccountStore.shared
        guard account.isSignedIn else { return }
        Task { await account.refreshSubscription() }
    }

    /// The field that has the keyboard, as Accessibility names it.
    private struct FocusedField: Equatable {
        let element: AXUIElement
        static func == (lhs: FocusedField, rhs: FocusedField) -> Bool { CFEqual(lhs.element, rhs.element) }
    }

    /// The app in front and, when Accessibility can say, the focused
    /// field and the app that owns it (a floating panel's field belongs to
    /// another app than the one in front). Each read is capped at 100 ms.
    private func insertionTarget() -> DictationCleanup.InsertionTarget<FocusedField> {
        var target = DictationCleanup.InsertionTarget<FocusedField>(
            app: NSWorkspace.shared.frontmostApplication?.processIdentifier, field: nil)
        guard AXIsProcessTrusted() else { return target }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return target }
        let element = ref as! AXUIElement
        target.field = FocusedField(element: element)
        var owner: pid_t = 0
        AXUIElementGetPid(element, &owner)
        if owner != 0 { target.app = owner }
        return target
    }

    /// The provider changed (or where it sends text) since the yes was
    /// given: the dictation went in as recognized, and this says once why
    /// and where the yes is. On the widget's pill too — dictation happens
    /// in other apps, the toast lives in Daisy's window.
    private func tellCleanupNeedsConsent() {
        let text = String(localized: "Dictation wasn’t fixed by context: allow sending in Settings")
        let open: @MainActor () -> Void = { ContextTips.openSettings(.dictation, row: .fixDictationByContext) }
        ToastCenter.shared.showAction(text, actionLabel: String(localized: "Open Settings"), style: .info,
                                      duration: .seconds(8), perform: open)
        WidgetBubbleCenter.shared.present(
            WidgetBubbleContent(text: text, actionTitle: String(localized: "Open Settings"), autoDismiss: 8,
                                tag: "dictation-cleanup-consent",
                                action: { open(); WidgetBubbleCenter.shared.openMainWindow?() }),
            notificationTitle: "Daisy"
        )
    }

    /// Where a `deliver` call came from — only a FRESH dictation shows
    /// the "landed nowhere" bubble. A re-paste that lands nowhere needs
    /// no prompt: the user explicitly asked to paste and can just ask
    /// again.
    private enum DeliveryContext {
        case freshDictation, repaste
        /// Backlog 24 М-10: a meeting's step or follow-up, inserted at the
        /// caret of the app the person came from.
        case step
    }

    /// Backlog 24 М-10: text that is not a dictation (a next step, the
    /// follow-up) by the same road — no dictation bookkeeping.
    func insert(_ text: String) async {
        await deliver(text, context: .step)
    }

    /// How far back the "paste last dictation" hotkey reaches.
    static let repasteWindow: TimeInterval = 60 * 60

    /// Re-paste the most recent dictation, if it is under an hour old, at the current caret — Wispr's
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
    func repasteLast() async {
        // Only the last hour (Egor, 2026-10-13): the history now keeps
        // days, and a hotkey that drops last week's paragraph at the
        // caret is a surprise, not a recovery.
        guard let last = DictationHistory.shared.entries.first,
              Date().timeIntervalSince(last.date) <= Self.repasteWindow,
              !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ToastCenter.shared.show(
                String(localized: "No dictations in the last hour"),
                style: .info
            )
            return
        }
        // Still on its way to the field (its text is in the history before
        // the cleanup's answer is awaited): it lands by itself in a
        // moment, and pasting it now as well would put it in twice.
        guard !order.isInFlight(last.id) else {
            log.notice("Re-paste asked for a dictation still on its way — left to land once")
            return
        }
        ImprovementStats.record(.dictationRepaste)
        await deliver(last.text, context: .repaste)
    }

    /// Put `transcript` where the caret is: straight into the focused
    /// field via Accessibility when we can, else onto the clipboard with
    /// an auto-paste and a timed restore of the user's prior clipboard.
    /// Assumes the text is already corrected — callers that start from a
    /// raw dictation run `prepare` first.
    ///
    /// `targetMoved`: the text waited (for the cleanup by context) and the
    /// person meanwhile moved to another field or app. It is then not
    /// written or typed anywhere — it would land in the wrong place — and
    /// goes on the clipboard for them to paste, as after `deliverNow`'s
    /// own wait.
    private func deliver(_ transcript: String, context: DeliveryContext, targetMoved: Bool = false) async {
        // One at a time: a delivery waits for a late write before it falls
        // back, and a second one starting meanwhile would type into the
        // middle of it.
        let previous = deliveryInFlight
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.deliverNow(transcript, context: context, targetMoved: targetMoved)
        }
        deliveryInFlight = task
        await task.value
    }

    private var deliveryInFlight: Task<Void, Never>?
    /// Bumped by every delivery: a watcher from an earlier one stops, so
    /// the same words delivered again aren't taken for a double landing.
    private var deliveryGeneration = 0

    private func deliverNow(_ transcript: String, context: DeliveryContext, targetMoved: Bool = false) async {
        deliveryGeneration &+= 1
        // The text goes in by a road the layout watcher's tap doesn't see
        // as typing: the word it remembers is no longer before the caret
        // — now, and still when the delivery ends (keys pressed while it
        // ran are on an unknown side of the text).
        LayoutAutoFix.forgetAfterOwnInsert()
        defer { LayoutAutoFix.forgetAfterOwnInsert() }
        // The whole delivery, the wait for a slow app included — the
        // release→paste line stops where the delivery begins.
        let deliveryStart = Date()
        defer { log.notice("Delivery \(Int(Date().timeIntervalSince(deliveryStart) * 1000), privacy: .public) ms") }
        // The tour's practice field takes a fresh dictation said into it.
        if context == .freshDictation, NSApp.isActive, let practiceSink, practiceSink(transcript) {
            return
        }
        // 0. Best path: insert DIRECTLY into the focused text field via
        //    the Accessibility API — the pasteboard is never touched, so
        //    whatever the user had copied (logs, a link…) survives
        //    untouched. Works in most native apps; web views / Electron
        //    and secure fields often refuse, in which case we fall through
        //    to the clipboard route below.
        let axStart = Date()
        // Not attempted when the person moved on during an earlier wait:
        // the write would go into whatever has the keyboard now.
        let attempt = targetMoved ? AXAttempt(outcome: .refused) : await attemptAXInsert(transcript)
        let axOutcome = attempt.outcome
        // `.notice` so it stays in the system log (latency audit 31.10,
        // item 0): the time and the branch, nothing about the app or text.
        log.notice("Accessibility \(Int(Date().timeIntervalSince(axStart) * 1000), privacy: .public) ms (\(axOutcome.logLabel, privacy: .public))")
        if axOutcome == .inserted { return }
        // A write went out and didn't show up in time. If the person moved
        // on meanwhile (another app, another field), typing or ⌘V would
        // land there — as shortcuts, or in the next message — so the text
        // only goes on the clipboard for them to paste.
        var focusMoved = targetMoved
        if let pending = attempt.pending {
            AXUIElementSetMessagingTimeout(pending.element, 0.1)
            let last = Self.axStringValue(of: pending.element)
            AXUIElementSetMessagingTimeout(pending.element, 0)
            if Self.holdsWrite(last, before: pending.before, text: transcript) {
                // Late, not ignored: the miss counted a moment ago is undone.
                if let app = pending.app { writeMemory.recordLate(Int(Date().timeIntervalSince(axStart) * 1000), for: app) }
                log.notice("Dictation inserted via AX (showed up just before the fallback) — clipboard untouched")
                return
            }
            focusMoved = !Self.stillFocused(pending.element)
            if focusMoved { log.notice("Focus moved while waiting for the AX write — clipboard only, no typing") }
        }
        // From here the text goes in another way. A write that went out
        // and may still land is watched, so a field that ends up holding
        // it twice is noticed and the app remembered.
        defer {
            if let pending = attempt.pending, !focusMoved {
                watchForLateWrite(pending, text: transcript, generation: deliveryGeneration)
            }
        }

        // 0b. Second-best path, and the one Electron / web views actually
        //     take: TYPE the text as synthetic key events, the way the
        //     layout fixer already re-types a corrected word. Still no
        //     pasteboard involvement. Chromium accepts a key-down carrying
        //     a Unicode string as typed text, which is exactly what AX
        //     refuses to do for it. Skipped when the person asked for the
        //     clipboard route (apps that autocomplete as you type can
        //     mangle typed text — the paste lands whole), and when
        //     Accessibility is missing, since event posting needs it too.
        //
        //     `.noFocusedField` still goes through here: Chromium reports
        //     no focus even with a caret blinking, so "no field" is not a
        //     reason to skip. Typing into a true void is as harmless as
        //     the ⌘V into a void was — and the "landed nowhere" bubble
        //     below still fires for that case.
        let clipboardRoute = UserDefaults.standard.bool(forKey: AppSettings.k_dictationPastesViaClipboard)

        // A true void — desktop, Daisy itself, nothing in front — gets
        // neither typed into (Finder would take the letters as
        // type-to-select) nor written to the clipboard. The bubble names
        // the re-paste hotkey; the text is in the history either way.
        if !clipboardRoute, axOutcome == .noFocusedField, Self.frontmostIsVoid() {
            if context != .freshDictation {
                ToastCenter.shared.show(
                    String(localized: "Click into a field first"),
                    style: .info
                )
            }
            presentLandedNowhereBubbleIfNeeded(transcript, context: context, axOutcome: axOutcome)
            return
        }

        // Type only when AX found a field that refused the write. With
        // NO focused element in an app that isn't a void, typed letters
        // are single-key shortcuts — Gmail archives on `e`, YouTube
        // seeks — whereas a ⌘V with nothing focused does nothing. So
        // `.noFocusedField` keeps the clipboard route, restore and all.
        if !clipboardRoute,
           !focusMoved,
           axOutcome == .refused,
           AXIsProcessTrusted(),
           attemptTypeInsert(transcript) {
            presentLandedNowhereBubbleIfNeeded(transcript, context: context, axOutcome: axOutcome)
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
        let autoPaste = focusMoved ? .failed : attemptAutoPaste()
        let didAutoPaste = (autoPaste == .pasted)
        // 4. Schedule restore. Auto-paste already landed → the transcript
        //    only needs to outlive the keystroke (quick restore, prior
        //    clipboard back in a few seconds). Manual-paste fallback → the
        //    transcript must stay around long enough to ⌘V by hand.
        let restoreAfter = didAutoPaste ? Self.quickRestoreSeconds : Self.retentionSeconds
        switch autoPaste {
        case .pasted:
            // No toast: the text in the field says it (Egor 01.11).
            break
        case .needsAccessibility:
            // Not a success, and not a mystery either: name the missing
            // permission and offer the pane. Announced as success, this
            // is how a person concludes that manual ⌘V is simply how
            // Daisy works.
            ToastCenter.shared.showAction(
                String(localized: "Press ⌘V within \(Int(Self.retentionSeconds)) s"),
                actionLabel: String(localized: "Allow access"),
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
            let text = String(localized: "Press ⌘V within \(Int(Self.retentionSeconds)) s")
            ToastCenter.shared.show(text, style: .warning)
            // The person is in another field or app by now, where a toast
            // in Daisy's window isn't seen: said on the widget's pill too
            // (a notification without one), for as long as the text is on
            // the clipboard.
            if focusMoved {
                WidgetBubbleCenter.shared.present(
                    WidgetBubbleContent(text: text, autoDismiss: Self.retentionSeconds, tag: "dictation-press-paste"),
                    notificationTitle: "Daisy"
                )
            }
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
        // The person's own ⌘V meanwhile gets their clipboard, not this
        // text. Only when Daisy pasted: after «Press ⌘V» it is this text
        // they were told to paste. And not with nothing to give back: an
        // empty clipboard is no answer to a ⌘V.
        if didAutoPaste, !snapshot.isEmpty {
            returnWatch = ClipboardReturnWatch.shared.arm { [weak self] in
                self?.restoreTimer?.invalidate()
                self?.restoreClipboardIfUnchanged()
            }
        }

        presentLandedNowhereBubbleIfNeeded(transcript, context: context, axOutcome: axOutcome)
    }

    /// Dictated into the void: no field had focus, so the text landed
    /// nowhere (typed or pasted — same outcome). Surface a bubble from the
    /// widget (Wispr's "copy last transcript") offering to keep the text —
    /// only for a fresh dictation, and only when we're sure there was no
    /// target.
    private func presentLandedNowhereBubbleIfNeeded(
        _ transcript: String,
        context: DeliveryContext,
        axOutcome: AXInsertOutcome
    ) {
        // `.refused` means a field exists but won't take an AX write; the
        // typed text / ⌘V almost certainly reached it, so no prompt there. And
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
                            format: String(localized: "Nowhere to paste, press %@ later"),
                            label
                        )
                    ),
                    notificationTitle: String(localized: "Dictation saved"),
                    notificationBody: String(
                        format: String(localized: "Nowhere to paste, press %@ later"),
                        label
                    )
                )
                return
            }
            WidgetBubbleCenter.shared.present(
                WidgetBubbleContent(
                    text: String(localized: "Nowhere to paste"),
                    actionTitle: String(localized: "Copy"),
                    actionSymbol: "doc.on.doc",
                    action: { [weak self] in
                        // Re-write it fresh (the restore may already have
                        // fired) and cancel any pending revert so it stays.
                        self?.cancelPendingRestore()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        ToastCenter.shared.show(
                            String(localized: "Copied, press ⌘V"),
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
    private enum AXInsertOutcome {
        case inserted, refused, noFocusedField

        var logLabel: String {
            switch self {
            case .inserted: "inserted"
            case .refused: "refused"
            case .noFocusedField: "no focused field"
            }
        }
    }

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

    /// A write that went out and didn't show up in time: what is needed to
    /// look at the field again once the text has gone in another way.
    private struct PendingWrite {
        let element: AXUIElement
        let before: String
        /// Per app and version (`AXWriteMemory.key`); nil for Daisy's own
        /// fields, which are never remembered.
        let app: String?
    }

    private struct AXAttempt {
        let outcome: AXInsertOutcome
        var pending: PendingWrite? = nil
    }

    private let writeMemory = AXWriteMemory()

    /// Insert `text` at the caret of the system-wide focused UI element
    /// (replacing any selection) via the Accessibility API — no
    /// pasteboard involvement at all.
    ///
    /// Whether the write took is read back from the field, and a field
    /// may show it late (Telegram — see AXWriteMemory), whatever the
    /// write answered: success or an error. So any write that went out is
    /// watched for a moment before it counts as refused, and how the app
    /// behaved is remembered per app version.
    private func attemptAXInsert(_ text: String) async -> AXAttempt {
        // Permission missing → we can't tell whether a field is focused,
        // so don't claim "nowhere"; take the clipboard path and let
        // `attemptAutoPaste` prompt for Accessibility as it always has.
        guard AXIsProcessTrusted() else { return AXAttempt(outcome: .refused) }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else { return AXAttempt(outcome: .noFocusedField) }
        // AXUIElement is a CoreFoundation type — an unconditional
        // downcast from CFTypeRef is the sanctioned bridge.
        let element = focusedRef as! AXUIElement

        // The app that owns the field — not the frontmost one, which a
        // floating panel (Spotlight, a non-activating window) leaves
        // pointing at the app behind it. Daisy's own fields are never
        // remembered.
        var ownerPID: pid_t = 0
        AXUIElementGetPid(element, &ownerPID)
        let ownField = ownerPID == getpid()
        let app = ownField ? nil : Self.memoryKey(pid: ownerPID)
        let memory = app.map(writeMemory.entry(for:)) ?? AXWriteMemory.Entry()
        // An app that ignored the write twice and never took one late:
        // straight to the fallback, without the write, the read-back and
        // the wait. Checked after the focus lookup, so «no field focused»
        // still says so.
        if app != nil, AXWriteMemory.skipsWrite(memory) {
            log.notice("AX insert skipped — this app ignored it before; typing instead")
            return AXAttempt(outcome: .refused)
        }

        // Only proceed when the element explicitly supports setting the
        // selected text — writing blindly can beep or mangle state in
        // apps that expose the attribute read-only.
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else {
            log.notice("AX insert refused — the field doesn't take a write")
            return AXAttempt(outcome: .refused)
        }

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

        // Unreadable field: nothing to verify against. A success keeps the
        // old trust rather than regress native fields that expose no
        // AXValue; an error is taken at its word.
        guard let before else {
            if result == .success {
                log.notice("Dictation inserted via AX (unverified — field exposes no readable value) — clipboard untouched")
                return AXAttempt(outcome: .inserted)
            }
            log.notice("AX write returned error \(result.rawValue, privacy: .public) on a field with no readable value")
            return AXAttempt(outcome: .refused)
        }

        // Verify by the text showing up — right away, or within the wait
        // this app gets. A change without the text (the person typing, a
        // chat clearing itself) is not taken for the write landing.
        let reply = result == .success ? "success" : "error \(result.rawValue)"
        let now = Self.axStringValue(of: element)
        // Right after a success any change is the write: a field may store
        // the text a little differently (Word's \r for a new line,
        // autocorrect, a length cap). An error, or a change later on, has
        // to show the text, so the person typing or a chat clearing
        // itself isn't taken for it.
        let changed = now.map { $0 != before } ?? false
        if text.isEmpty || (result == .success && changed) || Self.holdsWrite(now, before: before, text: text) {
            if let app { writeMemory.recordLanded(for: app) }
            log.notice("Dictation inserted via AX (verified by value change, \(reply, privacy: .public)) — clipboard untouched")
            return AXAttempt(outcome: .inserted)
        }
        let wait = AXWriteMemory.wait(for: memory)
        if let waited = await Self.lateChange(of: element, from: before, holding: text, within: wait) {
            if let app { writeMemory.recordLate(waited, for: app) }
            log.notice("Dictation inserted via AX (applied after \(waited, privacy: .public) ms, \(reply, privacy: .public)) — clipboard untouched")
            return AXAttempt(outcome: .inserted)
        }
        // Not counted when the field already held the text (a selection
        // replaced by the same words reads as unchanged).
        if let app, !before.contains(text) { writeMemory.recordIgnored(for: app) }
        log.warning("AX write (\(reply, privacy: .public)) didn't show up within \(Int(wait * 1000), privacy: .public) ms — falling back")
        return AXAttempt(outcome: .refused, pending: PendingWrite(element: element, before: before, app: app))
    }

    /// The app that owns a field, at its version: `bundleID|version`.
    private static func memoryKey(pid: pid_t) -> String? {
        guard let running = NSRunningApplication(processIdentifier: pid),
              let id = running.bundleIdentifier else { return nil }
        let info = running.bundleURL.flatMap(Bundle.init(url:))?.infoDictionary
        let version = [info?["CFBundleShortVersionString"], info?["CFBundleVersion"]]
            .compactMap { $0 as? String }.joined(separator: " ")
        return AXWriteMemory.key(bundleID: id, version: version.isEmpty ? nil : version)
    }

    /// The field moved off `before` and holds the text — line breaks and
    /// the ends' whitespace as the field may store them.
    private static func holdsWrite(_ value: String?, before: String, text: String) -> Bool {
        guard let value, value != before else { return false }
        let needle = AXWriteMemory.comparable(text)
        return needle.isEmpty || AXWriteMemory.comparable(value).contains(needle)
    }

    /// The system-wide focus is still on `element`. When the focus can't
    /// be read (a busy app timing out), the app in front decides: the
    /// field's own app still in front counts as staying.
    private static func stillFocused(_ element: AXUIElement) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
           let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            return CFEqual(ref, element)
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid != 0 && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// Milliseconds until the element's value moved off `before` AND holds
    /// `text`, looking every 25 ms up to `window`; nil if it never did.
    /// Sleeps between reads, so the main thread stays free (and Daisy's
    /// own fields can apply the write meanwhile); each read is capped at
    /// 100 ms, so a busy app can't hold it past the window.
    private static func lateChange(of element: AXUIElement, from before: String, holding text: String, within window: TimeInterval) async -> Int? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        defer { AXUIElementSetMessagingTimeout(element, 0) }
        let start = Date()
        while Date().timeIntervalSince(start) < window, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(25))
            if holdsWrite(axStringValue(of: element), before: before, text: text) {
                return Int(Date().timeIntervalSince(start) * 1000)
            }
        }
        return nil
    }

    /// After the fallback typed or pasted the text: look at the field
    /// twice more. Holding it twice means the write landed after all —
    /// the app is remembered as slow, so next time Daisy waits for it
    /// instead of typing. Doesn't hold up the delivery.
    private func watchForLateWrite(_ pending: PendingWrite, text: String, generation: Int) {
        Task { @MainActor [weak self] in
            for delay in [800, 1200] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, self.deliveryGeneration == generation else { return }
                AXUIElementSetMessagingTimeout(pending.element, 0.1)
                let now = Self.axStringValue(of: pending.element)
                AXUIElementSetMessagingTimeout(pending.element, 0)
                guard let now else { return }
                if AXWriteMemory.landedTwice(before: pending.before, after: now, text: text) {
                    if let app = pending.app { self.writeMemory.recordLandedAfterFallback(for: app) }
                    self.log.error("Dictation landed twice — the AX write came in after the fallback; this app now gets longer to take it")
                    return
                }
            }
        }
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
            AccessibilityPrompt.show()
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
        // Ours, so that neither the layout watcher nor the watch for the
        // person's own paste takes it for theirs.
        for event in [cmdDown, vDown, vUp, cmdUp] {
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvents.marker)
        }

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

    /// Type `text` into the frontmost app as synthetic key events — the
    /// clipboard-free route for fields that refuse an AX write. Each
    /// key-down carries up to 20 UTF-16 units of the text (the documented
    /// ceiling for `keyboardSetUnicodeString`); a newline goes out as
    /// ⇧Return, which is "new line, don't send" in every chat app and a
    /// plain newline everywhere else — a bare Return would SEND the
    /// message in Claude / Slack / Telegram, the apps this path exists for.
    ///
    /// Events carry the `SyntheticEvents.marker` so the layout fixer's tap
    /// ignores them; otherwise it would try to "correct" a Russian
    /// dictation typed under an English layout. Same `.privateState`
    /// source as the fixer, so the person physically holding ⇧ or ⌥ at
    /// the moment doesn't get their modifiers stamped onto our text.
    ///
    /// Returns false only when events can't be built — the caller then
    /// takes the clipboard route. Delivery itself is unverifiable, the
    /// same as ⌘V was.
    private func attemptTypeInsert(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard let source = CGEventSource(stateID: .privateState) else {
            log.error("Couldn't create CGEventSource for typed insert")
            return false
        }
        var events: [CGEvent] = []
        events.reserveCapacity(text.utf16.count / 10 + 4)

        func appendText(_ units: [UInt16]) -> Bool {
            var start = 0
            while start < units.count {
                var end = min(start + 20, units.count)
                // Never split a surrogate pair across two events — half an
                // emoji arrives as U+FFFD.
                if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
                let chunk = Array(units[start..<end])
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                else { return false }
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                events.append(down)
                events.append(up)
                start = end
            }
            return true
        }
        func appendNewline() -> Bool {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: false)
            else { return false }
            down.flags = .maskShift
            up.flags = .maskShift
            events.append(down)
            events.append(up)
            return true
        }

        // Split on line breaks; everything between them is plain text.
        let lines = text.split(omittingEmptySubsequences: false) { $0.isNewline }
        for (index, line) in lines.enumerated() {
            if index > 0, !appendNewline() { return false }
            if !line.isEmpty, !appendText(Array(line.utf16)) { return false }
        }
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvents.marker)
        }

        // Same settle delay as the ⌘V path, same reason: focus may not
        // have finished moving back to the person's field yet.
        Thread.sleep(forTimeInterval: 0.08)
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "<unknown>"
        log.notice("Typing dictation as \(events.count / 2, privacy: .public) key events — frontmost app: \(frontmost, privacy: .private)")
        let tap = CGEventTapLocation.cgSessionEventTap
        for event in events { event.post(tap: tap) }
        return true
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
            disarmReturnWatch()
            pendingSnapshot = nil
            restoreTimer = nil
        }
        guard let snapshot = pendingSnapshot else { return }
        let currentCount = NSPasteboard.general.changeCount
        if currentCount != snapshot.changeCountAfterOurWrite {
            log.notice("Pasteboard changed during retention window — skipping restore (\(currentCount, privacy: .public) vs \(snapshot.changeCountAfterOurWrite, privacy: .public))")
            return
        }
        NSPasteboard.general.clearContents()
        if snapshot.items.isEmpty {
            log.notice("Restored empty pasteboard (no prior contents)")
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
        log.notice("Restored pasteboard with \(nsItems.count, privacy: .public) item(s) after dictation grace window")
    }

    /// Cancel any pending restore — used when a NEW dictation
    /// happens before the previous one's 10 s window expired.
    /// The new transcript stays in clipboard, the new restore
    /// timer runs against the NEW snapshot.
    private func cancelPendingRestore() {
        restoreTimer?.invalidate()
        restoreTimer = nil
        pendingSnapshot = nil
        disarmReturnWatch()
    }

    private func disarmReturnWatch() {
        ClipboardReturnWatch.shared.disarm(returnWatch)
        returnWatch = nil
    }
}
