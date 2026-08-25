//
//  DiscardRecordingPrompt.swift
//  Daisy
//
//  The confirmation gate in front of `RecordingSession.discard()` —
//  the one code path allowed to delete a live recording on purpose
//  (husk-cleanup and crash-recovery must never delete on their own;
//  see the husk-deletes-live-recording incident).
//
//  It lives on its own because there is now more than one door into
//  discard: the floating widget's right-click menu and the sidebar's
//  "Stop & discard" capsule. Two doors must not mean two wordings, two
//  default buttons, or — the one that actually loses an hour of audio —
//  one door that forgets to ask.
//

import AppKit

@MainActor
enum DiscardRecordingPrompt {
    /// Ask, then throw the session away if the user says so.
    ///
    /// A plain `NSAlert` on purpose. The widget's caller is a 60 pt
    /// borderless non-activating panel, and SwiftUI presentation from
    /// that surface (sheet / confirmationDialog) is exactly what
    /// produced three invisible bubbles in a row on 2026-08-21 — an
    /// alert runs as its own app-modal window and cannot fail to
    /// appear. The sidebar caller could host a sheet, but a second
    /// dialog style for the same question would be the wrong kind of
    /// variety.
    ///
    /// The key equivalents are moved by hand: NSAlert makes the FIRST
    /// button added the default one, and here that button deletes an
    /// hour of audio. Button order stays (destructive first, which is
    /// where macOS puts it), only Return moves — so someone dismissing
    /// a dialog by reflex keeps their recording.
    static func confirmAndDiscard(_ session: RecordingSession) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard this recording?")
        alert.informativeText = String(localized: "Audio, transcript and screenshots from this session will not be saved.")
        alert.alertStyle = .warning
        let discard = alert.addButton(withTitle: String(localized: "Discard recording"))
        discard.hasDestructiveAction = true
        let keep = alert.addButton(withTitle: String(localized: "Keep recording"))
        discard.keyEquivalent = ""
        keep.keyEquivalent = "\r"
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await session.discard() }
        }
    }
}
