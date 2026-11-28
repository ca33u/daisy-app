// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  AccessibilityPrompt.swift
//  Daisy
//
//  The one place Daisy asks macOS for Accessibility.
//
//  `AXIsProcessTrustedWithOptions` with the prompt option puts up the
//  system window that sends the person to System Settings. Five places
//  ask (the Permissions rows and the tour, dictation paste, the layout
//  fix and its as-you-type watcher, the selection rewrite), and each used
//  to make the call itself.
//
//  The test host never asks. DaisyTests run inside a debug build of
//  Daisy.app, which macOS treats as a different app from the Daisy in
//  /Applications (another signing certificate): it is never trusted, so
//  any of those paths reached there took its «not trusted» branch and
//  asked. One was reached at every launch with no key pressed: the
//  as-you-type watcher, on in the real settings the host reads. macOS
//  leaves the window up until someone closes it, and a day of test runs
//  left Egor a screen of «Daisy would like to control this Mac» (18.11).
//  The host no longer starts the watcher either (`ServiceWiring`); this
//  is the second lock, for whatever reaches one of the five later.
//

import ApplicationServices
import Foundation

nonisolated enum AccessibilityPrompt {
    /// Shows the system Accessibility window. There is no completion: the
    /// grant happens in System Settings, and callers see it on the next
    /// `AXIsProcessTrusted()`.
    ///
    /// The two parameters are for tests; callers pass none.
    static func show(isTestHost: Bool = TestHost.isActive, ask: () -> Void = askSystem) {
        guard !isTestHost else { return }
        ask()
    }

    private static func askSystem() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }
}
