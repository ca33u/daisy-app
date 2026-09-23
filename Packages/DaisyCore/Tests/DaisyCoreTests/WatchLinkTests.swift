//
//  WatchLinkTests.swift
//  DaisyCoreTests
//
//  Бэклог 14 Н-2. Two rules decide whether the watch is a remote or a
//  recorder, and whether audio on it can be deleted. Both are tested
//  here, without a watch.
//

import Foundation
import Testing
@testable import DaisyLink

@Suite("The watch picks its role")
struct WatchRoleTests {
    let asked = Date(timeIntervalSince1970: 1_000_000)

    @Test func anAnsweringPhoneIsTheOnlyTruth() {
        let phone = PhoneState(isRecording: true, startedAt: asked, title: "Stand")
        let role = WatchLink.role(reachable: true, phone: phone, answeredAt: asked,
                                  askedAt: asked, now: asked.addingTimeInterval(1))
        #expect(role == .remoteControl(phone))
    }

    /// Found on paired simulators, 2026-09-23: the phone app was killed
    /// and the wrist kept saying "Ready — your phone records" off an
    /// answer from two minutes before. An answer describes a moment.
    @Test func anOldAnswerIsNotAnAnswer() {
        let phone = PhoneState(isRecording: true, startedAt: asked)
        let stale = WatchLink.role(reachable: true, phone: phone, answeredAt: asked,
                                   askedAt: asked, now: asked.addingTimeInterval(11))
        #expect(stale == .standalone(reason: .phoneDidNotAnswer))
    }

    /// And an answer with no timestamp is not one either — that is a
    /// caller bug, and the safe reading of a caller bug is silence.
    @Test func anAnswerWithoutAMomentIsTreatedAsSilence() {
        let phone = PhoneState(isRecording: true, startedAt: asked)
        let role = WatchLink.role(reachable: false, phone: phone, answeredAt: nil,
                                  askedAt: asked, now: asked.addingTimeInterval(WatchLink.reachabilityGrace))
        #expect(role == .standalone(reason: .phoneNotReachable))
    }

    /// `isReachable` describes the radio; an answer describes the app.
    /// When they disagree, the answer wins — otherwise a stale flag
    /// would push the watch into recording while the phone is already
    /// doing it, and the meeting would land in two halves.
    @Test func anAnswerBeatsAnUnreachableFlag() {
        let phone = PhoneState(isRecording: true, startedAt: asked)
        let role = WatchLink.role(reachable: false, phone: phone, answeredAt: asked.addingTimeInterval(29),
                                  askedAt: asked, now: asked.addingTimeInterval(30))
        #expect(role == .remoteControl(phone))
    }

    @Test func noPhoneInReachMeansRecordHereAndSayWhy() {
        let role = WatchLink.role(reachable: false, phone: nil, askedAt: asked, now: asked.addingTimeInterval(5))
        #expect(role == .standalone(reason: .phoneNotReachable))
        guard case .standalone(let reason) = role else { return }
        #expect(reason.explanation.contains("worse"))
    }

    @Test func silenceInsideTheGraceIsNotYetAnAnswerEitherWay() {
        let role = WatchLink.role(reachable: true, phone: nil, askedAt: asked, now: asked.addingTimeInterval(1))
        #expect(role == .reaching)
    }

    /// Egor's watch, 23.09: the tap sent Record to the phone AND, on a
    /// silence that had started while the app slept, recorded here too.
    /// A command in flight is not silence, however long ago the last
    /// answer was.
    @Test func aCommandOnItsWayIsNotSilence() {
        let role = WatchLink.role(reachable: true, phone: nil, askedAt: asked,
                                  now: asked.addingTimeInterval(60), commandInFlight: true)
        #expect(role == .reaching)
    }

    /// Once the phone answers, the answer wins over the flag.
    @Test func anAnswerEndsTheWait() {
        let phone = PhoneState(isRecording: true, startedAt: asked)
        let role = WatchLink.role(reachable: true, phone: phone, answeredAt: asked.addingTimeInterval(1),
                                  askedAt: asked, now: asked.addingTimeInterval(1), commandInFlight: true)
        #expect(role == .remoteControl(phone))
    }

    /// Egor's watch, 23.09: a tap on the complication woke the app, the
    /// radio had not found the phone yet, and the watch recorded on the
    /// wrist with the phone on the table. A fresh "unreachable" waits.
    @Test func aJustWokenWatchWaitsForTheRadio() {
        let role = WatchLink.role(reachable: false, phone: nil, askedAt: asked, now: asked.addingTimeInterval(3))
        #expect(role == .reaching)
    }

    /// A locked phone answers the Record command with "couldn't start":
    /// that is an answer, and it means the watch records.
    @Test func aPhoneThatCannotStartHandsTheRecordingToTheWatch() {
        let refused = PhoneState(isRecording: false, startFailure: "locked")
        let role = WatchLink.role(reachable: true, phone: refused, answeredAt: asked,
                                  askedAt: asked, now: asked.addingTimeInterval(1))
        #expect(role == .standalone(reason: .phoneCouldNotStart))
    }

    /// The failure travels only in the reply to the command; a plain
    /// answer later on is remote control again.
    @Test func aLaterPlainAnswerIsRemoteControlAgain() {
        let role = WatchLink.role(reachable: true, phone: .idle, answeredAt: asked,
                                  askedAt: asked, now: asked.addingTimeInterval(1))
        #expect(role == .remoteControl(.idle))
    }

    @Test func silencePastTheGraceStartsRecordingHere() {
        let role = WatchLink.role(reachable: true, phone: nil, askedAt: asked, now: asked.addingTimeInterval(2))
        #expect(role == .standalone(reason: .phoneDidNotAnswer))
    }
}

@Suite("Audio on the watch is the only copy until the phone says otherwise")
struct WatchRecordingStoreTests {
    let now = Date(timeIntervalSince1970: 2_000_000)

    private func made(daysAgo: Double, confirmed: Bool, handed: Bool = false) -> PendingRecording {
        PendingRecording(
            startedAt: now.addingTimeInterval(-daysAgo * 86_400), seconds: 600,
            bytes: WatchRecordingStore.expectedBytes(seconds: 600),
            handedToSystemAt: handed ? now : nil,
            confirmedByPhoneAt: confirmed ? now : nil)
    }

    /// The whole point of the rule: handing a file to the system is
    /// not delivery. A queued transfer can sit for hours, and the file
    /// is still the only copy while it does.
    @Test func handingItToTheSystemDoesNotMakeItSafe() {
        let sweep = WatchRecordingStore.sweep([made(daysAgo: 0, confirmed: false, handed: true)], now: now)
        #expect(sweep.confirmed.isEmpty)
        #expect(sweep.waiting.count == 1)
    }

    @Test func onlyThePhonesConfirmationFrees() {
        let sweep = WatchRecordingStore.sweep([made(daysAgo: 0, confirmed: true)], now: now)
        #expect(sweep.confirmed.count == 1)
        #expect(sweep.waiting.isEmpty)
    }

    /// Past the ceiling storage wins — but the expired ones come back
    /// in their own list, never folded in with the safe ones, because
    /// deleting them loses audio that exists nowhere else.
    @Test func pastTheCeilingIsItsOwnAnswerNotASafeOne() {
        let sweep = WatchRecordingStore.sweep([made(daysAgo: 8, confirmed: false)], now: now)
        #expect(sweep.expired.count == 1)
        #expect(sweep.confirmed.isEmpty)
        #expect(sweep.waiting.isEmpty)
    }

    @Test func theWaitingLineCountsEverythingStillOnTheWatch() {
        let line = WatchRecordingStore.waitingLine(
            [made(daysAgo: 0, confirmed: false), made(daysAgo: 8, confirmed: false), made(daysAgo: 0, confirmed: true)],
            now: now)
        #expect(line?.hasPrefix("2 recordings waiting") == true)
        #expect(WatchRecordingStore.waitingLine([made(daysAgo: 0, confirmed: true)], now: now) == nil)
    }

    /// 16 kHz mono int16 — the phone's format, so nothing is converted
    /// on the way over. One hour is about 115 MB.
    @Test func anHourIsAboutAHundredAndFifteenMegabytes() {
        let hour = WatchRecordingStore.expectedBytes(seconds: 3600)
        #expect(hour == 115_200_000)
    }
}
