//
//  WhatsNewTests.swift
//  DaisyTests
//
//  «What's New in Daisy» (Egor 22.10): once per edition after an update,
//  never on a fresh install, with the person's own key on the keycaps.
//

import Foundation
import Testing
@testable import Daisy

@MainActor
struct WhatsNewTests {
    /// A throwaway defaults domain, removed when the test is done.
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "whatsnew-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        body(d)
    }

    @Test func opensOnceAfterAnUpdate() { withDefaults { d in
        #expect(WhatsNew.shouldOpen(hasShownFirstRun: true, defaults: d))
        WhatsNew.markSeen(defaults: d)
        #expect(!WhatsNew.shouldOpen(hasShownFirstRun: true, defaults: d))
        // A later edition opens again.
        d.set("an-older-edition", forKey: WhatsNew.seenKey)
        #expect(WhatsNew.shouldOpen(hasShownFirstRun: true, defaults: d))
    } }

    @Test func notDuringOnboarding() { withDefaults { d in
        #expect(!WhatsNew.shouldOpen(hasShownFirstRun: false, defaults: d))
        // Finishing onboarding marks it seen (FirstRunView.finish).
        WhatsNew.markSeen(defaults: d)
        #expect(!WhatsNew.shouldOpen(hasShownFirstRun: true, defaults: d))
    } }

    @Test func keycapsShowThePersonsKey() {
        #expect(WhatsNewKeycaps.caps(for: .ctrlOpt).map(\.glyph) == ["⌃", "⌥"])
        #expect(WhatsNewKeycaps.caps(for: .rightCommand).map(\.glyph) == ["⌘"])
        #expect(WhatsNewKeycaps.caps(for: .ctrlOptD).map(\.glyph) == ["⌃", "⌥", "D"])
        #expect(WhatsNewKeycaps.caps(for: .ctrlShiftD).map(\.glyph) == ["⌃", "⇧", "D"])
        #expect(WhatsNewKeycaps.caps(for: .ctrlOptCmdD).map(\.glyph) == ["⌃", "⌥", "⌘", "D"])
        #expect(WhatsNewKeycaps.caps(for: .fn).map(\.glyph) == ["fn"])
    }

    @Test func scriptsHoldTogether() {
        for script in WhatsNewScript.all {
            #expect(script.still < script.duration)
            #expect(script.keyDown.allSatisfy { $0.upperBound < script.duration })
            if let speech = script.speech { #expect(script.keyDown.contains { $0.lowerBound < speech.lowerBound }) }
        }
    }
}
