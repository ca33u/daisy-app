//
//  PasteboardProxy.swift
//  Daisy
//
//  Borrowing the user's clipboard to read or replace a selection in
//  another app, and giving it back.
//
//  macOS has no API to read the selection of another application, so
//  every app that acts on "what I have selected" does the same dance:
//  snapshot the pasteboard, synthesize ⌘C, read, act, write, synthesize
//  ⌘V, put the snapshot back. The dance is the whole feature — get it
//  wrong and you have destroyed something the user copied ten minutes
//  ago and expected to still be there.
//
//  This lives in ONE place because Daisy now does it from two features
//  (rewrite-in-my-voice and the layout fixer) and two independent
//  restore timers racing over one pasteboard is a bug that only shows
//  up when someone uses both within a second and a half.
//
//  `Borrow` is deliberately a value the caller has to carry: it makes
//  "who owes the clipboard back" a thing the compiler helps with rather
//  than a comment.
//

import AppKit
import Carbon.HIToolbox
import os

@MainActor
final class PasteboardProxy {
    static let shared = PasteboardProxy()

    /// What the pasteboard held before we took it.
    struct Borrow {
        fileprivate let snapshot: [[String: Data]]
    }

    /// How long we wait for the frontmost app to service the ⌘C before
    /// reading the pasteboard.
    nonisolated static let copyGraceSeconds: TimeInterval = 0.25
    /// Restore delay after a paste. Short — the ⌘V lands within a beat
    /// and the user's own clipboard should come straight back.
    private static let restoreSeconds: TimeInterval = 1.5

    /// A `Task`, not a `Timer`: `Timer.scheduledTimer` runs in the
    /// run loop's default mode only, so opening a menu or dragging a
    /// window would hold the user's clipboard hostage until they let go.
    private var restoreTask: Task<Void, Never>?
    private var pendingSnapshot: [[String: Data]]?
    private var pendingChangeCount = 0

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Pasteboard")

    private init() {}

    // MARK: - Borrowing

    /// Take the clipboard: cancel any restore still pending, snapshot
    /// what is there, and leave it empty so a failed ⌘C is detectable.
    func borrow() -> Borrow {
        cancelPendingRestore()
        let snapshot = captureClipboard()
        NSPasteboard.general.clearContents()
        return Borrow(snapshot: snapshot)
    }

    /// Synthesize ⌘C and read what the frontmost app put on the
    /// clipboard. Nil when nothing arrived — no selection, or an app
    /// that doesn't answer ⌘C.
    ///
    /// Polled rather than slept once: a slow app (Word, a heavy web app,
    /// a big selection) can service the ⌘C after a fixed grace period has
    /// expired, and then its copy lands AFTER we have restored the
    /// clipboard — silently replacing what the user had copied with what
    /// they had selected. Polling ends as soon as the copy appears, so
    /// the common case is faster too.
    func copySelection(_ borrow: Borrow, grace: TimeInterval = PasteboardProxy.copyGraceSeconds) async -> String? {
        let before = NSPasteboard.general.changeCount
        postCommandKeystroke(CGKeyCode(kVK_ANSI_C))
        let deadline = ContinuousClock.now.advanced(by: .seconds(grace))
        while NSPasteboard.general.changeCount == before, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
        guard NSPasteboard.general.changeCount != before else { return nil }
        // Preserve the selection exactly: it is about to be replaced in
        // full. Trimming here would delete a selected trailing space and
        // merge the corrected word with the word after it.
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Write `text`, synthesize ⌘V over the still-active selection, and
    /// schedule the borrow's return. The restore is skipped if the user
    /// copies something else in the meantime — their copy wins over our
    /// courtesy.
    func pasteAndReturn(_ text: String, _ borrow: Borrow) {
        // Not typing, as far as the layout watcher's tap can tell.
        LayoutAutoFix.forgetAfterOwnInsert()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        pendingChangeCount = NSPasteboard.general.changeCount
        postCommandKeystroke(CGKeyCode(kVK_ANSI_V))

        pendingSnapshot = borrow.snapshot
        restoreTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.restoreSeconds))
            guard !Task.isCancelled, let self else { return }
            defer { self.pendingSnapshot = nil; self.restoreTask = nil }
            guard let snapshot = self.pendingSnapshot,
                  NSPasteboard.general.changeCount == self.pendingChangeCount else { return }
            self.restore(snapshot)
        }
    }

    /// Give the clipboard back untouched — the failure path.
    func giveBack(_ borrow: Borrow) {
        restore(borrow.snapshot)
    }

    // MARK: - Keystrokes

    /// Post ⌘+key as a down/up pair wrapped in ⌘ down/up.
    func postCommandKeystroke(_ key: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            log.error("Couldn't create CGEventSource for keystroke")
            return
        }
        let command = CGKeyCode(kVK_Command)
        guard
            let commandDown = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false),
            let commandUp = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false)
        else {
            log.error("CGEvent construction returned nil")
            return
        }
        // Flags set explicitly on all four, not just the two that need
        // ⌘: a synthesized event inherits whatever the user is physically
        // holding, and a stray Option or Control turns a paste into
        // something else entirely.
        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        commandUp.flags = []
        // Marked as ours so Daisy's own keyboard tap ignores what Daisy
        // types (see LayoutAutoFix — an unmarked ⌘V would come back as
        // two keystrokes to analyse).
        for event in [commandDown, keyDown, keyUp, commandUp] {
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvents.marker)
            event.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Clipboard snapshot

    private func captureClipboard() -> [[String: Data]] {
        guard let items = NSPasteboard.general.pasteboardItems else { return [] }
        return items.map { item in
            var out: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { out[type.rawValue] = data }
            }
            return out
        }
    }

    private func restore(_ snapshot: [[String: Data]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.map { entry in
            let item = NSPasteboardItem()
            for (raw, data) in entry {
                item.setData(data, forType: NSPasteboard.PasteboardType(raw))
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    /// Settle any outstanding borrow BEFORE a new one starts. Dropping
    /// the pending snapshot instead would lose the user's clipboard for
    /// good: two fixes a second apart, and what they had copied is
    /// replaced by our first correction forever.
    private func cancelPendingRestore() {
        restoreTask?.cancel()
        restoreTask = nil
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        // Only if the user hasn't copied something themselves in the
        // meantime — their copy outranks our courtesy.
        guard NSPasteboard.general.changeCount == pendingChangeCount else { return }
        restore(snapshot)
    }
}

/// Tag Daisy puts on every keyboard event it synthesizes, so Daisy's own
/// keyboard tap can tell the app's typing from the user's. Without it
/// the layout fixer would read its own corrections back as freshly typed
/// text and consider fixing them again.
nonisolated enum SyntheticEvents {
    /// Arbitrary but distinctive — `eventSourceUserData` is a free field
    /// on CGEvent that survives posting.
    static let marker: Int64 = 0x4441_4953_5900   // "DAISY"

    static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}
