//
//  UpdateDuringRecordingTests.swift
//  DaisyTests
//
//  Бэклог 16 Р-1. An update arriving in the middle of a meeting is the
//  same class of data loss we spent September on, except it comes from
//  outside the app: one click on "Install and Relaunch" and the
//  recording is gone. These are the guards.
//

import Foundation
import Sparkle
import Testing
@testable import Daisy

@Suite("An update never ends a recording")
struct UpdateDuringRecordingTests {

    @Test func nothingIsBlockedWhenNoAudioIsInFlight() {
        for kind in [SPUUpdateCheck.updates, .updatesInBackground, .updateInformation] {
            #expect(UpdateGate.mayCheck(kind: kind, whileCapturing: false))
        }
    }

    /// The one that matters: a check nobody asked for must not put a
    /// dialog on screen mid-meeting, because its default button
    /// relaunches the app.
    @Test func aScheduledCheckWaitsForTheRecordingToEnd() {
        #expect(!UpdateGate.mayCheck(kind: .updatesInBackground, whileCapturing: true))
    }

    /// A check the person started is not blocked — they are at the
    /// keyboard and are warned. Blocking it would just look broken.
    @Test func aCheckSomebodyAskedForStillRuns() {
        #expect(UpdateGate.mayCheck(kind: .updates, whileCapturing: true))
        #expect(UpdateGate.mayCheck(kind: .updateInformation, whileCapturing: true))
    }

    @MainActor
    @Test func anInstalledUpdateWaitsAndThenRelaunches() async throws {
        let hold = PostponedRelaunch()
        var busy = true
        hold.isBusy = { busy }
        var relaunched = 0
        hold.hold({ relaunched += 1 }, pollEvery: .milliseconds(20))

        try await Task.sleep(for: .milliseconds(120))
        #expect(relaunched == 0, "Relaunched while audio was still in flight")
        #expect(hold.isWaiting)

        busy = false
        try await Task.sleep(for: .milliseconds(150))
        #expect(relaunched == 1)
        #expect(!hold.isWaiting)
    }

    /// Dropping Sparkle's block would leave the update staged forever,
    /// so the hold releases exactly once and never loses it.
    @MainActor
    @Test func theInstallerBlockIsReleasedOnceAndNeverLost() async throws {
        let hold = PostponedRelaunch()
        hold.isBusy = { false }
        var relaunched = 0
        hold.hold({ relaunched += 1 }, pollEvery: .milliseconds(20))
        try await Task.sleep(for: .milliseconds(120))
        hold.release()
        hold.release()
        #expect(relaunched == 1)
    }
}
