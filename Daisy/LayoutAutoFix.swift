//
//  LayoutAutoFix.swift
//  Daisy
//
//  Fixing the wrong keyboard layout as you type. Off by default.
//
//  HOW IT CATCHES A WORD BEFORE RETURN SENDS IT. The tap is ACTIVE, so
//  the window server hands us each key press and waits for us to hand it
//  back. A boundary key — space, comma, Return, Tab — can therefore be
//  swallowed: we drop it, post the correction, and post the boundary
//  ourselves. The app sees «привет» and then Return, in that order, and
//  the message it sends is the fixed one. Compensating after the fact
//  cannot do this: an already-sent message cannot be unsent, which is why
//  the first version left Return alone.
//
//  THE COST OF AN ACTIVE TAP, AND WHAT PAYS IT. Everything typed on this
//  Mac now waits on this code. So the decision is NOT made here: it is
//  made between keystrokes, on the main actor, and stored as a verdict —
//  "if this word ends now, delete N presses and type X". The tap callback
//  reads that verdict under a lock and posts events. No dictionary
//  lookup, no Accessibility round trip, no allocation of consequence.
//  Everything expensive happens while the user is still typing letters.
//
//  For the same reason the tap does not live on the main run loop. It has
//  its own thread: a summarizer or a SwiftUI layout pass blocking the
//  main actor must not be able to block the keyboard. If this file hangs
//  anyway, macOS notices and disables the tap — keys flow again and the
//  feature goes quiet, which is the right way round. If Daisy crashes,
//  the tap dies with the process and typing is unaffected.
//
//  WHAT IT NEVER DOES. No typed text is logged, stored, or sent: the
//  buffer is one word, in memory, dropped at every boundary, click,
//  chord, app switch, and while macOS reports secure input anywhere on
//  the system. Terminals, IDEs, remote desktops and password managers
//  are excluded outright — see `excludedBundleIDs`.
//
//  What IS logged is why a fix did NOT happen: the name of the gate that
//  closed, plus Accessibility role names — never content, never the word
//  and never which app was excluded. "It does nothing" was the whole of
//  the first bug report, and every gate here fails the same silent way,
//  so without these notes the answer isn't in the log to be found.
//
//  WHY IT REFUSES SO OFTEN. Five things must hold before a verdict is
//  even recorded, and each is a way this would otherwise have eaten text:
//
//    1. Accessibility says the focus is editable text. Letters typed into
//       a mail list are type-select, and the backspaces that would fix a
//       word there delete messages instead. This check is the difference
//       between a fixer and a shredder.
//    2. The characters in front of the caret are the ones we think we
//       typed — which catches macOS text replacement ("omw" → "On my
//       way!"), inline autocomplete, and auto-paired brackets.
//    3. The word is unknown to the spell checker as typed and a real word
//       converted (see LayoutFix).
//    4. Nothing has been typed since the verdict was recorded. Every key
//       press bumps a generation counter and the verdict carries the one
//       it was computed for.
//    5. Backspaces are counted in KEY PRESSES, not characters — one press
//       can produce a combining mark that merges into the previous
//       grapheme.
//
//  And if a verdict is not ready when the boundary arrives, the boundary
//  passes through untouched and the old after-the-fact path fixes the
//  word — except after Return, where there is nothing left to fix.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// What the tap should do with the event it was handed.
nonisolated enum TapDecision {
    case pass
    case swallow
}

/// The tap's C callback. A file-level function rather than a closure
/// property: it must convert to `@convention(c)`, and a top-level
/// `nonisolated` func is the spelling with no isolation-inference
/// question hanging over it.
private nonisolated func daisyLayoutTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    switch type {
    case .keyDown:
        if LayoutAutoFix.handle(event, proxy: proxy) == .swallow { return nil }
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
        // The caret may have moved anywhere; the word in flight is no
        // longer the word in front of it, and it is no longer a candidate
        // for the fix key either. A pending undo is scoped to "same app,
        // recent, text still matches" — nothing here ties it to the
        // CARET the fix actually touched, so a click that lands on text
        // which happens to read the same as the last fix's output must
        // not be treated as that fix waiting to be undone.
        LayoutAutoFix.buffer.discard()
        Task { @MainActor in LayoutFixUndo.shared.clear() }
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        // Everything typed while we were deaf is unaccounted for.
        LayoutAutoFix.buffer.discard()
        Task { @MainActor in LayoutAutoFix.shared.reenable() }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

@MainActor
final class LayoutAutoFix {
    static let shared = LayoutAutoFix()

    private(set) var isRunning = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activationObserver: (any NSObjectProtocol)?
    private var watchdog: Timer?
    /// Observers for a rival layout switcher starting or quitting. Live
    /// for as long as the SETTING is on — including while suspended,
    /// which is the whole point: nothing else would notice the rival
    /// quitting. See `LayoutFixConflicts`.
    private var rivalLaunchObserver: (any NSObjectProtocol)?
    private var rivalQuitObserver: (any NSObjectProtocol)?
    /// On, but stood down because a rival switcher is running. Distinct
    /// from off: the user's setting is untouched and we resume by
    /// ourselves.
    private(set) var suspendedForConflict = false

    /// The rival we stood down for, for the log report and the
    /// onboarding caption — `auto=true running=false` with no reason is
    /// the exact line a bug report once cost a day to.
    private(set) var conflictingSwitcherName: String?
    private let host = TapHost()
    /// Read for `layoutFixSwitchesSource` only. A missing reference means
    /// "don't switch", the quieter of the two behaviours.
    private weak var settings: AppSettings?

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "LayoutAutoFix")

    /// When each stand-down reason was last logged. "It does nothing"
    /// was the entire first bug report, and the feature had no way to
    /// answer it: every gate returned the same silence. These notes name
    /// the gate — never the word, which is someone's typing — and each
    /// reason repeats at most every `noteInterval`.
    ///
    /// Per REASON, not a single last-reason slot: two reasons that
    /// alternate (a slow app that sometimes answers Accessibility and
    /// sometimes times out) would defeat one slot completely and log on
    /// every keystroke. The key set is small and fixed, so the dictionary
    /// cannot grow.
    private var lastNotes: [String: Date] = [:]
    private static let noteInterval: TimeInterval = 30

    /// The word being typed and the verdict about it. Lives outside the
    /// actor because the tap's callback reaches it on its own thread —
    /// that is the whole point of the design.
    nonisolated static let buffer = WordBuffer()

    /// How long the user must pause before we spend a dictionary lookup
    /// and an Accessibility round trip on the word so far. Typing "прив"
    /// through to "привет" would otherwise cost four of each. Kept well
    /// under a fast typist's inter-key gap: a verdict that isn't ready when
    /// the boundary lands is a word that doesn't get fixed before Return,
    /// which is the whole reason this path exists.
    /// Keep this shorter than a normal key-to-space gap.  The first
    /// release used 45 ms, which made the fallback do almost all the
    /// work for quick typists and meant Return frequently arrived before
    /// a verdict existed.  Twelve milliseconds still moves the
    /// dictionary and AX work off the tap thread, but gives the verdict a
    /// realistic chance to be ready before the word boundary.
    private static let verdictDelay: Duration = .milliseconds(12)

    /// How stale a just-finished word may be and still be fixable by the
    /// fix key. The key's own key-down clears the buffer on its way past
    /// the tap, so without this the key would always find nothing.
    private static let recentWordWindow: TimeInterval = 3

    private init() {}

    // MARK: - Lifecycle

    func start(settings: AppSettings) {
        self.settings = settings
        guard !isRunning else { return }
        // A single enabled layout is a top candidate for "it does nothing
        // at all", and used to leave no trace anywhere.
        guard KeyboardLayouts.shared.installed.count > 1 else {
            log.info("Layout auto-fix not started: only one usable keyboard layout is enabled")
            return
        }

        // Another layout switcher is running (Caramba, Punto). Two of
        // them on one keyboard converts a word twice — see
        // LayoutFixConflicts. Theirs wins: they chose it. We stay
        // suspended, not off, so quitting it brings this back without a
        // trip to Settings.
        if let rival = LayoutFixConflicts.runningSwitcherName() {
            suspendedForConflict = true
            conflictingSwitcherName = rival
            log.info("Layout auto-fix suspended: \(rival, privacy: .public) is running")
            ToastCenter.shared.show(
                String(
                    format: String(localized: "%@ already fixes layouts, so Daisy won’t — two of them would garble the same word. Quit it and Daisy takes over."),
                    rival
                ),
                style: .info
            )
            return
        }
        suspendedForConflict = false
        conflictingSwitcherName = nil

        // Turned off and on again: the tap and its thread are built once
        // per process and only enabled and disabled after that. Unwinding a
        // run loop and invalidating a mach port while the window server may
        // be inside our callback is a race with nothing to gain — a
        // disabled tap costs a parked thread and no CPU.
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            beginObserving()
            isRunning = true
            log.info("Layout auto-fix re-enabled")
            return
        }

        // An ACTIVE tap on keyboard events is gated on Accessibility —
        // the same grant we already need to type a correction back. (The
        // Input Monitoring grant is what a listen-only tap needs; this one
        // supersedes it.)
        guard AXIsProcessTrusted() else {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            ToastCenter.shared.show(
                String(localized: "Automatic layout fixing needs Accessibility access — grant it in System Settings, then turn it on again."),
                style: .warning
            )
            return
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: daisyLayoutTapCallback,
            userInfo: nil
        ) else {
            log.error("CGEvent.tapCreate returned nil — layout auto-fix not started")
            ToastCenter.shared.show(
                String(localized: "Couldn't start automatic layout fixing. Check Accessibility for Daisy in System Settings, then quit and reopen Daisy."),
                style: .error
            )
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            log.error("CFMachPortCreateRunLoopSource returned nil")
            return
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        // Its OWN thread, deliberately: with an active tap the system
        // waits for our callback, and a main actor busy with a summarizer
        // would then be a keyboard that stutters.
        host.startIfNeeded(source: source)

        self.tap = tap
        self.runLoopSource = source
        beginObserving()
        isRunning = true
        // Spin the spell-check service up now, not inside the first
        // keystroke that needs an answer.
        LayoutFix.warmUp()
        log.info("Layout auto-fix started (active tap, own thread)")
        // Not a refusal — a breadcrumb for "it does nothing in app X"
        // reports. After the start, so it never sits on the launch path
        // ahead of the first frame.
        LayoutFixConflicts.logOtherKeyboardTaps()
    }

    func stop() {
        LayoutAutoFix.buffer.discard()
        endObserving()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        guard isRunning else { return }
        isRunning = false
        log.info("Layout auto-fix stopped")
    }

    private func beginObserving() {
        // A word half-typed in one app has nothing to do with the next.
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { _ in
                LayoutAutoFix.buffer.discard()
                // Reactivating the SAME app (Cmd-Tab away and back, a
                // different window) is still an activation — the caret
                // could be anywhere in it, so a pending undo shouldn't
                // survive this either. The closure itself isn't
                // MainActor per its declared type (only `queue: .main`
                // guarantees it RUNS there), hence the explicit hop.
                Task { @MainActor in LayoutFixUndo.shared.clear() }
            }
        }
        // macOS disables a tap it thinks is slow, and the disable
        // notification can be missed. Without this the feature would go
        // quiet for the rest of the session.
        if watchdog == nil {
            watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reenableIfDisabled() }
            }
        }
    }

    private func endObserving() {
        watchdog?.invalidate()
        watchdog = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
    }

    func apply(settings: AppSettings) {
        if settings.layoutFixAutoActive {
            beginRivalWatch()
            start(settings: settings)
        } else {
            endRivalWatch()
            suspendedForConflict = false
            conflictingSwitcherName = nil
            stop()
        }
    }

    // MARK: - Rival layout switchers

    /// Watch for a rival switcher launching or quitting. Tied to the
    /// SETTING, not to `isRunning`: while suspended the tap is down and
    /// no other timer or observer is alive to notice the rival leaving.
    private func beginRivalWatch() {
        guard rivalLaunchObserver == nil, rivalQuitObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        // Only Sendable values cross the hop — the house pattern (see
        // MeetingDetector): the closure runs on the main QUEUE but isn't
        // main-actor-isolated, and `NSRunningApplication` isn't Sendable.
        rivalLaunchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  LayoutFixConflicts.isSwitcher(bundleID: bundleID) else { return }
            let name = app.localizedName ?? bundleID
            Task { @MainActor in LayoutAutoFix.shared.rivalDidLaunch(named: name) }
        }
        rivalQuitObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in LayoutAutoFix.shared.resumeIfRivalsGone() }
        }
    }

    private func endRivalWatch() {
        let center = NSWorkspace.shared.notificationCenter
        if let rivalLaunchObserver { center.removeObserver(rivalLaunchObserver) }
        if let rivalQuitObserver { center.removeObserver(rivalQuitObserver) }
        rivalLaunchObserver = nil
        rivalQuitObserver = nil
    }

    /// A rival started while we were running: stand down mid-session,
    /// before the first double-converted word rather than after it.
    private func rivalDidLaunch(named name: String) {
        guard isRunning else { return }
        stop()
        suspendedForConflict = true
        conflictingSwitcherName = name
        log.info("Layout auto-fix stood down: \(name, privacy: .public) started")
        ToastCenter.shared.show(
            String(
                format: String(localized: "%@ started, so Daisy stopped fixing layouts — two of them would garble the same word."),
                name
            ),
            style: .info
        )
    }

    /// Something quit. Resume if we stood down for a rival, the setting
    /// is still on, and no rival is left.
    ///
    /// Deliberately NOT keyed on which app terminated: a terminated
    /// `NSRunningApplication` no longer answers reliably (its pid is -1),
    /// so an identity test here could strand us suspended for the rest of
    /// the session. `runningSwitcherName()` is the real question anyway,
    /// and it is cheap. The still-suspended case logs — a gate that
    /// closes silently is how this feature earned its first bug report.
    private func resumeIfRivalsGone() {
        guard suspendedForConflict, let settings, settings.layoutFixAutoActive else { return }
        if let remaining = LayoutFixConflicts.runningSwitcherName() {
            log.info("An app quit but \(remaining, privacy: .public) is still running — layout auto-fix stays suspended")
            return
        }
        suspendedForConflict = false
        conflictingSwitcherName = nil
        log.info("Rival layout switcher quit — resuming layout auto-fix")
        start(settings: settings)
    }

    fileprivate func reenable() {
        // `isRunning` / `suspendedForConflict` are NOT redundant with the
        // caller's checks: the tap thread posts this hop when macOS
        // disables the tap, and a disable already in flight when we stand
        // down for a rival switcher lands after `stop()`. Re-enabling
        // then would leave a live tap with `isRunning == false` and
        // nothing to ever disable it again — Daisy and the rival both
        // converting the same word, which is the whole thing this
        // suspension exists to prevent.
        guard isRunning, !suspendedForConflict, let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        log.warning("Layout auto-fix tap was disabled by the system — re-enabled")
    }

    private func reenableIfDisabled() {
        guard isRunning, let tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
        reenable()
    }

    // MARK: - The tap (its own thread, no main actor, no I/O)

    /// Runs for every key press on the machine. Everything here is a lock
    /// acquisition and, at most, posting a handful of events. Anything
    /// that could block belongs in `verdict(for:)` on the main actor.
    nonisolated static func handle(_ event: CGEvent, proxy: CGEventTapProxy) -> TapDecision {
        // Never analyse our own typing.
        guard !SyntheticEvents.isOurs(event) else { return .pass }
        // A password field somewhere on the system: don't even buffer.
        guard !secureInputIsOn() else {
            buffer.discard()
            return .pass
        }

        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            buffer.clear()   // a chord is a command, not a word
            return .pass
        }
        // `truncatingIfNeeded`, not `UInt16(_:)`: any process can post an
        // event with an out-of-range keycode field, and a trap here would
        // crash the app from inside the tap — mid-swallow, worst possible
        // moment.
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        if caretMovingKeyCodes.contains(keyCode) {
            buffer.discard()
            // Same reasoning as the mouse-down case: the caret just
            // moved, so a pending undo — scoped only to "same app,
            // recent, text matches" — is no longer known to be sitting
            // where the fix actually landed.
            Task { @MainActor in LayoutFixUndo.shared.clear() }
            return .pass
        }
        if keyCode == UInt16(kVK_Delete) {
            // Backspacing inside a word is ordinary typing, so track it
            // instead of giving up — but a delete on an empty buffer
            // means we no longer know what is in front of the caret.
            if !buffer.deleteLast() { buffer.discard() }
            return .pass
        }
        if keyCode == UInt16(kVK_ForwardDelete) {
            // Removes what is AFTER the caret — never anything we
            // buffered, so our picture of the field is now wrong.
            buffer.discard()
            return .pass
        }

        var length = 0
        var units = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &units)
        guard length == 1, let scalar = Unicode.Scalar(units[0]) else {
            // No character (dead key, F-key, modifier alone) — we can't
            // account for what the app did with it.
            buffer.clear()
            return .pass
        }
        let character = Character(scalar)

        // Still inside a word: keep it, and ask the main actor for a
        // verdict once it is long enough to have one.
        if character.isLetter || character == "'" || character == "-" {
            let snapshot = buffer.append(character)
            if snapshot.presses >= LayoutFix.minAutomaticWordLength {
                Task { @MainActor in await LayoutAutoFix.shared.prepareVerdict(for: snapshot) }
            }
            return .pass
        }

        // A boundary — the word just ended. Only characters that really
        // are text count: function keys and Help report private-use
        // scalars, and retyping one of those would insert garbage.
        guard isTextBoundary(character) else {
            buffer.clear()
            return .pass
        }

        // The verdict path: swallow the boundary, fix, and put the
        // boundary back ourselves. This is the only path that can save a
        // word ended with Return.
        if let verdict = buffer.matchingVerdict(),
           applyFromTap(verdict, boundary: event, character: character, proxy: proxy) {
            buffer.discard()
            let target = verdict.targetLayoutID
            let originalWord = verdict.originalWord
            let replacementWord = verdict.replacement
            Task { @MainActor in
                LayoutAutoFix.shared.settle(
                    targetLayoutID: target,
                    via: "before the boundary",
                    undo: (originalWord, character, replacementWord)
                )
            }
            return .swallow
        }

        // No verdict ready. Let the boundary through and fall back to
        // fixing after the fact — except after Return or Tab, where the
        // text may already have been sent and a retype would send it
        // twice.
        let finished = buffer.take(boundary: character)
        guard !character.isNewline, character != "\t" else {
            buffer.discard()
            return .pass
        }
        guard let finished, finished.word.count >= LayoutFix.minAutomaticWordLength else { return .pass }
        Task { @MainActor in
            LayoutAutoFix.shared.consider(finished, boundary: character)
        }
        return .pass
    }

    /// Post the correction and the swallowed boundary, in order, from the
    /// tap's own thread. Every event is built BEFORE any is posted: half
    /// of this operation — backspaces with no replacement, or a swallowed
    /// Return that never comes back — is worse than not running at all.
    nonisolated private static func applyFromTap(
        _ verdict: WordBuffer.Verdict,
        boundary: CGEvent,
        character: Character,
        proxy: CGEventTapProxy
    ) -> Bool {
        guard verdict.presses > 0, verdict.presses <= WordBuffer.maxPresses else { return false }
        guard let source = eventSource else { return false }
        let units = Array(verdict.replacement.utf16)
        guard !units.isEmpty else { return false }

        var events: [CGEvent] = []
        for _ in 0..<verdict.presses {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)
            else { return false }
            events.append(down)
            events.append(up)
        }
        // Text goes on a key event rather than through key codes: the
        // correction is in the OTHER layout, so the codes that would
        // produce it are exactly what the active layout cannot type.
        guard let textDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let textUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return false }
        textDown.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        textUp.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        events.append(textDown)
        events.append(textUp)

        // The boundary goes back as a copy of what the user pressed —
        // same key code, same flags, so a Return really is a Return in the
        // app that receives it. The CHARACTER is pinned onto it as well: a
        // copy carries only a key code, and `settle` may switch the input
        // source a moment later, at which point key code 47 stops being
        // "." and becomes "ю". Built before anything is posted, because a
        // swallowed Return that never comes back is the one outcome worse
        // than not running at all. Only the key-DOWN is injected: the
        // physical key-up was never tapped and arrives on its own, so
        // synthesizing one would hand the app two.
        guard let boundaryDown = boundary.copy() else { return false }
        let boundaryUnits = Array(String(character).utf16)
        boundaryDown.keyboardSetUnicodeString(
            stringLength: boundaryUnits.count,
            unicodeString: boundaryUnits
        )
        events.append(boundaryDown)

        for event in events {
            // Flags cleared on everything we invented; the boundary copy
            // keeps its own, because shift is what makes it "!" rather
            // than "1". A synthesized Delete that inherits a physically
            // held Option is ⌥Delete — it deletes a whole WORD per press,
            // and this posts several.
            if event !== boundaryDown { event.flags = [] }
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvents.marker)
            // `tapPostEvent`, not `post(tap:)`: it injects DOWNSTREAM of
            // this tap. Our events don't traverse the session chain again,
            // so they can't re-enter our own callback and no other app's
            // active tap gets to drop the Return we just promised to put
            // back. It is also far cheaper, which matters while the window
            // server is blocked on this callback.
            event.tapPostEvent(proxy)
        }
        return true
    }

    /// One event source for the life of the process: creating one per fix
    /// is an allocation and a window-server round trip inside the
    /// callback. `.privateState` so synthesized events never inherit the
    /// modifiers the user is physically holding.
    nonisolated(unsafe) private static let eventSource = CGEventSource(stateID: .privateState)

    /// `IsSecureEventInputEnabled` is not free in every macOS release and
    /// this runs on every key press in the system, so the answer is cached
    /// briefly. Short enough to be safe: the flag flips when a password
    /// field takes focus, which is always before the first character of a
    /// password is typed.
    nonisolated private static func secureInputIsOn() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        return secureInputCache.withLock { cache in
            if let cached = cache, now &- cached.at < 200_000_000 { return cached.value }
            let value = IsSecureEventInputEnabled()
            cache = (value, now)
            return value
        }
    }

    nonisolated private static let secureInputCache =
        OSAllocatedUnfairLock<(value: Bool, at: UInt64)?>(initialState: nil)

    nonisolated private static func isTextBoundary(_ character: Character) -> Bool {
        character == " " || character.isNumber || character.isPunctuation || character.isSymbol
            || character.isNewline || character == "\t"
    }

    /// Keys after which we no longer know what sits in front of the
    /// caret: arrows, Home/End, Page up/down, Escape.
    nonisolated private static let caretMovingKeyCodes: Set<UInt16> = [
        UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow), UInt16(kVK_UpArrow), UInt16(kVK_DownArrow),
        UInt16(kVK_Home), UInt16(kVK_End), UInt16(kVK_PageUp), UInt16(kVK_PageDown),
        UInt16(kVK_Escape),
    ]

    // MARK: - Deciding (main actor, between keystrokes)

    /// Debounced verdict: wait for a pause, check the word is still the
    /// word, then spend the dictionary lookup and the Accessibility round
    /// trip. Every keystroke schedules one of these and all but the last
    /// die on the generation check — which is cheaper than it sounds and
    /// far cheaper than checking on every letter.
    private func prepareVerdict(for snapshot: WordBuffer.Word) async {
        try? await Task.sleep(for: Self.verdictDelay)
        guard self.isRunning else { return }
        // The ordinary outcome of a fast typist: the word moved on before
        // the debounce fired. Indistinguishable from a hang without this —
        // the 1 Aug run had rows of silence that were this, not a bug.
        guard LayoutAutoFix.buffer.generation == snapshot.generation else {
            return note("kept typing before the verdict was ready")
        }
        if let reason = contextRefusal() { return note(reason) }
        let judgement = LayoutFix.judge(snapshot.word, exceptions: .shared)
        guard let fix = judgement.fix else {
            noteJudgement(refusal: judgement.refusal)
            return
        }
        // Verify a positive answer, but don't demand that every app expose
        // its text through Accessibility.  Web and Electron editors often
        // identify themselves as editable while refusing AXStringForRange;
        // the old strict gate therefore made automatic fixing appear dead
        // in chats and browser editors.  `confirmBeforeCaret` still
        // rejects an explicit mismatch (autocomplete, text replacement),
        // while the editable-focus and excluded-app checks keep us away
        // from lists, terminals and password fields.
        guard focusIsEditableText() else {
            return note("focus is not editable text", detail: AXFocus.describeFocus())
        }
        guard confirmBeforeCaret(snapshot.word) else {
            return note("what is in front of the caret is not what we typed")
        }
        LayoutAutoFix.buffer.record(
            WordBuffer.Verdict(
                generation: snapshot.generation,
                presses: snapshot.presses,
                originalWord: snapshot.word,
                replacement: fix.text,
                targetLayoutID: fix.target.id,
                at: DispatchTime.now().uptimeNanoseconds
            )
        )
    }

    /// The after-the-fact path: no verdict was ready, the boundary has
    /// already landed, and the word is still in front of the caret.
    private func consider(_ finished: WordBuffer.Word, boundary: Character) {
        guard isRunning else { return }
        if let reason = contextRefusal() { return note(reason) }
        guard LayoutAutoFix.buffer.generation == finished.generation else { return }
        let judgement = LayoutFix.judge(finished.word, exceptions: .shared)
        guard let fix = judgement.fix else {
            noteJudgement(refusal: judgement.refusal)
            return
        }
        guard focusIsEditableText() else {
            return note("focus is not editable text", detail: AXFocus.describeFocus())
        }
        let expected = finished.word + String(boundary)
        guard confirmBeforeCaret(expected) else {
            return note("what is in front of the caret is not what we typed")
        }
        guard replace(presses: finished.presses + 1, with: fix.text + String(boundary)) else {
            return note("couldn't post the replacement")
        }
        settle(
            targetLayoutID: fix.target.id,
            via: "after the fact",
            undo: (finished.word, boundary, fix.text)
        )
    }

    /// The fix key's second source: the word just typed. The user asked,
    /// so this uses `deliberate` (no dictionary needed) and leaves the
    /// boundary alone — there isn't one yet.
    func fixWordInFlight() -> LayoutFix.Fix? {
        guard isRunning, contextAllows() else { return nil }
        guard let candidate = LayoutAutoFix.buffer.wordInFlightOrJustFinished(
            within: Self.recentWordWindow
        ), candidate.word.count > 1 else { return nil }
        guard let fix = LayoutFix.deliberate(candidate.word) else { return nil }
        guard focusIsEditableText() else { return nil }
        // A word already finished has its boundary in front of the caret,
        // so that has to be deleted and put back too. And because the
        // count comes from memory rather than from the screen, this branch
        // demands a positive answer from Accessibility — deleting one
        // character too many here eats whatever preceded the word.
        let trailing = candidate.boundary.map(String.init) ?? ""
        let expected = candidate.word + trailing
        if candidate.boundary != nil {
            guard confirmBeforeCaret(expected) else { return nil }
        } else {
            guard confirmBeforeCaret(expected) else { return nil }
        }
        guard replace(
            presses: candidate.presses + (candidate.boundary == nil ? 0 : 1),
            with: fix.text + trailing
        ) else { return nil }
        settle(targetLayoutID: fix.target.id, via: "fix key")
        return fix
    }

    /// Cheap checks: no I/O, no cross-process calls. Returns the reason
    /// we're standing down, or nil when the context is fine — phrased as
    /// the reason rather than as a Bool so the caller can say WHICH gate
    /// closed without duplicating the conditions.
    private func contextRefusal() -> String? {
        if IsSecureEventInputEnabled() {
            return "secure input is on somewhere on the system"
        }
        // An input method (Japanese, Pinyin, Hangul) composes text from
        // keystrokes on its own; what we saw is not what landed.
        if KeyboardLayouts.shared.isInputMethodActive {
            return "an input method is composing"
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        // The identifier is deliberately NOT logged. The excluded list is
        // terminals, IDEs, password managers and remote desktops, so
        // naming the app would inventory which of those the user runs —
        // into a file they are about to email us. Which app it is, they
        // already know: it is the one they were typing in.
        if frontmost.isEmpty { return "couldn't identify the frontmost app" }
        if Self.isExcluded(frontmost) { return "the frontmost app is on the excluded list" }
        return nil
    }

    private func contextAllows() -> Bool { contextRefusal() == nil }

    /// Log a stand-down reason, de-duplicated per reason.
    ///
    /// `detail` is an autoclosure because the details worth having are
    /// not free: `AXFocus.describeFocus()` is four cross-process calls
    /// with a 200 ms timeout each, on the main actor. Paying for them to
    /// build a line we then drop would slow down exactly the apps being
    /// diagnosed — the slow ones. It also keeps the dedupe key stable,
    /// since the detail is the part that varies between keystrokes.
    private func note(_ reason: String, detail: @autoclosure () -> String = "") {
        let now = Date()
        guard now.timeIntervalSince(lastNotes[reason] ?? .distantPast) > Self.noteInterval else { return }
        lastNotes[reason] = now
        let extra = detail()
        let line = extra.isEmpty ? reason : "\(reason) — \(extra)"
        log.info("Layout fix stood down: \(line, privacy: .public)")
    }

    /// Every reason `judge` can decline, not just the structural ones — a
    /// word the dictionary already knows is the normal case, but "normal"
    /// and "the feature is dead" look identical from the outside if only
    /// one of them is logged. The source layout goes in `detail`, not the
    /// dedupe key: it's what actually explains a wrong call ("typed
    /// latin, but the active layout was already Russian") and it belongs
    /// with a specific instance of the reason, not baked into it.
    private func noteJudgement(refusal: LayoutFix.Refusal?) {
        guard let refusal else { return }
        note(
            "word declined — \(refusal.rawValue)",
            detail: "source=\(KeyboardLayouts.shared.current?.id ?? "?")"
        )
    }

    /// The one check that keeps backspaces out of mail lists, Finder and
    /// single-key-shortcut web apps — where letters are commands and a
    /// Delete is not an edit but a deletion.
    ///
    /// A `.noElement` here is also how we find out an app has no
    /// accessibility tree at all — the Electron default. Ask for one on
    /// the way past: it can't help this keystroke (Chromium builds the
    /// tree asynchronously) but it unblocks the next word, and the ask
    /// happens once per app. Standing down is still the answer for this
    /// one.
    ///
    /// Only `.noElement` earns the ask. A mail list, Finder or a
    /// password field all answer "not editable" from an app that
    /// demonstrably HAS a tree, and the ask is a once-per-app budget
    /// with a 200 ms ceiling — not something to spend on an app that
    /// already answered us.
    private func focusIsEditableText() -> Bool {
        let kind = AXFocus.kind()
        if kind == .editable { return true }
        guard kind == .noElement,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let result = AXFocus.requestAccessibilityTree(forProcessID: pid)
        else { return false }
        // No identifier, for the same reason `contextRefusal` omits it:
        // the report is about to be emailed to us. That this line
        // appears at all is the diagnostic — the app had no tree — and
        // the error code says whether it took the request.
        log.info(
            "Asked the frontmost app to build its accessibility tree — AXError \(result.rawValue, privacy: .public)"
        )
        return false
    }

    /// Does the text in front of the caret actually end with what we
    /// believe we typed? Nil answers (an app that won't say) are allowed
    /// through — most apps outside AppKit won't answer, and refusing them
    /// all would leave the feature working nowhere. A WRONG answer is
    /// refused: that is text replacement or autocomplete having changed
    /// the field under us.
    private func confirmBeforeCaret(_ expected: String) -> Bool {
        guard let actual = AXFocus.textBeforeCaret(count: expected.utf16.count) else { return true }
        return actual == expected
    }

    /// `undo`, when non-nil, is what one keypress needs to reverse THIS
    /// fix — supplied only by the two automatic paths (before-the-
    /// boundary, after-the-fact). The fix key and mouse-selection paths
    /// don't pass one: the user asked for that conversion, so "undo" is
    /// just pressing the key again, which already flips it back.
    fileprivate func settle(
        targetLayoutID: String,
        via path: String,
        undo: (originalWord: String, boundary: Character, replacementWord: String)? = nil
    ) {
        // Our own typing is marked and skipped by the tap, so the buffer
        // would otherwise still hold the pre-fix word — and the fix key
        // must not be able to "fix" it a second time.
        LayoutAutoFix.buffer.discard()
        // Captured BEFORE the switch: this is the layout undo restores,
        // and it only means anything if a switch is about to happen —
        // nil otherwise, matching "nothing to put back".
        var restoreLayoutID: String?
        if settings?.layoutFixSwitchesSource ?? false,
           let target = KeyboardLayouts.shared.installed.first(where: { $0.id == targetLayoutID }) {
            restoreLayoutID = KeyboardLayouts.shared.current?.id
            KeyboardLayouts.shared.select(target)
        }
        UsageStats.shared.recordFixes(polished: 1)
        log.info("Layout fixed (\(path, privacy: .public)) → \(targetLayoutID, privacy: .public)")
        if let undo {
            LayoutFixUndo.shared.record(LayoutFixUndo.Record(
                originalWord: undo.originalWord,
                boundary: undo.boundary,
                replacementWord: undo.replacementWord,
                bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
                restoreLayoutID: restoreLayoutID,
                // Read AFTER `buffer.discard()` above, deliberately —
                // discard() itself bumps the generation, and a value
                // captured before it would already read one stale the
                // instant this record is made.
                generation: LayoutAutoFix.buffer.generation,
                at: Date()
            ))
        }
    }

    /// Delete `presses` key presses' worth of text and type `text`. Used
    /// by the two paths that run on the main actor; the tap has its own
    /// copy that also puts the boundary back. Not `private`: LayoutFix-
    /// Service's undo reuses it — deleting the fix's output and
    /// retyping the original is the same operation as `consider`'s
    /// replacement, just in the other direction.
    func replace(presses: Int, with text: String) -> Bool {
        guard presses > 0, presses <= WordBuffer.maxPresses + 1 else { return false }
        guard let source = Self.eventSource else { return false }
        let units = Array(text.utf16)
        guard !units.isEmpty else { return false }

        var events: [CGEvent] = []
        for _ in 0..<presses {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)
            else { return false }
            events.append(down)
            events.append(up)
        }
        guard let textDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let textUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return false }
        textDown.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        textUp.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        events.append(textDown)
        events.append(textUp)

        for event in events {
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvents.marker)
            event.post(tap: .cgSessionEventTap)
        }
        return true
    }

    // MARK: - Exclusions

    /// Apps where deleting and retyping a word is worse than leaving the
    /// mistake, either because the text is not prose or because the app
    /// rewrites the line under us:
    ///
    ///   - terminals: a wrong "correction" is a command that runs;
    ///   - editors and IDEs: identifiers are misspelled by definition,
    ///     and autocomplete edits the same characters we are editing;
    ///   - password managers and Keychain: nobody's master password
    ///     should pass through a language check;
    ///   - remote desktops and VMs: the keystrokes belong to another
    ///     machine, and the caret is not where we think it is.
    nonisolated static func isExcluded(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return true }
        if excludedBundleIDs.contains(bundleID) { return true }
        return excludedPrefixes.contains { bundleID.hasPrefix($0) }
    }

    nonisolated private static let excludedBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.apple.dt.Xcode",
        "com.sublimetext.4",
        "com.apple.keychainaccess",
        "com.apple.ScreenSharing",
        "com.microsoft.rdc.macos",
        "com.teamviewer.TeamViewer",
        "com.parallels.desktop.console",
        "com.vmware.fusion",
    ]

    nonisolated private static let excludedPrefixes: [String] = [
        "com.jetbrains.",       // IntelliJ, PyCharm, WebStorm, …
        "com.google.android.studio",
        "com.1password.",
        "com.agilebits.onepassword",
        "com.bitwarden.",
        "com.valvesoftware.steam",
    ]
}

// MARK: - The tap's thread

/// Owns the thread the event tap runs on. Its own run loop, because an
/// active tap makes every keystroke on the Mac wait for our callback and
/// the main actor is busy with recording, transcription and SwiftUI.
nonisolated private final class TapHost: @unchecked Sendable {
    /// CF types carry no `Sendable` conformance and this one doesn't need
    /// it: the source is handed to exactly one thread and never read again.
    /// The box is what says so out loud — `OSAllocatedUnfairLock` would
    /// refuse the type outright.
    private final class Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private let started = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Started once per process, and deliberately without a `stop`: taking
    /// a run loop down while the window server may be inside our callback
    /// is a race against nothing. Disabling the tap is what "off" means,
    /// and a parked thread costs no CPU.
    func startIfNeeded(source: CFRunLoopSource) {
        let shouldStart = started.withLock { flag in
            guard !flag else { return false }
            flag = true
            return true
        }
        guard shouldStart else { return }

        let box = Box(source)
        let thread = Thread {
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, box.value, .commonModes)
            // Parks here for the life of the process, waking only to hand
            // events to the tap callback.
            CFRunLoopRun()
        }
        thread.name = "app.essazanov.Daisy.layout-tap"
        // The keyboard waits on this thread. Nothing on the machine has a
        // better claim to being scheduled.
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}

// MARK: - The word, and the verdict about it

/// The one word being typed, plus the decision about what to do if it
/// ends now. Behind a lock: the tap's thread reads and writes it, the
/// main actor writes the verdict.
///
/// Tracks KEY PRESSES as well as characters, because the number of
/// backspaces needed is the number of presses: a layout whose keys emit
/// combining marks can merge two presses into one `Character`, and
/// deleting by character count would leave a stray mark glued to the
/// correction.
///
/// `generation` counts every key press the tap saw. Anything decided on
/// the main actor carries the generation it was decided at, and is
/// refused if it has moved — the user kept typing while we were thinking.
nonisolated final class WordBuffer: @unchecked Sendable {
    struct Word: Sendable {
        let word: String
        let presses: Int
        let generation: UInt64
    }

    /// "If the word ends now, delete `presses` and type `replacement`."
    /// Computed between keystrokes so the tap has nothing to think about.
    struct Verdict: Sendable {
        let generation: UInt64
        let presses: Int
        /// The word as typed, filled from the snapshot that produced
        /// this verdict — `LayoutFixUndo` needs it to retype on undo,
        /// and `replacement` alone can't be reversed without it.
        let originalWord: String
        let replacement: String
        let targetLayoutID: String
        /// When it was decided, `DispatchTime` nanoseconds. The generation
        /// check only proves nothing was TYPED since; a document can also
        /// change without a keystroke — a collaborative edit, another
        /// automation tool, the app's own autocorrect — so a verdict also
        /// expires.
        let at: UInt64
    }

    private struct State {
        var word = ""
        var presses = 0
        var generation: UInt64 = 0
        var verdict: Verdict?
        /// Last non-empty word and when it was dropped, in `DispatchTime`
        /// nanoseconds. The fix key needs this: its own key-down reaches
        /// the tap first and clears the buffer, so by the time the handler
        /// runs the word is already gone.
        /// The last word that was dropped, what followed it, and when.
        /// The boundary matters: after "privet." the caret is past the
        /// dot, so fixing that word means deleting one more press and
        /// typing the dot back.
        var recent: (word: String, presses: Int, boundary: Character?, at: UInt64)?
    }

    static let maxPresses = 64
    /// How long a verdict stays good. Long enough to cover a pause
    /// mid-word, short enough that it can't be applied to a field someone
    /// walked away from.
    private static let verdictLifetime: UInt64 = 5_000_000_000
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    var generation: UInt64 { lock.withLock { $0.generation } }

    /// Append and return the word as it now stands, so the caller can ask
    /// for a verdict without a second lock acquisition.
    func append(_ character: Character) -> Word {
        lock.withLock { state in
            state.generation &+= 1
            state.verdict = nil
            if state.presses < Self.maxPresses {
                state.word.append(character)
                state.presses += 1
            }
            return Word(word: state.word, presses: state.presses, generation: state.generation)
        }
    }

    /// True if something was actually removed — false means the caret is
    /// somewhere we weren't tracking.
    func deleteLast() -> Bool {
        lock.withLock { state in
            state.generation &+= 1
            state.verdict = nil
            guard state.presses > 0, !state.word.isEmpty else { return false }
            state.word.removeLast()
            state.presses -= 1
            return true
        }
    }

    /// Forget the word, but keep it as the fix key's candidate — used
    /// where the keystroke means "not typing" rather than "the caret
    /// moved". The fix key's own chord lands here, which is the only
    /// reason the candidate exists.
    func clear() {
        lock.withLock { state in
            state.generation &+= 1
            state.verdict = nil
            stash(&state, boundary: nil)
            state.word = ""
            state.presses = 0
        }
    }

    /// Forget the word AND the candidate — the caret is no longer behind
    /// what we were tracking, so retyping it later would eat something
    /// else.
    func discard() {
        lock.withLock { state in
            state.generation &+= 1
            state.verdict = nil
            state.word = ""
            state.presses = 0
            state.recent = nil
        }
    }

    /// Read and clear — the word is finished. `boundary` is what ended it,
    /// remembered so the fix key can put it back.
    func take(boundary: Character? = nil) -> Word? {
        lock.withLock { state in
            state.generation &+= 1
            state.verdict = nil
            stash(&state, boundary: boundary)
            let finished = Word(word: state.word, presses: state.presses, generation: state.generation)
            state.word = ""
            state.presses = 0
            return finished.word.isEmpty ? nil : finished
        }
    }

    func record(_ verdict: Verdict) {
        lock.withLock { state in
            // Only if nothing has been typed since it was decided.
            guard state.generation == verdict.generation else { return }
            state.verdict = verdict
        }
    }

    /// The verdict, if it still describes what is on screen. Read on the
    /// tap's thread, in the middle of a key press: one lock, no work.
    func matchingVerdict() -> Verdict? {
        let now = DispatchTime.now().uptimeNanoseconds
        return lock.withLock { state in
            guard let verdict = state.verdict,
                  verdict.generation == state.generation,
                  verdict.presses == state.presses,
                  now &- verdict.at < Self.verdictLifetime else { return nil }
            return verdict
        }
    }

    /// What the fix key should act on: the word being typed, or the one
    /// that was dropped moments ago (by the fix key's own keystroke).
    /// What the fix key should act on: the word being typed, or the one
    /// dropped moments ago — by the fix key's own keystroke, which reaches
    /// the tap before the hotkey handler runs. `boundary` is nil for a word
    /// still in flight and set for a finished one, and the caller must
    /// account for it: the caret is past it.
    func wordInFlightOrJustFinished(
        within window: TimeInterval
    ) -> (word: String, presses: Int, boundary: Character?)? {
        lock.withLock { state in
            if !state.word.isEmpty {
                return (state.word, state.presses, nil)
            }
            guard let recent = state.recent else { return nil }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- recent.at) / 1_000_000_000
            guard elapsed <= window else { return nil }
            return (recent.word, recent.presses, recent.boundary)
        }
    }

    private func stash(_ state: inout State, boundary: Character?) {
        guard !state.word.isEmpty else { return }
        state.recent = (state.word, state.presses, boundary, DispatchTime.now().uptimeNanoseconds)
    }
}
