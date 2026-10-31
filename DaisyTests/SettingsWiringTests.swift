//
//  SettingsWiringTests.swift
//  DaisyTests
//
//  A changed setting is applied by `SettingsWiring`, which lives as long
//  as the app — not by the main window's `.onChange` handlers, gone with
//  the window while the Settings window stays open (review H1, 31.10).
//

import Foundation
import Observation
import Testing
@testable import Daisy

@Observable
@MainActor
private final class Knob {
    var value = 0
    var other = ""
}

@MainActor
struct SettingsWiringTests {
    /// Lets the Observation callback's hop to the main actor run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test func aChangeIsAppliedOnce() async {
        let knob = Knob()
        var calls = 0
        let watch = ObservedValue({ knob.value }) { calls += 1 }
        defer { watch.cancel() }

        knob.value = 1
        await settle()
        #expect(calls == 1)

        knob.value = 2
        await settle()
        #expect(calls == 2)
    }

    @Test func writesBeforeTheReadCollapseAndAWriteBackIsNone() async {
        let knob = Knob()
        var calls = 0
        let watch = ObservedValue({ knob.value }) { calls += 1 }
        defer { watch.cancel() }

        knob.value = 1
        knob.value = 2
        await settle()
        #expect(calls == 1)

        knob.value = 3
        knob.value = 2
        await settle()
        #expect(calls == 1)
    }

    @Test func anotherPropertyDoesNotFire() async {
        let knob = Knob()
        var calls = 0
        let watch = ObservedValue({ knob.value }) { calls += 1 }
        defer { watch.cancel() }

        knob.other = "x"
        await settle()
        #expect(calls == 0)
    }

    /// A change the action itself makes is seen too.
    @Test func aChangeMadeByTheActionIsSeen() async {
        let knob = Knob()
        var seen: [Int] = []
        let watch = ObservedValue({ knob.value }) {
            seen.append(knob.value)
            if knob.value == 1 { knob.value = 5 }
        }
        defer { watch.cancel() }

        knob.value = 1
        await settle()
        await settle()
        #expect(seen == [1, 5])
    }

    @Test func aCancelledWatchStops() async {
        let knob = Knob()
        var calls = 0
        let watch = ObservedValue({ knob.value }) { calls += 1 }
        watch.cancel()

        knob.value = 1
        await settle()
        #expect(calls == 0)
    }

    /// The main window no longer re-wires settings; the app-long observer
    /// does, started next to the initial wiring.
    @Test func theWiringLivesOutsideTheMainWindow() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let main = try String(contentsOf: root.appendingPathComponent("Daisy/MainView.swift"), encoding: .utf8)
        #expect(!main.contains("ServiceWiring.apply"))
        let app = try String(contentsOf: root.appendingPathComponent("Daisy/DaisyApp.swift"), encoding: .utf8)
        #expect(app.contains("SettingsWiring.start(settings: s, session: sess)"))
    }

    // MARK: - Toasts in one window

    /// The onboarding ↔ shell swap: the new branch may appear before the
    /// old one disappears, or after — the main window is open either way.
    @Test func theMainWindowStaysOpenThroughABranchSwap() {
        let nav = AppNavigation.shared
        let before = nav.mainWindowViews
        defer { #expect(nav.mainWindowViews == before) }

        nav.mainWindowViewAppeared()          // shell
        nav.mainWindowViewAppeared()          // tour appears first…
        nav.mainWindowViewDisappeared()       // …then the shell goes
        #expect(nav.mainWindowIsOpen)
        nav.mainWindowViewDisappeared()       // the tour goes (window closed)
        #expect(nav.mainWindowViews == before)
    }

    @Test func aToastShowsInExactlyOneWindow() {
        // Settings key → there; otherwise the main window while it is open.
        #expect(AppNavigation.toastsInSettings(settingsIsKey: true, mainIsOpen: true))
        #expect(!AppNavigation.toastsInSettings(settingsIsKey: false, mainIsOpen: true))
        // Main window closed → Settings, key or not.
        #expect(AppNavigation.toastsInSettings(settingsIsKey: false, mainIsOpen: false))
        #expect(AppNavigation.toastsInSettings(settingsIsKey: true, mainIsOpen: false))
    }
}
