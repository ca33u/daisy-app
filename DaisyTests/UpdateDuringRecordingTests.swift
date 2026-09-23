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

/// Инцидент 23.09 п.7. Both users who lost meetings were weeks behind:
/// the fixes were downloaded, staged for "Install on Quit", and a
/// menu-bar app is never quit. The staged update is now offered when
/// nothing is recording — and only then.
@Suite("A staged update is offered, never forced, never mid-recording")
struct StagedUpdateOfferTests {
    @MainActor
    @Test func nothingIsOfferedWhileRecording() {
        let offer = StagedUpdateOffer()
        var busy = true
        var offers = 0
        offer.isBusy = { busy }
        offer.present = { _ in offers += 1 }
        offer.stage(version: "1.0.8.2", install: {}, pollEvery: .seconds(3600))
        offer.offerIfDue()
        #expect(offers == 0)
        busy = false
        offer.offerIfDue()
        #expect(offers == 1)
    }

    /// Asked once, then left alone for an hour — an offer that repeats
    /// every thirty seconds is a nag, and nags get dismissed unread.
    @MainActor
    @Test func anOfferIsNotRepeatedWithinTheHour() {
        let offer = StagedUpdateOffer()
        var offers = 0
        offer.isBusy = { false }
        offer.present = { _ in offers += 1 }
        offer.stage(version: "1.0.8.2", install: {}, pollEvery: .seconds(3600))
        let now = Date()
        offer.offerIfDue(now: now)
        offer.offerIfDue(now: now.addingTimeInterval(600))
        #expect(offers == 1)
        offer.offerIfDue(now: now.addingTimeInterval(StagedUpdateOffer.offerInterval + 1))
        #expect(offers == 2)
    }

    /// A meeting can start between the offer and the click. Then the
    /// answer is "not now", and the install block stays for later.
    @MainActor
    @Test func theButtonRefusesIfARecordingStartedMeanwhile() {
        let offer = StagedUpdateOffer()
        var busy = false
        var installs = 0
        offer.isBusy = { busy }
        offer.stage(version: "1.0.8.2", install: { installs += 1 }, pollEvery: .seconds(3600))
        busy = true
        #expect(!offer.installNow())
        #expect(installs == 0)
        #expect(offer.isStaged)
        busy = false
        #expect(offer.installNow())
        #expect(installs == 1)
    }

    @MainActor
    @Test func nothingStagedMeansNothingOffered() {
        let offer = StagedUpdateOffer()
        var offers = 0
        offer.isBusy = { false }
        offer.present = { _ in offers += 1 }
        offer.offerIfDue()
        #expect(offers == 0)
        #expect(!offer.installNow())
    }
}
