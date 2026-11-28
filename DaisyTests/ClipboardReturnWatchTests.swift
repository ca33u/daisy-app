// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  ClipboardReturnWatchTests.swift
//  DaisyTests
//
//  Which key press is the person pasting while Daisy holds their clipboard
//  (`OwnPaste`). The tap and the clipboard itself aren't touched.
//

import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import Daisy

@Suite(.serialized)
struct ClipboardReturnWatchTests {
    private func isPaste(_ key: Int = kVK_ANSI_V, _ characters: String = "v",
                         _ flags: CGEventFlags = .maskCommand, ours: Bool = false) -> Bool {
        OwnPaste.isPaste(keyCode: key, characters: characters, flags: flags, isOurs: ours)
    }

    @Test func commandVIsAPaste() {
        #expect(isPaste())
        #expect(isPaste(kVK_ANSI_V, "м"))          // Russian layout
        #expect(isPaste(kVK_ANSI_Period, "v"))     // Dvorak
        #expect(isPaste(kVK_ANSI_V, "V", [.maskCommand, .maskShift]))
        #expect(isPaste(kVK_ANSI_V, "v", [.maskCommand, .maskShift, .maskAlternate]))
        #expect(isPaste(kVK_ANSI_V, ""))
    }

    /// Daisy's own ⌘V is what the wait is for.
    @Test func daisysOwnIsNot() {
        #expect(!isPaste(ours: true))
    }

    @Test func otherKeysAreNot() {
        #expect(!isPaste(kVK_ANSI_V, "v", []))
        #expect(!isPaste(kVK_ANSI_C, "c"))
        #expect(!isPaste(kVK_Return, "\r", []))
        // «Paste last dictation» on ⌃⌥V, and any ⌃⌘V.
        #expect(!isPaste(kVK_ANSI_V, "v", [.maskControl, .maskAlternate]))
        #expect(!isPaste(kVK_ANSI_V, "v", [.maskControl, .maskCommand]))
    }

    // MARK: - What goes back (no tap in the test host)

    @MainActor private final class Returned { var names: [String] = [] }

    @MainActor @Test func aPasteReturnsWhatWasBorrowedBeforeIt() {
        let watch = ClipboardReturnWatch.shared
        let returned = Returned()
        let start = ContinuousClock.now
        let old = watch.arm(at: start) { returned.names.append("old") }
        let new = watch.arm(at: start + .seconds(2)) { returned.names.append("new") }
        defer { watch.disarm(old); watch.disarm(new) }

        // Daisy's own ⌘V may not have been read yet.
        watch.personPasted(at: start + .seconds(OwnPaste.settle / 2))
        #expect(returned.names.isEmpty)
        // The newer borrow's ⌘V came after this key.
        watch.personPasted(at: start + .seconds(1))
        #expect(returned.names == ["old"])
        watch.personPasted(at: start + .seconds(1))
        #expect(returned.names == ["old"])
        watch.personPasted(at: start + .seconds(3))
        #expect(returned.names == ["old", "new"])
        #expect(!watch.isWatching)
    }

    @MainActor @Test func aReturnedOrEndedBorrowIsNotReturnedAgain() {
        let watch = ClipboardReturnWatch.shared
        let returned = Returned()
        let start = ContinuousClock.now
        var token: UUID?
        token = watch.arm(at: start) {
            returned.names.append("once")
            watch.disarm(token)
        }
        watch.personPasted(at: start + .seconds(1))
        watch.personPasted(at: start + .seconds(2))
        #expect(returned.names == ["once"])
        let ended = watch.arm(at: start) { returned.names.append("ended") }
        watch.disarm(ended)
        watch.disarm(ended)
        watch.disarm(nil)
        watch.personPasted(at: start + .seconds(1))
        #expect(returned.names == ["once"])
        #expect(!watch.isWatching)
    }
}
