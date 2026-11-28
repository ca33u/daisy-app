// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  DayLedeTests.swift
//  DaisyTests
//
//  When the day card has an intro written by a model (daisy-app#12: it
//  named people and reports that don't exist), and whose answer reaches it.
//

import Foundation
import Testing
@testable import Daisy

@MainActor
@Suite(.timeLimit(.minutes(5)))
struct DayLedeTests {
    private let scratch = ScratchDefaults("day-lede")
    private let item = TrackedActionItem(
        id: "m#0", text: "Send the contract", sessionID: "m", sessionTitle: "Sync",
        sessionDate: Date(timeIntervalSince1970: 1_795_000_000), doneAt: nil, kindKnown: true
    )

    private func key(
        _ day: String, destination: String = "anthropic", dossier: String = "- 12:00 Lunch"
    ) -> DayLedeRequests.Key {
        .init(day: day, destination: destination, dossier: dossier)
    }

    private func summary(_ text: String) -> MeetingSummary {
        MeetingSummary(summary: text, sections: [], actionItems: [], clientFollowUp: "")
    }

    @Test(arguments: SummaryProviderKind.allCases)
    func withNothingOpenNoProviderIsAsked(provider: SummaryProviderKind) {
        #expect(!MorningBriefStore.hasLede(openItems: [], provider: provider))
    }

    @Test(arguments: SummaryProviderKind.allCases)
    func withSomethingOpenEveryProviderButAppleIsAsked(provider: SummaryProviderKind) {
        #expect(MorningBriefStore.hasLede(openItems: [item], provider: provider) == (provider != .appleIntelligence))
    }

    /// The words the models filled in when nothing in the data matched.
    @Test func thePromptOffersNothingToFillIn() {
        let prompt = SummaryPrompt.morningBriefSystemInstructions()
        for bait in ["promised", "overdue", "name people", "deliverables", "urgent", "late"] {
            #expect(!prompt.localizedCaseInsensitiveContains(bait), "\(bait)")
        }
    }

    @Test func anotherCalendarOrProviderIsAnotherRequest() {
        #expect(key("today") == key("today"))
        #expect(key("today") != key("tomorrow"))
        #expect(key("today") != key("today", destination: "openai"))
        #expect(key("today") != key("today", dossier: "- 12:00 Lunch\n- 18:30 QBR"))
    }

    @Test func aYesIsToOneProvider() {
        let defaults = scratch.make()
        #expect(!DayLedeConsent(currentDestination: "anthropic", defaults: defaults).allows("anthropic"))
        DayLedeConsent(currentDestination: "anthropic", defaults: defaults).allow("anthropic")
        let later = DayLedeConsent(currentDestination: "openai", defaults: defaults)
        #expect(later.allows("anthropic"))
        #expect(!later.allows("openai"))
        #expect(!later.allows("ollama|http://192.168.0.7:11434"))
    }

    /// Up to 1.0.8.55 the yes named nobody.
    @Test func theOldYesGoesToTheProviderInUseAndNoFurther() {
        let defaults = scratch.make()
        defaults.set(true, forKey: "daisy.morningBrief.cloudConsented")
        #expect(DayLedeConsent(currentDestination: "anthropic", defaults: defaults).allows("anthropic"))
        #expect(!DayLedeConsent(currentDestination: "openai", defaults: defaults).allows("openai"))
    }

    @Test func theOldYesIsForgottenOnALocalProvider() {
        let defaults = scratch.make()
        defaults.set(true, forKey: "daisy.morningBrief.cloudConsented")
        _ = DayLedeConsent(currentDestination: nil, defaults: defaults)
        #expect(!DayLedeConsent(currentDestination: "openai", defaults: defaults).allows("openai"))
    }

    @Test func anAnswerComesBack() async throws {
        let requests = DayLedeRequests()
        let result = await requests.run(key: key("today")) { self.summary("intro") }
        #expect(try result?.get().summary == "intro")
        #expect(requests.key == nil)
    }

    @Test func aFailureComesBackAsOne() async {
        let requests = DayLedeRequests()
        let result = await requests.run(key: key("today")) { throw CocoaError(.fileNoSuchFile) }
        #expect(throws: CocoaError.self) { try result?.get() }
        #expect(result != nil)
        #expect(requests.key == nil)
    }

    /// Tomorrow's request replaces today's; today's answer, coming late,
    /// must not land over tomorrow's agenda.
    @Test func aNewerRequestDropsTheOneInFlight() async throws {
        let requests = DayLedeRequests()
        let gate = Gate()
        let first = Task { await requests.run(key: key("today")) { await gate.wait(); return self.summary("today") } }
        await gate.reached()
        #expect(requests.key == key("today"))
        let second = await requests.run(key: key("tomorrow")) { self.summary("tomorrow") }
        gate.open()
        #expect(await first.value == nil)
        #expect(try second?.get().summary == "tomorrow")
    }

    /// The last open item closed while its lede was being written.
    @Test func aCancelledRequestAnswersNothing() async {
        let requests = DayLedeRequests()
        let gate = Gate()
        let first = Task { await requests.run(key: key("today")) { await gate.wait(); return self.summary("today") } }
        await gate.reached()
        requests.cancel()
        #expect(requests.key == nil)
        gate.open()
        #expect(await first.value == nil)
    }

    @Test func aDroppedRequestIsCancelledToo() async {
        let requests = DayLedeRequests()
        let gate = Gate()
        let first = Task {
            await requests.run(key: key("today")) {
                await gate.wait()
                gate.sawCancellation = Task.isCancelled
                return self.summary("today")
            }
        }
        await gate.reached()
        requests.cancel()
        gate.open()
        _ = await first.value
        #expect(gate.sawCancellation)
    }

    /// The card's task is cancelled when the agenda changes; the request
    /// isn't, and its answer is still the day's.
    @Test func theCallersCancellationLeavesTheRequestAlone() async throws {
        let requests = DayLedeRequests()
        let gate = Gate()
        let caller = Task {
            await requests.run(key: key("today")) {
                await gate.wait()
                try Task.checkCancellation()
                return self.summary("today")
            }
        }
        await gate.reached()
        caller.cancel()
        gate.open()
        #expect(try await caller.value?.get().summary == "today")
    }

    /// Holds a request open until the test lets it go.
    @MainActor
    private final class Gate {
        var sawCancellation = false
        private var isOpen = false
        private var isReached = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var watching: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            isReached = true
            watching.forEach { $0.resume() }
            watching = []
            if isOpen { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func reached() async {
            if isReached { return }
            await withCheckedContinuation { watching.append($0) }
        }

        func open() {
            isOpen = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }
}
