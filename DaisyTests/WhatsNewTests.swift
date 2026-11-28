// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  WhatsNewTests.swift
//  DaisyTests
//
//  «What's New in Daisy» (Egor 22.10): once per edition after an update,
//  never on a fresh install. The edition of 28.11 is a paywall for the
//  Daisy Subscription: it doesn't open by itself for a subscriber, its
//  figures come from the two prices, and its button never buys before the
//  person has signed in and said yes to sending text. A stubbed server,
//  defaults of the tests' own, no page opened.
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Daisy

/// Its own stub, answering by the session's token and the path: every test
/// signs its store in with a token of its own, so suites running side by
/// side never get each other's answers.
final class WhatsNewServerStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: (status: Int, body: String)] = [:]
    nonisolated(unsafe) private static var asked: [(token: String, path: String, body: String)] = []

    /// The answer for `path` (its last component) asked with `token`; any
    /// other request gets a 500.
    static func answer(_ token: String, _ path: String, _ status: Int, _ body: String) {
        lock.withLock { answers["\(token)/\(path)"] = (status, body) }
    }

    /// What was asked with `token`: the paths, and what was sent to them.
    static func requests(_ token: String) -> [(path: String, body: String)] {
        lock.withLock { asked.filter { $0.token == token }.map { ($0.path, $0.body) } }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WhatsNewServerStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var sent = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                sent.append(buffer, count: read)
            }
            stream.close()
        }
        let token = String((request.value(forHTTPHeaderField: "authorization") ?? "").dropFirst("Bearer ".count))
        let path = request.url?.lastPathComponent ?? ""
        let next = Self.lock.withLock {
            Self.asked.append((token, path, String(decoding: sent, as: UTF8.self)))
            return Self.answers["\(token)/\(path)"]
        } ?? (status: 500, body: "no stub")
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// An account for the window's tests: scratch defaults, the stubbed server,
/// a browser that opens nothing.
@MainActor
struct WhatsNewAccount {
    static let free = #"{"active":false,"sources":[],"trialRemaining":2}"#
    static let active = #"{"active":true,"sources":[{"source":"web","renewsAt":"2026-12-27T12:00:00.000Z","willRenew":true,"manageUrl":"https://whop.com/billing/manage/mber_x/"}],"trialRemaining":0}"#

    let token = "s1.\(UUID().uuidString).sig"
    let opened = OpenedPages()
    let store: DaisyAccountStore

    /// `status`: what GET /v1/subscription says, read once here; nil leaves
    /// the status unknown (and the server answering 500).
    init(defaults: UserDefaults, signedIn: Bool, consented: Bool, status: String? = nil) async {
        let opened = opened
        store = DaisyAccountStore(
            session: WhatsNewServerStub.session(),
            defaults: defaults,
            readStored: false,
            restoring: signedIn
                ? (token: token, account: DaisyAccountInfo(id: "acct", email: "anna@example.com", providers: ["email"]))
                : nil,
            openInBrowser: { opened.urls.append($0) },
            // Asked every ten minutes: the only reads are the tests' own.
            pollInterval: .seconds(600))
        if consented { store.acknowledgeCloudDisclosure() }
        if let status {
            WhatsNewServerStub.answer(token, "subscription", 200, status)
            if signedIn { await store.refreshSubscription() }
        }
    }

    var requests: [(path: String, body: String)] { WhatsNewServerStub.requests(token) }
}

@MainActor
struct WhatsNewTests {
    private let scratch = ScratchDefaults("WhatsNew")

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: When it opens

    @Test func opensOnceAfterAnUpdate() {
        let d = scratch.make()
        #expect(WhatsNew.shouldOpen(hasShownFirstRun: true, defaults: d))
        WhatsNew.markSeen(defaults: d)
        #expect(!WhatsNew.shouldOpen(hasShownFirstRun: true, defaults: d))
        // A later edition opens again.
        d.set("an-older-edition", forKey: WhatsNew.seenKey)
        #expect(WhatsNew.shouldOpen(hasShownFirstRun: true, defaults: d))
    }

    @Test func notDuringOnboarding() {
        let d = scratch.make()
        #expect(!WhatsNew.shouldOpen(hasShownFirstRun: false, defaults: d))
        // Finishing onboarding marks it seen (OnboardingTourController.finish).
        WhatsNew.markSeen(defaults: d)
        #expect(!WhatsNew.shouldOpen(hasShownFirstRun: true, defaults: d))
    }

    @Test("the subscription's edition opens for someone who saw the Daisy key's")
    func theEditionIsNew() {
        let d = scratch.make()
        #expect(WhatsNew.edition == "subscription-2026-11")
        d.set("daisy-key-2026-10-e", forKey: WhatsNew.seenKey)
        #expect(WhatsNew.shouldOpen(hasShownFirstRun: true, defaults: d))
    }

    @Test("a subscriber isn't sold the subscription: the edition counts as seen; an unknown status waits")
    func notByItselfForASubscriber() {
        // Signed out: this Mac has no subscription to use.
        #expect(WhatsNew.arrival(signedIn: false, subscriptionActive: nil) == .open)
        #expect(WhatsNew.arrival(signedIn: true, subscriptionActive: false) == .open)
        // Seen, not skipped for ever: it stays in Help, Settings and About.
        #expect(WhatsNew.arrival(signedIn: true, subscriptionActive: true) == .seen)
        // The server didn't answer: nothing is known, so nothing is decided.
        #expect(WhatsNew.arrival(signedIn: true, subscriptionActive: nil) == .later)
    }

    @Test("a fresh install has nothing to decide; signed out, the window opens and is marked only once shown")
    func theOpeningDecision() {
        let d = scratch.make()
        // A fresh install: the tour is on, and marks the edition when it ends.
        #expect(WhatsNew.arrive(hasShownFirstRun: false, signedIn: false, subscriptionActive: nil, defaults: d) == nil)
        #expect(WhatsNew.arrive(hasShownFirstRun: false, signedIn: true, subscriptionActive: true, defaults: d) == nil)
        #expect(d.string(forKey: WhatsNew.seenKey) == nil)
        // An update, signed out: opens. Deciding marks nothing; the window does, as it appears.
        #expect(WhatsNew.arrive(hasShownFirstRun: true, signedIn: false, subscriptionActive: nil, defaults: d) == .open)
        #expect(WhatsNew.shouldOpen(hasShownFirstRun: true, defaults: d))
        WhatsNew.markSeen(defaults: d)
        // Once per edition, whoever asks again.
        #expect(WhatsNew.arrive(hasShownFirstRun: true, signedIn: false, subscriptionActive: nil, defaults: d) == nil)
        #expect(WhatsNew.arrive(hasShownFirstRun: true, signedIn: true, subscriptionActive: false, defaults: d) == nil)
    }

    @Test("a status not known at launch is put off, and decided when it arrives")
    func anUnknownStatusIsDecidedWhenItArrives() {
        // No subscription after all: the window opens.
        let free = scratch.make()
        #expect(WhatsNew.arrive(hasShownFirstRun: true, signedIn: true, subscriptionActive: nil, defaults: free) == .later)
        #expect(WhatsNew.shouldOpen(hasShownFirstRun: true, defaults: free), "put off is not seen")
        #expect(WhatsNew.arrive(hasShownFirstRun: true, signedIn: true, subscriptionActive: false, defaults: free) == .open)
        // A subscriber after all: never opened, and marked seen, so the next launch doesn't ask.
        let paid = scratch.make()
        #expect(WhatsNew.arrive(hasShownFirstRun: true, signedIn: true, subscriptionActive: nil, defaults: paid) == .later)
        #expect(WhatsNew.arrive(hasShownFirstRun: true, signedIn: true, subscriptionActive: true, defaults: paid) == .seen)
        #expect(!WhatsNew.shouldOpen(hasShownFirstRun: true, defaults: paid))
        #expect(WhatsNew.arrive(hasShownFirstRun: true, signedIn: true, subscriptionActive: true, defaults: paid) == nil)
        // Signed out while it was put off: nothing to wait for.
        let out = scratch.make()
        #expect(WhatsNew.arrive(hasShownFirstRun: true, signedIn: true, subscriptionActive: nil, defaults: out) == .later)
        #expect(WhatsNew.arrive(hasShownFirstRun: true, signedIn: false, subscriptionActive: nil, defaults: out) == .open)
    }

    @Test("the Daisy key's bubble waits while the window is on its way or up, and no longer")
    func theBubbleWaitsForTheWindow() {
        // Due and not decided yet this launch: it is about to open.
        #expect(WhatsNew.isAhead(due: true, settled: false, showing: false))
        #expect(WhatsNew.isAhead(due: true, settled: true, showing: true))
        #expect(WhatsNew.isAhead(due: false, settled: true, showing: true), "opened by hand")
        // Closed (seen), marked seen for a subscriber, or put off: the bubble's turn.
        #expect(!WhatsNew.isAhead(due: false, settled: true, showing: false))
        #expect(!WhatsNew.isAhead(due: true, settled: true, showing: false))
        // Nothing due at all: never waited for.
        #expect(!WhatsNew.isAhead(due: false, settled: false, showing: false))
        let key = try? String(contentsOf: Self.repositoryRoot.appendingPathComponent("Daisy/DaisyKey.swift"), encoding: .utf8)
        #expect(key?.contains("WhatsNew.isAhead(hasShownFirstRun: settings.hasShownFirstRun)") == true)
    }

    @Test func keycapsShowThePersonsKey() {
        #expect(WhatsNewKeycaps.caps(for: .ctrlOpt).map(\.glyph) == ["⌃", "⌥"])
        #expect(WhatsNewKeycaps.caps(for: .rightCommand).map(\.glyph) == ["⌘"])
        #expect(WhatsNewKeycaps.caps(for: .ctrlOptD).map(\.glyph) == ["⌃", "⌥", "D"])
        #expect(WhatsNewKeycaps.caps(for: .ctrlShiftD).map(\.glyph) == ["⌃", "⇧", "D"])
        #expect(WhatsNewKeycaps.caps(for: .ctrlOptCmdD).map(\.glyph) == ["⌃", "⌥", "⌘", "D"])
        #expect(WhatsNewKeycaps.caps(for: .fn).map(\.glyph) == ["fn"])
    }

    // MARK: The prices and what is worked out from them

    @Test("the two amounts are written once, and Settings shows them as it did")
    func thePricesHaveOneSource() throws {
        #expect(DaisyAccountStore.Plan.month.price == Decimal(string: "7.99"))
        #expect(DaisyAccountStore.Plan.year.price == Decimal(string: "59.99"))
        // The decimal mark is the language's, not the region's.
        #expect(DaisyAccountStore.Plan.priceText(DaisyAccountStore.Plan.month.price, language: "en") == "$7.99")
        #expect(DaisyAccountStore.Plan.priceText(DaisyAccountStore.Plan.month.price, language: "ru") == "$7,99")
        #expect(DaisyAccountStore.Plan.priceText(DaisyAccountStore.Plan.year.price, language: "ru") == "$59,99")
        #expect(DaisyAccountStore.Plan.priceText(5, language: "en") == "$5.00")
        // No screen writes an amount out: the row of Settings and the window read the plan's.
        for file in ["Daisy/DaisySubscriptionSettings.swift", "Daisy/WhatsNew.swift"] {
            let source = try String(contentsOf: Self.repositoryRoot.appendingPathComponent(file), encoding: .utf8)
            #expect(!source.contains("7.99") && !source.contains("59.99"), "\(file) writes a price out")
        }
        let catalog = try Self.catalog()
        #expect(catalog["$7.99 a month"] == nil && catalog["$59.99 a year"] == nil)
        #expect(catalog["%@ a month"] == "%@ в месяц")
        #expect(catalog["%@ a year"] == "%@ в год")
    }

    /// With `-testLanguage en`, as the suites run.
    @Test func thePlanRowReadsAsBefore() throws {
        try #require(Bundle.main.preferredLocalizations.first == "en")
        #expect(DaisyAccountStore.Plan.month.priceLine == "$7.99 a month")
        #expect(DaisyAccountStore.Plan.year.priceLine == "$59.99 a year")
    }

    /// Whatever language the suites run in: the Russian catalog's own
    /// lines, with the amounts as Russian writes them.
    @Test func thePriceLinesInRussian() throws {
        let ru = try #require(Bundle.main.path(forResource: "ru", ofType: "lproj").flatMap(Bundle.init(path:)))
        func line(_ key: String, _ amount: Decimal) -> String {
            String(format: ru.localizedString(forKey: key, value: nil, table: nil),
                   DaisyAccountStore.Plan.priceText(amount, language: "ru"))
        }
        #expect(line("%@ a month", DaisyAccountStore.Plan.month.price) == "$7,99 в месяц")
        #expect(line("%@ a year", DaisyAccountStore.Plan.year.price) == "$59,99 в год")
        #expect(line("%@ a month", DaisyPlanMath.perMonth(yearly: DaisyAccountStore.Plan.year.price)) == "$5,00 в месяц")
    }

    @Test("the saving is rounded down and the month's share is to the cent, as on the iPhone")
    func thePlanFigures() {
        let month = DaisyAccountStore.Plan.month.price, year = DaisyAccountStore.Plan.year.price
        // 12 × 7.99 = 95.88; 35.89 less is 37.43 %.
        #expect(DaisyPlanMath.savingsPercent(monthly: month, yearly: year) == 37)
        // 59.99 / 12 = 4.999…
        #expect(DaisyPlanMath.perMonth(yearly: year) == Decimal(string: "5.00"))
        // Down, never up: 16.67 % is 16, 49.99 % is 49.
        #expect(DaisyPlanMath.savingsPercent(monthly: 10, yearly: 100) == 16)
        #expect(DaisyPlanMath.savingsPercent(monthly: 10, yearly: Decimal(string: "60.01")!) == 49)
        // Nothing saved: no badge. Neither for under one percent, nor without a monthly price.
        #expect(DaisyPlanMath.savingsPercent(monthly: 10, yearly: 120) == nil)
        #expect(DaisyPlanMath.savingsPercent(monthly: 10, yearly: 130) == nil)
        #expect(DaisyPlanMath.savingsPercent(monthly: 10, yearly: Decimal(string: "119.50")!) == nil)
        #expect(DaisyPlanMath.savingsPercent(monthly: 0, yearly: 0) == nil)
        #expect(DaisyPlanMath.perMonth(yearly: 100) == Decimal(string: "8.33"))
        #expect(DaisyPlanMath.perMonth(yearly: 119) == Decimal(string: "9.92"))
    }

    // MARK: What «Subscribe» does

    @Test("the button buys only for someone signed in who said yes to sending text")
    func theButtonsDecision() {
        typealias S = WhatsNewSubscribe
        #expect(S.action(signedIn: true, consented: true, active: false, awaitingPayment: false) == .checkout)
        // Buying is never the yes: each of these goes to Settings first.
        #expect(S.action(signedIn: false, consented: false, active: nil, awaitingPayment: false) == .settings)
        #expect(S.action(signedIn: false, consented: true, active: nil, awaitingPayment: false) == .settings)
        #expect(S.action(signedIn: true, consented: false, active: false, awaitingPayment: false) == .settings)
        // A status not known buys nothing: Settings show no plan row then either.
        #expect(S.action(signedIn: true, consented: true, active: nil, awaitingPayment: false) == .settings)
        #expect(S.action(signedIn: true, consented: false, active: nil, awaitingPayment: false) == .settings)
        // Never a second purchase, never a second page.
        for signedIn in [true, false] {
            for consented in [true, false] {
                #expect(S.action(signedIn: signedIn, consented: consented, active: true, awaitingPayment: false) == .status)
                #expect(S.action(signedIn: signedIn, consented: consented, active: false, awaitingPayment: true) == .status)
                #expect(S.action(signedIn: signedIn, consented: consented, active: true, awaitingPayment: true) == .status)
            }
        }
    }

    @Test("signed out: nothing is bought, and the plan chosen is the one picked in Settings")
    func signedOutGoesToSettingsWithThePlan() async {
        let account = await WhatsNewAccount(defaults: scratch.make(), signedIn: false, consented: false)
        #expect(account.store.chosenPlan == .month)
        var settingsOpened = 0
        let failure = await WhatsNewSubscribe.run(plan: .year, store: account.store) { settingsOpened += 1 }
        #expect(failure == nil)
        #expect(settingsOpened == 1)
        #expect(account.store.chosenPlan == .year)
        #expect(account.opened.urls.isEmpty && !account.store.awaitingPayment)
    }

    @Test("signed in without the yes to sending text: Settings first, no page, nothing asked of the server")
    func withoutConsentGoesToSettings() async {
        let account = await WhatsNewAccount(defaults: scratch.make(), signedIn: true, consented: false, status: WhatsNewAccount.free)
        WhatsNewServerStub.answer(account.token, "checkout", 200, #"{"url":"https://whop.com/checkout/plan_x"}"#)
        var settingsOpened = 0
        let failure = await WhatsNewSubscribe.run(plan: .month, store: account.store) { settingsOpened += 1 }
        #expect(failure == nil && settingsOpened == 1)
        #expect(account.store.chosenPlan == .month)
        #expect(account.opened.urls.isEmpty && !account.store.awaitingPayment)
        #expect(!account.requests.contains { $0.path == "checkout" })
    }

    @Test("the plan chosen in the window is the plan the checkout is asked for", arguments: [DaisyAccountStore.Plan.year, .month])
    func buysTheChosenPlan(plan: DaisyAccountStore.Plan) async throws {
        let account = await WhatsNewAccount(defaults: scratch.make(), signedIn: true, consented: true, status: WhatsNewAccount.free)
        WhatsNewServerStub.answer(account.token, "checkout", 200, #"{"url":"https://whop.com/checkout/plan_x"}"#)
        let failure = await WhatsNewSubscribe.run(plan: plan, store: account.store) {}
        #expect(failure == nil)
        let asked = account.requests.filter { $0.path == "checkout" }
        #expect(asked.count == 1)
        let sent = try #require(asked.first).body
        let body = try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: String]
        #expect(body == ["plan": plan.rawValue], "\(sent)")
        #expect(account.store.chosenPlan == plan)
        #expect(account.opened.urls == [URL(string: "https://whop.com/checkout/plan_x")!])
        account.store.stopWaitingForPayment()
    }

    @Test("a status not read yet buys nothing: Settings, with the plan, and no checkout")
    func anUnknownStatusGoesToSettings() async {
        // Signed in with the yes, and the server not answering.
        let account = await WhatsNewAccount(defaults: scratch.make(), signedIn: true, consented: true)
        WhatsNewServerStub.answer(account.token, "checkout", 200, #"{"url":"https://whop.com/checkout/plan_x"}"#)
        #expect(account.store.subscription == nil)
        var settingsOpened = 0
        let failure = await WhatsNewSubscribe.run(plan: .year, store: account.store) { settingsOpened += 1 }
        #expect(failure == nil && settingsOpened == 1)
        #expect(account.store.chosenPlan == .year)
        #expect(account.opened.urls.isEmpty && !account.store.awaitingPayment)
        #expect(!account.requests.contains { $0.path == "checkout" })
    }

    @Test("a double click, or Return held down, opens one payment page")
    func oneClickAtATime() async throws {
        let account = await WhatsNewAccount(defaults: scratch.make(), signedIn: true, consented: true, status: WhatsNewAccount.free)
        WhatsNewServerStub.answer(account.token, "checkout", 200, #"{"url":"https://whop.com/checkout/plan_x"}"#)
        let purchase = WhatsNewPurchase()
        var settingsOpened = 0
        let first = try #require(purchase.subscribe(plan: .year, store: account.store, openSettings: { settingsOpened += 1 }))
        #expect(purchase.isWorking)
        // While the first is on its way, nothing more is started.
        #expect(purchase.subscribe(plan: .year, store: account.store, openSettings: { settingsOpened += 1 }) == nil)
        #expect(purchase.subscribe(plan: .month, store: account.store, openSettings: { settingsOpened += 1 }) == nil)
        await first.value
        #expect(!purchase.isWorking && purchase.error == nil)
        #expect(account.requests.filter { $0.path == "checkout" }.count == 1)
        #expect(account.opened.urls.count == 1 && settingsOpened == 1)
        #expect(account.store.chosenPlan == .year)
        account.store.stopWaitingForPayment()
    }

    @Test("a failed checkout shows its words on the button's own state, and the next click is taken")
    func aFailedClickCanBeRepeated() async throws {
        let account = await WhatsNewAccount(defaults: scratch.make(), signedIn: true, consented: true, status: WhatsNewAccount.free)
        WhatsNewServerStub.answer(account.token, "checkout", 503, #"{"error":"unavailable"}"#)
        let purchase = WhatsNewPurchase()
        let failed = try #require(purchase.subscribe(plan: .year, store: account.store, openSettings: {}))
        await failed.value
        #expect(purchase.error == DaisyAccountFailure.checkoutUnavailable.localizedDescription)
        #expect(!purchase.isWorking)
        WhatsNewServerStub.answer(account.token, "checkout", 200, #"{"url":"https://whop.com/checkout/plan_x"}"#)
        let again = try #require(purchase.subscribe(plan: .year, store: account.store, openSettings: {}))
        await again.value
        #expect(purchase.error == nil && account.opened.urls.count == 1)
        account.store.stopWaitingForPayment()
    }

    @Test("signed in with the yes: the page opens, then Settings with the wait showing, and the payment turns the switch")
    func aPaymentSeenWhileTheWaitShowsTurnsTheSwitch() async throws {
        let account = await WhatsNewAccount(defaults: scratch.make(), signedIn: true, consented: true, status: WhatsNewAccount.free)
        WhatsNewServerStub.answer(account.token, "checkout", 200, #"{"url":"https://whop.com/checkout/plan_x"}"#)
        var paid = 0
        account.store.onPaid = { paid += 1 }
        var settingsOpened = 0
        var pageWasOpenBySettings = false
        let failure = await WhatsNewSubscribe.run(plan: .year, store: account.store) {
            settingsOpened += 1
            // Settings come up with the wait already showing.
            pageWasOpenBySettings = account.store.awaitingPayment && !account.opened.urls.isEmpty
        }
        #expect(failure == nil && settingsOpened == 1 && pageWasOpenBySettings)
        #expect(account.opened.urls == [URL(string: "https://whop.com/checkout/plan_x")!])
        // A click while that page is waited for opens no second one.
        #expect(await WhatsNewSubscribe.run(plan: .month, store: account.store) { settingsOpened += 1 } == nil)
        #expect(settingsOpened == 2 && account.opened.urls.count == 1)
        #expect(account.requests.filter { $0.path == "checkout" }.count == 1)
        // Paid while the wait shows: `onPaid`, which turns the subscription's switch on.
        WhatsNewServerStub.answer(account.token, "subscription", 200, WhatsNewAccount.active)
        await account.store.refreshSubscription()
        #expect(paid == 1 && !account.store.awaitingPayment)
    }

    @Test("a checkout that fails says so in the window: Settings don't open, nothing is waited for")
    func aFailedCheckoutIsSaid() async {
        let account = await WhatsNewAccount(defaults: scratch.make(), signedIn: true, consented: true, status: WhatsNewAccount.free)
        WhatsNewServerStub.answer(account.token, "checkout", 503, #"{"error":"unavailable"}"#)
        var settingsOpened = 0
        let failure = await WhatsNewSubscribe.run(plan: .year, store: account.store) { settingsOpened += 1 }
        #expect(failure == DaisyAccountFailure.checkoutUnavailable.localizedDescription)
        #expect(settingsOpened == 0)
        #expect(account.opened.urls.isEmpty && !account.store.awaitingPayment)
    }

    @Test("a subscriber's click buys nothing")
    func aSubscriberBuysNothing() async {
        let account = await WhatsNewAccount(defaults: scratch.make(), signedIn: true, consented: true, status: WhatsNewAccount.active)
        var settingsOpened = 0
        let failure = await WhatsNewSubscribe.run(plan: .year, store: account.store) { settingsOpened += 1 }
        #expect(failure == nil && settingsOpened == 1)
        #expect(account.opened.urls.isEmpty)
        #expect(!account.requests.contains { $0.path == "checkout" })
        // Not the window's to change: the row keeps its own choice.
        #expect(account.store.chosenPlan == .month)
    }

    @Test("the «Plan» row of Settings picks the store's plan, so the window's choice is the one shown there")
    func theRowReadsTheStoresPlan() throws {
        let rows = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("Daisy/DaisySubscriptionSettings.swift"),
                              encoding: .utf8)
        #expect(rows.contains("selection: $store.chosenPlan"))
        #expect(rows.contains("let picked = store.chosenPlan"))
        #expect(!rows.contains("@State private var plan"))
    }

    // MARK: What it shows

    @Test("the field photograph ships in the app, and the notices name it as not under the license")
    func thePhotographIsInTheApp() throws {
        // The app itself, not the test bundle.
        let app = Bundle(for: SparkleProgress.self)
        let photo = try #require(app.image(forResource: "WhatsNewField"), "WhatsNewField is not in Daisy.app")
        #expect(photo.size.width > photo.size.height * 2)
        for file in ["NOTICE.md", "TRADEMARKS.md"] {
            let text = try String(contentsOf: Self.repositoryRoot.appendingPathComponent(file), encoding: .utf8)
            #expect(text.contains("`Daisy/Assets.xcassets/WhatsNewField.imageset/`"), "\(file)")
        }
    }

    @Test("every line of the window is in Russian too, without a full stop at the end")
    func theWindowsStringsAreInTheCatalog() throws {
        let catalog = try Self.catalog()
        let source = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("Daisy/WhatsNew.swift"), encoding: .utf8)
        let plain = [
            "Daisy Subscription",
            "Summaries without an API key",
            "Daisy writes them for you, with no key of your own",
            "Not only summaries",
            "Follow-ups, briefs, Daisy key commands, rewrites of the selection and the transcript's second pass run on it too",
            "Three summaries are free",
            "Everything else needs the subscription",
            "The free summaries are used",
            "Summaries and everything else now need the subscription",
            "Write summaries on the Daisy Subscription",
            "Only text is sent, never audio",
            "It goes through Daisy's server to Anthropic, and only while the subscription's switch is on. Your own provider and its key stay in Settings; you can switch back any time",
            "The payment page opens in your browser",
            "Manage subscription",
            "Not now",
            "Your subscription is active",
            "Open Settings",
            "Done",
            "Privacy",
        ]
        let keyed = ["daisySubscription.subscribe", "whatsNew.plan.year", "whatsNew.plan.month",
                     "whatsNew.plan.perYear", "whatsNew.plan.perMonth", "whatsNew.link.terms", "whatsNew.link.refunds"]
        for key in plain + keyed {
            #expect(source.contains("\"\(key)\""), "the window no longer shows «\(key)»")
        }
        let formats = ["The subscription renews until you cancel it in %@, “%@”", "Save %lld%%", "%@ a month",
                       "Free summaries left: %lld of 3", "For a meeting or a voice note: sign in and turn on “%@”",
                       "Renews %@", "Until %@, won't renew", "Bought on iPhone, managed in the App Store"]
        for key in plain + keyed + formats {
            let russian = try #require(catalog[key], "no Russian for «\(key)»")
            #expect(!russian.hasSuffix("."), "\(russian)")
            #expect(!key.hasSuffix("."), "\(key)")
        }
        // The words the app already uses, not a second spelling of them.
        let followUps = try #require(catalog["Follow-ups"]).lowercased()
        let covered = try #require(catalog["Follow-ups, briefs, Daisy key commands, rewrites of the selection and the transcript's second pass run on it too"])
        #expect(covered.contains(followUps), "\(covered)")
        // Lines other screens still say stay: the tour's counter, a quote.
        #expect(catalog["%lld of %lld"] == "%1$lld из %2$lld")
        #expect(catalog["“%@”"] == "«%@»")
        // The Daisy key's scenes went with their edition, and their lines with them.
        for gone in ["Hold and say what to do", "whatsNew.settings", "tip.whatsNew.tour", "Week in review"] {
            #expect(catalog[gone] == nil, "\(gone)")
        }
        #expect(!source.contains("WhatsNewStage") && !source.contains("WhatsNewScript") && !source.contains("WhatsNewFlower"))
    }

    @Test("the title never says three are free over a line saying they are used")
    func theFreeSummariesLineFollowsTheAccount() {
        typealias F = WhatsNewSheet.FreeSummaries
        #expect(F.state(signedIn: false, remaining: nil) == .offered)
        #expect(F.state(signedIn: false, remaining: 0) == .offered, "a status left from an account signed out")
        #expect(F.state(signedIn: true, remaining: nil) == .offered)
        #expect(F.state(signedIn: true, remaining: 3) == .left(3))
        #expect(F.state(signedIn: true, remaining: 1) == .left(1))
        #expect(F.state(signedIn: true, remaining: 0) == .used)
    }

    // MARK: How tall it is

    @Test("the window is never taller than the display leaves under the title bar")
    func theHeightLimit() {
        // A 13-inch display at its default scaling, Dock hidden: the whole window fits.
        #expect(WhatsNewSheet.heightLimit(displayHeight: 919, titleBar: 52) == 919 - 52 - PanelSize.margin)
        // «Larger Text» with the Dock: 800 − 25 − 70.
        #expect(WhatsNewSheet.heightLimit(displayHeight: 705, titleBar: 52) == 629)
        // Never less than the photograph, the button and a strip to scroll.
        #expect(WhatsNewSheet.heightLimit(displayHeight: 300, titleBar: 52) == WhatsNewSheet.minimumHeight)
        #expect(WhatsNewSheet.heightLimit(under: nil) == .infinity)
    }

    @Test("on a short display only the feature rows scroll: the plans and the button stay whole, down to the shortest limit")
    func theSheetFitsTheLimit() async throws {
        let account = await WhatsNewAccount(defaults: scratch.make(), signedIn: false, consented: false)
        let subscriber = await WhatsNewAccount(defaults: scratch.make(), signedIn: true, consented: true, status: WhatsNewAccount.active)
        func height(_ limit: CGFloat) -> CGFloat {
            NSHostingView(rootView: WhatsNewSheet(store: account.store, maxHeight: limit, openSettings: {})).fittingSize.height
        }
        let whole = height(.infinity)
        #expect(whole > 600 && whole < 800, "\(whole)")
        // Room to spare changes nothing.
        #expect(height(whole + 200) == whole)
        #expect(height(whole) == whole)
        // Short of it, the limit is the height.
        #expect(height(620) == 620)
        #expect(height(WhatsNewSheet.minimumHeight) == WhatsNewSheet.minimumHeight)
        // What never scrolls — the plans (or the subscription's state), the
        // button, its small print, the links — fits whole under the
        // photograph at its shortest and a strip of feature rows, at the
        // shortest limit there is.
        for store in [account.store, subscriber.store] {
            let fixed = NSHostingView(rootView: WhatsNewSheet(store: store, openSettings: {}).fixedPartForInspection)
                .fittingSize.height
            #expect(fixed > 100, "\(fixed)")
            #expect(WhatsNewSheet.heroMinimum + WhatsNewSheet.featuresMinimum + fixed <= WhatsNewSheet.minimumHeight, "\(fixed)")
        }
        // The photograph gives way only after the feature rows are down to
        // their strip, and keeps its words: at its own height wherever the
        // limit leaves room for the strip.
        #expect(WhatsNewSheet.heroMinimum < WhatsNewSheet.heroHeight)
        #expect(WhatsNewSheet.heightLimit(displayHeight: 0, titleBar: 0) == WhatsNewSheet.minimumHeight)
        // Only the feature rows are inside the scroll view.
        let source = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("Daisy/WhatsNew.swift"), encoding: .utf8)
        let scrolls = source.components(separatedBy: "ScrollView {")
        #expect(scrolls.count == 2)
        let scrolled = try #require(scrolls.last?.components(separatedBy: ".scrollIndicators").first)
        #expect(scrolled.contains("features") && !scrolled.contains("plan") && !scrolled.contains("offer")
            && !scrolled.contains("activeCard"), "\(scrolled)")
    }

    @Test func theLinksAreTheSitesOwn() {
        #expect(WhatsNewSheet.terms.absoluteString == "https://mydaisy.io/terms")
        #expect(WhatsNewSheet.privacy.absoluteString == "https://mydaisy.io/privacy")
        #expect(WhatsNewSheet.refunds.absoluteString == "https://mydaisy.io/refunds")
    }

    /// key → the Russian value.
    private static func catalog() throws -> [String: String] {
        let url = repositoryRoot.appendingPathComponent("Daisy/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try #require(json?["strings"] as? [String: [String: Any]])
        return strings.compactMapValues { entry in
            let localizations = entry["localizations"] as? [String: Any]
            return ((localizations?["ru"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
    }
}
