//
//  ClipboardReturnWatch.swift
//  Daisy
//
//  The person's own ⌘V, pressed while Daisy still holds their clipboard,
//  pastes what they had copied.
//
//  Two roads borrow the clipboard: a dictation into an app that names no
//  focused field (`DictationPaste`, four seconds) and the rewrite and
//  layout fixes (`PasteboardProxy`, one and a half). The wait is for the
//  app in front to read Daisy's text, since ⌘V is posted and nothing says
//  when it was served. A person faster than the wait got Daisy's text a
//  second time: copy, dictate, ⌘V, send — and what went out was the
//  dictation instead of what had been copied (Egor, 23.11).
//
//  So from Daisy's ⌘V until the clipboard is back, a keyboard tap looks for one thing: a paste
//  that isn't Daisy's own. The clipboard goes back first, then the
//  keystroke goes on. The text of a dictation that didn't land is in the
//  history and on the «paste last dictation» shortcut; it isn't what a
//  ⌘V means to someone who copied something else.
//
//  A paste from a menu isn't seen here, nor one in a field with secure
//  input: those get what is on the clipboard, until the wait is over.
//

import AppKit
import Carbon.HIToolbox
import os

/// Whether a key press is the person pasting.
nonisolated enum OwnPaste {
    /// ⌘V, with Shift or Option as in «Paste and Match Style»; by the
    /// key and by the letter it types, for layouts where they part. With
    /// Control it's some app's own shortcut.
    static func isPaste(keyCode: Int, characters: String, flags: CGEventFlags, isOurs: Bool) -> Bool {
        guard !isOurs, flags.contains(.maskCommand), !flags.contains(.maskControl) else { return false }
        return keyCode == kVK_ANSI_V || characters.lowercased() == "v"
    }

    /// How long after Daisy's own ⌘V the clipboard stays as it is whatever
    /// is pressed: the app in front has yet to read it. A person who
    /// reaches for ⌘V sooner than this gets Daisy's text, as before.
    static let settle: TimeInterval = 0.4
}

@MainActor
final class ClipboardReturnWatch {
    static let shared = ClipboardReturnWatch()

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Pasteboard")
    private var tap: CFMachPort?
    private let host = TapHost(name: "app.essazanov.Daisy.paste-tap")
    private struct Borrow {
        let since: ContinuousClock.Instant
        let giveBack: @MainActor () -> Void
    }
    private var borrows: [UUID: Borrow] = [:]

    /// Read by the tap's thread: when the oldest borrow went out, nil when
    /// there is none.
    nonisolated private static let oldest = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

    /// Counts the changes of `borrows`: the tap goes off only when none
    /// came after the one that emptied it.
    private var change = 0

    private init() {}

    var isWatching: Bool { !borrows.isEmpty }

    /// Call right after posting Daisy's ⌘V. `giveBack` puts the person's
    /// clipboard back (and is expected to leave it alone when they have
    /// copied something since). Ends with `disarm`.
    func arm(at since: ContinuousClock.Instant = .now, giveBack: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        borrows[token] = Borrow(since: since, giveBack: giveBack)
        borrowsChanged()
        startTap()
        return token
    }

    func disarm(_ token: UUID?) {
        guard let token, borrows.removeValue(forKey: token) != nil else { return }
        borrowsChanged()
    }

    /// The person pressed ⌘V at `pressed`: what was borrowed long enough
    /// before it goes back. A borrow newer than that (a dictation pasted
    /// between the key and this call) has its own ⌘V still to be read.
    func personPasted(at pressed: ContinuousClock.Instant) {
        let due = borrows.filter { pressed - $0.value.since >= .seconds(OwnPaste.settle) }
        guard !due.isEmpty else { return }
        for token in due.keys { borrows[token] = nil }
        log.notice("The person's own paste: giving the clipboard back")
        due.values.forEach { $0.giveBack() }
        borrowsChanged()
    }

    private func borrowsChanged() {
        let since = borrows.values.map(\.since).min()
        Self.oldest.withLock { $0 = since }
        change += 1
        guard borrows.isEmpty else { return }
        let asOf = change
        // Not now: the tap's thread may be holding the very keystroke this
        // answers, and what becomes of it when its tap goes off isn't
        // documented. Past `patience` it has been let go.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.patience * 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.change == asOf, let tap = self.tap else { return }
                CGEvent.tapEnable(tap: tap, enable: false)
            }
        }
    }

    private func startTap() {
        // An active tap needs Accessibility, the grant Daisy's ⌘V needed a
        // moment ago. Without it there is only the wait.
        guard !TestHost.isActive, AXIsProcessTrusted() else { return }
        if let tap, CFMachPortIsValid(tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            return
        }
        // A tap dies with the Accessibility grant; the thread serves the
        // first one only, so after a revoke and a new grant this is off
        // until Daisy is opened again.
        guard tap == nil, let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: 1 << CGEventType.keyDown.rawValue,
            callback: daisyPasteTapCallback,
            userInfo: nil
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            log.error("No keyboard tap for the clipboard's return")
            return
        }
        self.tap = tap
        CGEvent.tapEnable(tap: tap, enable: true)
        // Its own thread, as the layout watcher's: the keyboard waits on
        // the callback, and the main actor may be busy.
        host.startIfNeeded(source: source)
    }

    /// On the tap's thread. Every other key passes at once; the one paste
    /// waits for the main actor to put the clipboard back, and not longer
    /// than `patience` — past that it goes on and pastes what is there.
    nonisolated static func sawKey(_ event: CGEvent) {
        let pressed = ContinuousClock.now
        guard let since = oldest.withLock({ $0 }), pressed - since >= .seconds(OwnPaste.settle) else { return }
        var length = 0
        var units = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        guard OwnPaste.isPaste(
            keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            characters: String(utf16CodeUnits: units, count: min(length, units.count)),
            flags: event.flags,
            isOurs: SyntheticEvents.isOurs(event)
        ) else { return }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { shared.personPasted(at: pressed) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + patience)
    }

    nonisolated private static let patience: TimeInterval = 0.25
}

private nonisolated func daisyPasteTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .keyDown { ClipboardReturnWatch.sawKey(event) }
    return Unmanaged.passUnretained(event)
}
