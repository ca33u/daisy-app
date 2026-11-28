// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  DaisySubscriptionTests.swift
//  DaisyTests
//
//  «Подписка Daisy» on the Mac (27.11): the provider sends the Mac's own
//  prompt and schema for a subscriber to daisy-api's /v1/complete and reads
//  Anthropic's stream back; without a subscription a meeting summary goes to
//  /api/summary (the free three) and anything else is refused; the server's
//  refusals read as what they are; the account's status and the
//  `daisy://subscription` link parse. A stubbed server, invented data.
//

import Foundation
import Testing
@testable import Daisy

/// The pages a store under test asked the browser to open.
@MainActor
final class OpenedPages {
    var urls: [URL] = []
}

/// Its own stub, so this suite can run beside CloudStreamingTests. What
/// the tests read and what the loading thread writes is behind one lock.
final class DaisyServerStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [(status: Int, body: String, headers: [String: String])] = []
    nonisolated(unsafe) private static var asked: [URLRequest] = []
    nonisolated(unsafe) private static var sent: [Data] = []
    nonisolated(unsafe) private static var heldPath: String?
    nonisolated(unsafe) private static var held: [() -> Void] = []
    /// Under `lock`: the request was given up, and nothing more is said to its client.
    private var stopped = false

    static var requests: [URLRequest] { lock.withLock { asked } }
    static var bodies: [Data] { lock.withLock { sent } }

    /// Requests to this path (its last component) get their answer only at
    /// `release()`: for what happens while a request is on its way.
    static func hold(_ path: String) {
        lock.withLock { heldPath = path }
    }

    /// Sends the answers held back, and holds no more: a request that
    /// arrives after this is answered at once, not left waiting.
    static func release() {
        let waiting = lock.withLock {
            heldPath = nil
            let all = held
            held = []
            return all
        }
        for answer in waiting { answer() }
    }

    static func reset(_ responses: [(status: Int, body: String, headers: [String: String])]) {
        lock.withLock {
            answers = responses
            asked = []
            sent = []
            heldPath = nil
            held = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            let size = 64 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            buffer.deallocate()
            stream.close()
        } else {
            data = request.httpBody ?? Data()
        }
        // Noted, and held or not, in one step: a test that sees the
        // request and releases finds its answer already held.
        let answerNow: (() -> Void)? = Self.lock.withLock {
            Self.asked.append(request)
            Self.sent.append(data)
            let next = Self.answers.isEmpty ? (status: 500, body: "no stub", headers: [:]) : Self.answers.removeFirst()
            let answer = { [self] in
                guard !Self.lock.withLock({ stopped }) else { return }
                let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1",
                                               headerFields: next.headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(next.body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            if let hold = Self.heldPath, request.url?.lastPathComponent == hold {
                Self.held.append(answer)
                return nil
            }
            return answer
        }
        answerNow?()
    }

    override func stopLoading() {
        Self.lock.withLock { stopped = true }
    }
}

@Suite("Daisy Subscription on the Mac", .serialized)
struct DaisySubscriptionTests {
    /// The stores' defaults: suites of this suite's own, gone with it (no
    /// plist left in ~/Library/Preferences).
    private let scratch = ScratchDefaults("DaisySubscription")

    private func session(_ responses: [(Int, String, [String: String])]) -> URLSession {
        DaisyServerStub.reset(responses.map { (status: $0.0, body: $0.1, headers: $0.2) })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DaisyServerStub.self]
        return URLSession(configuration: config)
    }

    private let sse = ["Content-Type": "text/event-stream"]
    private let json = ["Content-Type": "application/json"]
    private let transcript = String(repeating: "**[0:01 · Me]** We agreed on the launch plan and the budget for May.\n\n", count: 4)
    private let summaryJSON = #"{"summary":"Launch plan agreed.","sections":[],"actionItems":["Anna: send the budget"],"clientFollowUp":""}"#

    private func anthropicSSE(_ text: String, stop: String? = "end_turn") -> String {
        func event(_ name: String, _ data: [String: Any]) -> String {
            "event: \(name)\ndata: \(String(decoding: try! JSONSerialization.data(withJSONObject: data), as: UTF8.self))\n\n"
        }
        var out = event("message_start", ["type": "message_start", "message": ["usage": ["input_tokens": 100, "output_tokens": 1]]])
        out += event("content_block_start", ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]])
        out += event("content_block_delta", ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]])
        out += event("content_block_stop", ["type": "content_block_stop", "index": 0])
        if let stop {
            out += event("message_delta", ["type": "message_delta", "delta": ["stop_reason": stop], "usage": ["output_tokens": 40]])
            out += event("message_stop", ["type": "message_stop"])
        }
        return out
    }

    private func sentBody(_ index: Int = 0) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: DaisyServerStub.bodies[index]) as? [String: Any]) ?? [:]
    }

    @Test("a subscriber's summary goes to /v1/complete with the Mac's prompt and schema, and comes back")
    func subscriberSummary() async throws {
        let provider = DaisySubscriptionSummarizer(urlSession: session([(200, anthropicSSE(summaryJSON), sse)]),
                                                   sessionOverride: "s1.session.sig", subscribedOverride: true)
        let summary = try await provider.summarize(transcript: transcript, title: "Launch", localeHint: "en", task: .standard)
        #expect(summary.summary == "Launch plan agreed.")
        let request = try #require(DaisyServerStub.requests.first)
        #expect(request.url == DaisySubscriptionSummarizer.endpoint)
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer s1.session.sig")
        let body = sentBody()
        #expect(body["task"] as? String == "meeting")
        #expect((body["system"] as? String)?.isEmpty == false)
        #expect((body["user"] as? String)?.contains("launch plan") == true)
        // The schema goes in as an object, not as the placeholder string.
        #expect(body["schema"] is [String: Any])
        #expect(body["maxTokens"] as? Int == AnthropicAPISummarizer.maxOutputTokens(for: DaisySubscriptionSummarizer.serverModel))
    }

    @Test("dictation polish is a subscriber's task, with a small ceiling")
    func polishTask() async throws {
        let reply = #"{"summary":"","sections":[],"actionItems":[],"clientFollowUp":"Polished words"}"#
        let provider = DaisySubscriptionSummarizer(urlSession: session([(200, anthropicSSE(reply), sse)]),
                                                   sessionOverride: "s", subscribedOverride: true)
        let summary = try await provider.summarize(transcript: transcript, title: "Dictation", localeHint: nil,
                                                   task: .dictationPolish(instruction: "Keep my tone"))
        #expect(summary.clientFollowUp == "Polished words")
        let body = sentBody()
        #expect(body["task"] as? String == "dictationPolish")
        let user = try #require(body["user"] as? String)
        #expect(body["maxTokens"] as? Int == user.count + 4_000)
    }

    // MARK: - Dictation cleanup (28.11.2026)

    @Test("a dictation's cleanup goes without a schema, however short, and comes back as plain text")
    func cleanupTask() async throws {
        let provider = DaisySubscriptionSummarizer(urlSession: session([(200, anthropicSSE("Call me back."), sse)]),
                                                   sessionOverride: "s", subscribedOverride: true)
        // Ten characters: a summary's floor is not this task's.
        let summary = try await provider.summarize(transcript: "call me bk", title: "Dictation", localeHint: nil,
                                                   task: .dictationCleanup(.init(terms: ["Figma"])))
        #expect(summary.clientFollowUp == "Call me back.")
        #expect(DaisyServerStub.requests.first?.url == DaisySubscriptionSummarizer.endpoint)
        let body = sentBody()
        #expect(body["task"] as? String == "dictationCleanup")
        // No `schema` key at all: the server answers one with 400.
        #expect(Set(body.keys) == ["task", "system", "user", "maxTokens"])
        let user = try #require(body["user"] as? String)
        #expect(user == "<<<DICTATION>>>\ncall me bk\n<<<END DICTATION>>>")
        #expect(body["maxTokens"] as? Int == 64 + user.count)
        let system = try #require(body["system"] as? String)
        #expect(system.contains("Figma") && !system.contains("clientFollowUp"))
        #expect(!String(decoding: DaisyServerStub.bodies[0], as: UTF8.self).contains("daisy-reply-schema-"))
    }

    @Test("a cleanup cut at the ceiling, refused or broken off is not applied, though it came as HTTP 200 with text")
    func cleanupNotFinished() async throws {
        let input = "call me back at five tomorrow"
        func cleaned(stop: String?) async -> (text: String, outcome: DictationCleanup.Outcome) {
            let provider = DaisySubscriptionSummarizer(
                urlSession: session([(200, anthropicSSE("Call me back at five tomorrow.", stop: stop), sse)]),
                sessionOverride: "s", subscribedOverride: true)
            return await DictationCleanup.run(input, kind: .daisySubscription) { text in
                try await provider.summarize(transcript: text, title: "Dictation", localeHint: nil,
                                             task: .dictationCleanup(.init())).clientFollowUp
            }
        }
        let truncated = await cleaned(stop: "max_tokens")
        #expect(truncated.outcome == .rejected(.truncated) && truncated.text == input)
        let refused = await cleaned(stop: "refusal")
        #expect(refused.outcome == .rejected(.refused) && refused.text == input)
        let paused = await cleaned(stop: "pause_turn")
        #expect(paused.outcome == .rejected(.stopped) && paused.text == input)
        // No stop reason: the server's time ran out mid-answer.
        let cutOff = await cleaned(stop: nil)
        #expect(cutOff.outcome == .failed && cutOff.text == input)
        let finished = await cleaned(stop: "end_turn")
        #expect(finished.outcome == .applied && finished.text == "Call me back at five tomorrow.")
    }

    @Test("the cleanup is asked once, and without a subscription not at all")
    func cleanupIsNotRetried() async throws {
        let busy = DaisySubscriptionSummarizer(
            urlSession: session([(503, #"{"error":"provider_busy","providerStatus":529}"#, json), (200, anthropicSSE("Call me back."), sse)]),
            sessionOverride: "s", subscribedOverride: true)
        await #expect(throws: DaisySubscriptionError.busy) {
            _ = try await busy.summarize(transcript: "call me bk", title: "Dictation", localeHint: nil, task: .dictationCleanup(.init()))
        }
        #expect(DaisyServerStub.requests.count == 1)

        let free = DaisySubscriptionSummarizer(urlSession: session([]), sessionOverride: "s", subscribedOverride: false)
        await #expect(throws: DaisySubscriptionError.subscriptionRequired) {
            _ = try await free.summarize(transcript: "call me bk", title: "Dictation", localeHint: nil, task: .dictationCleanup(.init()))
        }
        #expect(DaisyServerStub.requests.isEmpty)
        // The ceiling asked for is what the server reserves: small.
        #expect(DaisySubscriptionSummarizer.maxTokens(for: .dictationCleanup(.init()), userChars: 100) == 164)
        #expect(DaisySubscriptionSummarizer.taskName(.dictationCleanup(.init())) == "dictationCleanup")
    }

    @Test("the cleanup goes by the status last read and never asks for it: no subscription known, nothing is sent")
    func cleanupUsesTheCachedStatus() async throws {
        func cleanup(_ store: DaisyAccountStore) async throws -> MeetingSummary {
            try await DaisySubscriptionSummarizer(urlSession: store.urlSessionForTests, accountStore: store)
                .summarize(transcript: "call me back at five tomorrow", title: "Dictation", localeHint: nil,
                           task: .dictationCleanup(.init()))
        }
        // Signed in, the status never read: not known to be active.
        let unknown = await account([(200, anthropicSSE("Call me back at five tomorrow."), sse)])
        do {
            _ = try await cleanup(unknown)
            Issue.record("sent without a known subscription")
        } catch {
            #expect(error as? DaisySubscriptionError == .subscriptionRequired)
            // The state it comes to: its own skip, not a failure the breaker counts.
            #expect(DictationCleanup.outcome(for: error) == .skipped(.noSubscription))
        }
        #expect(DaisyServerStub.requests.isEmpty)

        // Read as inactive: the same, and no free summary is spent on it.
        let inactive = await account([(200, statusJSON(active: false, trial: 3), json)])
        await inactive.refreshSubscription()
        await #expect(throws: DaisySubscriptionError.subscriptionRequired) { _ = try await cleanup(inactive) }
        #expect(DaisyServerStub.requests.count == 1)

        // Read as active: one request, the cleanup itself — no status read in front of it.
        let active = await account([(200, statusJSON(active: true, trial: 0), json),
                                    (200, anthropicSSE("Call me back at five tomorrow."), sse)])
        await active.refreshSubscription()
        #expect(try await cleanup(active).clientFollowUp == "Call me back at five tomorrow.")
        #expect(DaisyServerStub.requests.map { $0.url?.lastPathComponent } == ["subscription", "complete"])
    }

    @Test("the server saying there is no subscription is that state too, and a meeting's free summary is not spent on a dictation")
    func cleanupRefusedForNoSubscription() async throws {
        let provider = DaisySubscriptionSummarizer(
            urlSession: session([(402, #"{"error":"subscription_required"}"#, json)]),
            sessionOverride: "s", subscribedOverride: true)
        do {
            _ = try await provider.summarize(transcript: "call me back at five tomorrow", title: "Dictation", localeHint: nil,
                                             task: .dictationCleanup(.init()))
            Issue.record("a 402 read as an answer")
        } catch {
            #expect(error as? DaisySubscriptionError == .subscriptionRequired)
            #expect(DictationCleanup.outcome(for: error) == .skipped(.noSubscription))
        }
        #expect(DaisyServerStub.requests.map { $0.url?.lastPathComponent } == ["complete"])
        // The allowances used up are states of their own.
        for (code, reason) in [("daily_limit", DictationCleanup.SkipReason.dailyLimit), ("monthly_limit", .monthlyLimit)] {
            let limited = DaisySubscriptionSummarizer(urlSession: session([(429, #"{"error":"\#(code)"}"#, json)]),
                                                      sessionOverride: "s", subscribedOverride: true)
            let result = await DictationCleanup.run("call me back at five tomorrow", kind: .daisySubscription) { text in
                try await limited.summarize(transcript: text, title: "Dictation", localeHint: nil,
                                            task: .dictationCleanup(.init())).clientFollowUp
            }
            #expect(result.outcome == .skipped(reason), "\(code)")
            #expect(result.text == "call me back at five tomorrow")
        }
    }

    @Test("a session handed in from outside that the server refuses never signs this Mac's account out")
    func overriddenSessionDoesNotSignOut() async throws {
        // The bench's `DAISY_BENCH_SESSION`: another session than the store's.
        let store = await account([(401, #"{"error":"session_expired"}"#, json),
                                   (401, #"{"error":"session_expired"}"#, json),
                                   (401, #"{"error":"session_expired"}"#, json)])
        let subscribed = DaisySubscriptionSummarizer(urlSession: store.urlSessionForTests, sessionOverride: "another.session",
                                                     subscribedOverride: true, accountStore: store)
        await #expect(throws: DaisySubscriptionError.signedOut) {
            _ = try await subscribed.summarize(transcript: "call me back at five tomorrow", title: "Dictation", localeHint: nil,
                                               task: .dictationCleanup(.init()))
        }
        await #expect(throws: DaisySubscriptionError.signedOut) {
            _ = try await subscribed.summarize(transcript: transcript, title: "Launch", localeHint: "en", task: .standard)
        }
        // The free summaries' road too.
        let free = DaisySubscriptionSummarizer(urlSession: store.urlSessionForTests, sessionOverride: "another.session",
                                               subscribedOverride: false, accountStore: store)
        await #expect(throws: DaisySubscriptionError.signedOut) {
            _ = try await free.summarize(transcript: transcript, title: "Launch", localeHint: "en", task: .standard)
        }
        #expect(DaisyServerStub.requests.count == 3)
        #expect(await MainActor.run { store.isSignedIn && store.sessionToken == "s1.session.sig" })
    }

    @Test("without a subscription a meeting summary is one of the free three, on /api/summary")
    func freeSummary() async throws {
        let provider = DaisySubscriptionSummarizer(
            urlSession: session([(200, #"{"text":\#(String(reflecting: summaryJSON)),"trialRemaining":2}"#, json)]),
            sessionOverride: "s", subscribedOverride: false)
        let summary = try await provider.summarize(transcript: transcript, title: "Launch", localeHint: "en", task: .standard)
        #expect(summary.summary == "Launch plan agreed.")
        #expect(DaisyServerStub.requests.first?.url == DaisySubscriptionSummarizer.freeEndpoint)
        let body = sentBody()
        #expect(body["sessionToken"] as? String == "s")
        #expect(body["singleVoice"] as? Bool == false)
        #expect(body["system"] == nil)
    }

    @Test("without a subscription anything but a meeting summary is refused before sending")
    func freeRefusesOtherTasks() async throws {
        let provider = DaisySubscriptionSummarizer(urlSession: session([]), sessionOverride: "s", subscribedOverride: false)
        await #expect(throws: DaisySubscriptionError.subscriptionRequired) {
            _ = try await provider.summarize(transcript: transcript, title: "Dictation", localeHint: nil,
                                             task: .dictationPolish(instruction: "x"))
        }
        #expect(DaisyServerStub.requests.isEmpty)
    }

    @Test("the free three used up reads as such")
    func trialUsed() async throws {
        let provider = DaisySubscriptionSummarizer(urlSession: session([(402, #"{"error":"trial_used","trialRemaining":0}"#, json)]),
                                                   sessionOverride: "s", subscribedOverride: false)
        await #expect(throws: DaisySubscriptionError.trialUsed) {
            _ = try await provider.summarize(transcript: transcript, title: "Launch", localeHint: "en", task: .standard)
        }
    }

    @Test("a subscriber's day used up reads as the day's limit, asked once")
    func dailyLimit() async throws {
        let provider = DaisySubscriptionSummarizer(urlSession: session([(429, #"{"error":"daily_limit"}"#, json)]),
                                                   sessionOverride: "s", subscribedOverride: true)
        await #expect(throws: DaisySubscriptionError.dailyLimit) {
            _ = try await provider.summarize(transcript: transcript, title: "Launch", localeHint: "en", task: .standard)
        }
        #expect(DaisyServerStub.requests.count == 1)
    }

    @Test("Anthropic overloaded for a moment is asked again; the summary comes")
    func providerBusyIsRetried() async throws {
        let provider = DaisySubscriptionSummarizer(
            urlSession: session([(503, #"{"error":"provider_busy","providerStatus":529}"#, json), (200, anthropicSSE(summaryJSON), sse)]),
            sessionOverride: "s", subscribedOverride: true)
        let summary = try await provider.summarize(transcript: transcript, title: "Launch", localeHint: "en", task: .standard)
        #expect(summary.summary == "Launch plan agreed.")
        #expect(DaisyServerStub.requests.count == 2)
    }

    @Test("our own refusals are not retried")
    func refusalsAreNotRetried() {
        #expect(!DaisySubscriptionSummarizer.isRetryable(status: 503, body: #"{"error":"busy"}"#))
        #expect(!DaisySubscriptionSummarizer.isRetryable(status: 429, body: #"{"error":"rate_limit"}"#))
        #expect(!DaisySubscriptionSummarizer.isRetryable(status: 402, body: #"{"error":"subscription_required"}"#))
        #expect(DaisySubscriptionSummarizer.isRetryable(status: 503, body: #"{"error":"provider_unreachable"}"#))
        #expect(DaisySubscriptionSummarizer.isRetryable(status: 502, body: "Bad gateway"))
    }

    @Test("a status not known yet is no reason to take a subscriber for a free account")
    func unknownStatusGoesToComplete() async throws {
        let provider = DaisySubscriptionSummarizer(urlSession: session([(200, anthropicSSE(summaryJSON), sse)]),
                                                   sessionOverride: "s")
        _ = try await provider.summarize(transcript: transcript, title: "Launch", localeHint: "en", task: .standard)
        #expect(DaisyServerStub.requests.first?.url == DaisySubscriptionSummarizer.endpoint)
    }

    @Test("a free account's «Draft follow-up» spends no free summary")
    func freeRefusesFollowUp() async throws {
        let provider = DaisySubscriptionSummarizer(urlSession: session([]), sessionOverride: "s", subscribedOverride: false)
        await #expect(throws: DaisySubscriptionError.subscriptionRequired) {
            _ = try await provider.summarize(transcript: transcript, title: "Launch", localeHint: "en",
                                             task: .meeting(forceFollowUp: true))
        }
        #expect(DaisyServerStub.requests.isEmpty)
    }

    @Test("a stream that ends before Anthropic finished is no summary")
    func cutOff() async throws {
        let provider = DaisySubscriptionSummarizer(urlSession: session([(200, anthropicSSE(summaryJSON, stop: nil), sse)]),
                                                   sessionOverride: "s", subscribedOverride: true)
        do {
            _ = try await provider.summarize(transcript: transcript, title: "Launch", localeHint: "en", task: .standard)
            Issue.record("a cut-off stream was taken as a summary")
        } catch SummaryProviderError.streamInterrupted {
        }
    }

    /// A signed-in account of its own: scratch defaults, the stubbed server.
    @MainActor
    private func account(_ responses: [(Int, String, [String: String])], consented: Bool = true,
                         defaults: UserDefaults? = nil, opened: OpenedPages? = nil) -> DaisyAccountStore {
        // A wait that asks every 30 ms: the stub's answers are shared by
        // the suite, so a test that opens a checkout ends its wait itself
        // (`stopWaitingForPayment`, or signing out).
        let store = DaisyAccountStore(
            session: session(responses),
            defaults: defaults ?? scratch.make(),
            readStored: false,
            restoring: (token: "s1.session.sig", account: DaisyAccountInfo(id: "acct", email: nil, providers: ["email"])),
            openInBrowser: { opened?.urls.append($0) },
            pollInterval: .milliseconds(30))
        if consented { store.acknowledgeCloudDisclosure() }
        return store
    }

    private func statusJSON(active: Bool, trial: Int) -> String {
        active
            ? #"{"active":true,"sources":[{"source":"web","renewsAt":"2026-12-27T12:00:00.000Z"}],"trialRemaining":0}"#
            : #"{"active":false,"sources":[],"trialRemaining":\#(trial)}"#
    }

    @Test("signed in without the yes to sending text: not ready, and nothing is sent")
    func nothingWithoutConsent() async throws {
        let store = await account([], consented: false)
        let provider = DaisySubscriptionSummarizer(urlSession: session([]), accountStore: store)
        #expect(await provider.readiness() == .notReady)
        await #expect(throws: DaisySubscriptionError.consentNeeded) {
            _ = try await provider.summarize(transcript: transcript, title: "Launch", localeHint: "en", task: .standard)
        }
        #expect(DaisyServerStub.requests.isEmpty)
    }

    @Test("the yes is kept for the next launch, says so once, and goes with a deleted account")
    func consentIsKeptAndCleared() async throws {
        let defaults = scratch.make()
        let changes = await MainActor.run { () -> Int in
            let store = account([], consented: false, defaults: defaults)
            var count = 0
            store.onChange = { count += 1 }
            store.acknowledgeCloudDisclosure()
            store.acknowledgeCloudDisclosure()
            return count
        }
        #expect(changes == 1)
        let again = await account([(200, #"{"deleted":true,"subscriptionsCancelled":false,"linked":[]}"#, json)],
                                  consented: false, defaults: defaults)
        #expect(await MainActor.run { again.hasAcknowledgedCloudDisclosure })
        try await again.deleteAccount()
        #expect(await MainActor.run { !again.hasAcknowledgedCloudDisclosure && !again.isSignedIn })
        let afterDelete = await account([], consented: false, defaults: defaults)
        #expect(await MainActor.run { !afterDelete.hasAcknowledgedCloudDisclosure })
    }

    @Test("a session /v1/complete refuses signs the account out")
    func refusedSessionOnSendSignsOut() async throws {
        let store = await account([
            (200, statusJSON(active: true, trial: 0), json),
            (401, #"{"error":"session_expired"}"#, json),
        ])
        let provider = DaisySubscriptionSummarizer(urlSession: store.urlSessionForTests, accountStore: store)
        await #expect(throws: DaisySubscriptionError.signedOut) {
            _ = try await provider.summarize(transcript: transcript, title: "Launch", localeHint: "en", task: .standard)
        }
        #expect(await MainActor.run { !store.isSignedIn })
    }

    @Test("ready with a subscription or a free summary left; not ready with neither; a server that didn't answer is no «not set up»")
    func readiness() async throws {
        let subscribed = DaisySubscriptionSummarizer(accountStore: await account([(200, statusJSON(active: true, trial: 0), json)]))
        #expect(await subscribed.readiness() == .ready)
        let trial = DaisySubscriptionSummarizer(accountStore: await account([(200, statusJSON(active: false, trial: 2), json)]))
        #expect(await trial.readiness() == .ready)
        let used = DaisySubscriptionSummarizer(accountStore: await account([(200, statusJSON(active: false, trial: 0), json)]))
        #expect(await used.readiness() == .notReady)
        let down = DaisySubscriptionSummarizer(accountStore: await account([(500, "oops", json)]))
        guard case .checkFailed = await down.readiness() else {
            Issue.record("a failed check read as an answer")
            return
        }
    }

    @Test("a session the server refuses signs out, and the provider is not ready")
    func refusedSessionSignsOut() async throws {
        let store = await account([(401, #"{"error":"session_expired"}"#, json)])
        let provider = DaisySubscriptionSummarizer(accountStore: store)
        #expect(await provider.readiness() == .notReady)
        #expect(await MainActor.run { !store.isSignedIn })
    }

    @Test("a subscription that ended since the status was read: a meeting falls back to a free summary")
    func endedSubscriptionFallsBack() async throws {
        // Status read as active, then /v1/complete says 402, the status is
        // read again, and the meeting goes to /api/summary.
        let store = await account([
            (200, statusJSON(active: true, trial: 0), json),
            (402, #"{"error":"subscription_required"}"#, json),
            (200, statusJSON(active: false, trial: 3), json),
            (200, #"{"text":\#(String(reflecting: summaryJSON)),"trialRemaining":2}"#, json),
        ])
        let provider = DaisySubscriptionSummarizer(urlSession: store.urlSessionForTests, accountStore: store)
        let summary = try await provider.summarize(transcript: transcript, title: "Launch", localeHint: "en", task: .standard)
        #expect(summary.summary == "Launch plan agreed.")
        #expect(DaisyServerStub.requests.map(\.url) == [
            DaisyAccountStore.base.appendingPathComponent("subscription"), DaisySubscriptionSummarizer.endpoint,
            DaisyAccountStore.base.appendingPathComponent("subscription"), DaisySubscriptionSummarizer.freeEndpoint,
        ])
        #expect(await MainActor.run { store.subscription?.trialRemaining } == 2)
    }

    @Test("a checkout whose tab was closed is no dead end: the page opens again, and the wait can be called off")
    func checkoutCanBeReopenedAndCancelled() async throws {
        let opened = await MainActor.run { OpenedPages() }
        // Asked every 10 minutes here, so the only reads are the ones the test makes.
        let store = await MainActor.run {
            DaisyAccountStore(
                session: session([
                    (200, #"{"url":"https://whop.com/checkout/plan_x"}"#, json),
                    (200, statusJSON(active: false, trial: 3), json),
                ]),
                defaults: scratch.make(), readStored: false,
                restoring: (token: "s1.session.sig", account: DaisyAccountInfo(id: "acct", email: nil, providers: ["email"])),
                openInBrowser: { opened.urls.append($0) },
                pollInterval: .seconds(600))
        }
        try await store.checkout(.year)
        #expect(await MainActor.run { store.awaitingPayment })
        #expect(await MainActor.run { opened.urls } == [URL(string: "https://whop.com/checkout/plan_x")!])
        await MainActor.run { store.reopenCheckout() }
        let twice = await MainActor.run { opened.urls }
        #expect(twice.count == 2 && twice[1] == twice[0])
        await store.cancelCheckout()
        #expect(await MainActor.run { !store.awaitingPayment && store.pendingCheckout == nil })
        // Called off, the status was asked once (the checkout, then that read), and nothing reopens.
        #expect(DaisyServerStub.requests.map(\.url) == [
            DaisyAccountStore.base.appendingPathComponent("checkout"), DaisyAccountStore.base.appendingPathComponent("subscription"),
        ])
        await MainActor.run { store.reopenCheckout() }
        #expect(await MainActor.run { opened.urls.count } == 2)
        await MainActor.run { store.stopWaitingForPayment() }
    }

    /// Waits, up to 3 s, for what a quick wait should bring.
    private func eventually(_ condition: @MainActor @Sendable () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if await MainActor.run(body: condition) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test("a payment made before Cancel is still seen: the asking goes on quietly, and the plan row gives way to Active")
    func cancelledCheckoutStillSeesThePayment() async throws {
        let store = await account([
            (200, #"{"url":"https://whop.com/checkout/plan_x"}"#, json),
            (200, statusJSON(active: false, trial: 3), json),
            (200, statusJSON(active: false, trial: 3), json),
            (200, statusJSON(active: true, trial: 0), json),
        ])
        // In one hop to the main actor, so the quiet asking can't run between the two.
        try await Task { @MainActor in
            try await store.checkout(.month)
            await store.cancelCheckout()
        }.value
        #expect(await MainActor.run { !store.awaitingPayment })
        #expect(await eventually { store.subscription?.active == true })
        #expect(await MainActor.run { !store.awaitingPayment && store.pendingCheckout == nil })
        // Seen, the asking is over: nothing more is requested.
        let asked = DaisyServerStub.requests.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(DaisyServerStub.requests.count == asked)
    }

    @Test("back from the payment page before Whop has reported it: the wait starts again and ends as Active")
    func returnLinkResumesTheWait() async {
        let store = await account([
            (200, statusJSON(active: false, trial: 3), json),
            (200, statusJSON(active: true, trial: 0), json),
        ])
        await store.returnedFromCheckout()
        // No page to reopen: this wait began from the link, not from a checkout here.
        #expect(await MainActor.run { store.pendingCheckout == nil })
        #expect(await eventually { store.subscription?.active == true && !store.awaitingPayment })
    }

    @Test("back from the payment page of a checkout opened here: that page is not offered again, and paying turns the switch")
    func returnLinkAfterACheckoutHere() async throws {
        let opened = await MainActor.run { OpenedPages() }
        let paid = await MainActor.run { OpenedPages() }
        let store = await account([
            (200, #"{"url":"https://whop.com/checkout/plan_x"}"#, json),
            (200, statusJSON(active: false, trial: 3), json),
            (200, statusJSON(active: false, trial: 3), json),
            (200, statusJSON(active: true, trial: 0), json),
            (200, statusJSON(active: true, trial: 0), json),
        ], opened: opened)
        await MainActor.run { store.onPaid = { paid.urls.append(URL(string: "daisy://paid")!) } }
        // In one hop to the main actor, so the first wait asks nothing in between.
        try await Task { @MainActor in
            try await store.checkout(.year)
            await store.returnedFromCheckout()
        }.value
        #expect(await MainActor.run { store.pendingCheckout == nil })
        await MainActor.run { store.reopenCheckout() }
        #expect(await MainActor.run { opened.urls.count } == 1)
        #expect(await eventually { store.subscription?.active == true && !store.awaitingPayment })
        // Seen while the wait was showing: said once.
        #expect(await MainActor.run { paid.urls.count } == 1)
    }

    @Test("a payment seen after Cancel doesn't turn the switch: the wait was called off")
    func paymentAfterCancelLeavesTheSwitch() async throws {
        let paid = await MainActor.run { OpenedPages() }
        let store = await account([
            (200, #"{"url":"https://whop.com/checkout/plan_x"}"#, json),
            (200, statusJSON(active: false, trial: 3), json),
            (200, statusJSON(active: false, trial: 3), json),
            (200, statusJSON(active: true, trial: 0), json),
        ])
        await MainActor.run { store.onPaid = { paid.urls.append(URL(string: "daisy://paid")!) } }
        // In one hop to the main actor: the wait is called off before anything is asked.
        try await Task { @MainActor in
            try await store.checkout(.month)
            await store.cancelCheckout()
        }.value
        #expect(await eventually { store.subscription?.active == true })
        #expect(await MainActor.run { paid.urls.isEmpty })
    }

    @Test("back from a page that said the payment wasn't completed: the prices again, no wait, no switch")
    func returnLinkAfterAFailedPayment() async throws {
        let paid = await MainActor.run { OpenedPages() }
        let store = await MainActor.run {
            DaisyAccountStore(
                session: session([
                    (200, #"{"url":"https://whop.com/checkout/plan_x"}"#, json),
                    (200, statusJSON(active: false, trial: 3), json),
                ]),
                defaults: scratch.make(), readStored: false,
                restoring: (token: "s1.session.sig", account: DaisyAccountInfo(id: "acct", email: nil, providers: ["email"])),
                openInBrowser: { _ in },
                pollInterval: .seconds(600))
        }
        await MainActor.run { store.onPaid = { paid.urls.append(URL(string: "daisy://paid")!) } }
        try await store.checkout(.year)
        await store.returnedFromCheckout(paymentFailed: true)
        #expect(await MainActor.run { !store.awaitingPayment && store.pendingCheckout == nil })
        #expect(await MainActor.run { store.subscription?.active == false && paid.urls.isEmpty })
        await MainActor.run { store.stopWaitingForPayment() }

        // With no checkout open here (the link typed, or Daisy started by it): one read, and no wait.
        let cold = await account([(200, statusJSON(active: false, trial: 3), json)])
        await cold.returnedFromCheckout(paymentFailed: true)
        #expect(await MainActor.run { !cold.awaitingPayment })
        try await Task.sleep(for: .milliseconds(100))
        #expect(DaisyServerStub.requests.count == 1)
    }

    @Test("paid while the wait was called off: a second checkout the server still lets through opens no page")
    func paidMeanwhileOpensNoSecondPage() async throws {
        let opened = await MainActor.run { OpenedPages() }
        let store = await account([
            (200, #"{"url":"https://whop.com/checkout/plan_x"}"#, json),
            (200, statusJSON(active: false, trial: 3), json),
            (200, statusJSON(active: true, trial: 0), json),
            (200, #"{"url":"https://whop.com/checkout/plan_y"}"#, json),
        ], opened: opened)
        try await Task { @MainActor in
            try await store.checkout(.month)
            await store.cancelCheckout()
        }.value
        #expect(await eventually { store.subscription?.active == true })
        do {
            try await store.checkout(.year)
            Issue.record("a second page opened for a subscriber")
        } catch {
            #expect(error as? DaisyAccountFailure == .alreadySubscribed)
        }
        #expect(await MainActor.run { opened.urls.count } == 1)
        #expect(await MainActor.run { !store.awaitingPayment && store.pendingCheckout == nil })
    }

    @Test("a wait replaced while it was asking doesn't end the one that replaced it")
    func replacedWaitLeavesTheNewOne() async throws {
        let opened = await MainActor.run { OpenedPages() }
        let store = await account([
            (200, #"{"url":"https://whop.com/checkout/plan_x"}"#, json),
            (200, statusJSON(active: false, trial: 3), json),
            (200, #"{"url":"https://whop.com/checkout/plan_y"}"#, json),
        ], opened: opened)
        // The first wait's question stays on its way…
        DaisyServerStub.hold("subscription")
        try await store.checkout(.year)
        #expect(await eventually { DaisyServerStub.requests.count == 2 })
        // …and is given up when the second checkout starts its own wait.
        try await store.checkout(.month)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await MainActor.run { store.awaitingPayment })
        #expect(await MainActor.run { store.pendingCheckout } == URL(string: "https://whop.com/checkout/plan_y")!)
        await MainActor.run { store.stopWaitingForPayment() }
    }

    @Test("signed out while the payment page was being made: no page, no wait")
    func signOutDuringCheckout() async throws {
        let opened = await MainActor.run { OpenedPages() }
        let store = await account([(200, #"{"url":"https://whop.com/checkout/plan_x"}"#, json)], opened: opened)
        DaisyServerStub.hold("checkout")
        let pending = Task { @MainActor in try await store.checkout(.year) }
        #expect(await eventually { DaisyServerStub.requests.count == 1 })
        await MainActor.run { store.signOut() }
        DaisyServerStub.release()
        do {
            try await pending.value
            Issue.record("a checkout went through for a session that is gone")
        } catch {
            #expect(error as? DaisyAccountFailure == .signedOut)
        }
        #expect(await MainActor.run { !store.awaitingPayment && store.pendingCheckout == nil && opened.urls.isEmpty })
    }

    @Test("a status that arrives after signing out is nobody's")
    func statusAfterSignOut() async {
        let store = await account([(200, statusJSON(active: true, trial: 0), json)])
        DaisyServerStub.hold("subscription")
        let pending = Task { @MainActor in await store.refreshSubscription() }
        #expect(await eventually { DaisyServerStub.requests.count == 1 })
        await MainActor.run { store.signOut() }
        DaisyServerStub.release()
        #expect(await pending.value == nil)
        #expect(await MainActor.run { store.subscription == nil && !store.subscriptionCheckFailed })
    }

    @Test("a read that failed starts no wait for someone already subscribed")
    func returnLinkWithAFailedReadAndASubscription() async {
        let store = await account([
            (200, statusJSON(active: true, trial: 0), json),
            (500, "oops", json),
        ])
        await store.refreshSubscription()
        await store.returnedFromCheckout()
        #expect(await MainActor.run { store.subscription?.active == true && !store.awaitingPayment })
        #expect(DaisyServerStub.requests.count == 2)
    }

    @Test("called off, then a second checkout: its wait is its own")
    func secondCheckoutAfterCancel() async throws {
        let opened = await MainActor.run { OpenedPages() }
        let store = await MainActor.run {
            DaisyAccountStore(
                session: session([
                    (200, #"{"url":"https://whop.com/checkout/plan_x"}"#, json),
                    (200, statusJSON(active: false, trial: 3), json),
                    (200, #"{"url":"https://whop.com/checkout/plan_y"}"#, json),
                ]),
                defaults: scratch.make(), readStored: false,
                restoring: (token: "s1.session.sig", account: DaisyAccountInfo(id: "acct", email: nil, providers: ["email"])),
                openInBrowser: { opened.urls.append($0) },
                pollInterval: .seconds(600))
        }
        try await store.checkout(.year)
        await store.cancelCheckout()
        try await store.checkout(.month)
        // The first wait's task was replaced; give its end a moment to (not) clear the second.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await MainActor.run { store.awaitingPayment })
        #expect(await MainActor.run { store.pendingCheckout } == URL(string: "https://whop.com/checkout/plan_y")!)
        await MainActor.run { store.stopWaitingForPayment() }
    }

    @Test("back from the payment page with the subscription already active: no wait")
    func returnLinkWithAnActiveSubscription() async {
        let store = await account([(200, statusJSON(active: true, trial: 0), json)])
        await store.returnedFromCheckout()
        #expect(await MainActor.run { store.subscription?.active == true && !store.awaitingPayment })
        #expect(DaisyServerStub.requests.count == 1)
    }

    @Test("signing out ends a wait for a payment, and its page is forgotten")
    func signOutEndsTheWait() async throws {
        let opened = await MainActor.run { OpenedPages() }
        let store = await account([(200, #"{"url":"https://whop.com/checkout/plan_x"}"#, json)], opened: opened)
        try await store.checkout(.year)
        #expect(await MainActor.run { store.awaitingPayment && store.pendingCheckout != nil })
        await MainActor.run { store.signOut() }
        #expect(await MainActor.run { !store.awaitingPayment && store.pendingCheckout == nil })
        await MainActor.run { store.reopenCheckout() }
        #expect(await MainActor.run { opened.urls.count } == 1)
        // Nothing is asked for a session that is gone.
        let asked = DaisyServerStub.requests.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(DaisyServerStub.requests.count == asked)
    }

    @Test("a wait that runs out ends by itself")
    func waitRunsOut() async throws {
        let store = await MainActor.run {
            DaisyAccountStore(
                session: session([(200, #"{"url":"https://whop.com/checkout/plan_x"}"#, json)]),
                defaults: scratch.make(), readStored: false,
                restoring: (token: "s1.session.sig", account: DaisyAccountInfo(id: "acct", email: nil, providers: ["email"])),
                openInBrowser: { _ in },
                paymentWait: .milliseconds(600), pollInterval: .milliseconds(30))
        }
        // In one hop to the main actor: the wait is 600 ms.
        let waiting = try await Task { @MainActor in
            try await store.checkout(.year)
            return store.awaitingPayment
        }.value
        #expect(waiting)
        #expect(await eventually { !store.awaitingPayment && store.pendingCheckout == nil })
        await MainActor.run { store.stopWaitingForPayment() }
    }

    @Test("the plan picked is the plan asked for", arguments: [DaisyAccountStore.Plan.month, .year])
    func checkoutAsksForThePickedPlan(plan: DaisyAccountStore.Plan) async throws {
        let store = await account([(200, #"{"url":"https://whop.com/checkout/plan_x"}"#, json)])
        try await store.checkout(plan)
        await MainActor.run { store.stopWaitingForPayment() }
        #expect(DaisyServerStub.requests.first?.url == DaisyAccountStore.base.appendingPathComponent("checkout"))
        #expect(sentBody()["plan"] as? String == plan.rawValue)
        #expect(["month", "year"].contains(plan.rawValue))
    }

    @Test("a second checkout for an account that already pays is refused, and Settings shows it as Active")
    func checkoutRefusedForASubscriber() async {
        let opened = await MainActor.run { OpenedPages() }
        let store = await account([
            (409, #"{"error":"already_subscribed"}"#, json),
            (200, statusJSON(active: true, trial: 0), json),
        ], opened: opened)
        do {
            try await store.checkout(.year)
            Issue.record("a second checkout went through")
        } catch {
            #expect(error as? DaisyAccountFailure == .alreadySubscribed)
        }
        #expect(await MainActor.run { store.subscription?.active == true && !store.awaitingPayment })
        #expect(await MainActor.run { opened.urls.isEmpty })
    }

    @Test("the server's refusals map to their own errors")
    func refusals() {
        #expect(DaisySubscriptionError.from(status: 401, body: #"{"error":"session_expired"}"#) == .signedOut)
        #expect(DaisySubscriptionError.from(status: 402, body: #"{"error":"subscription_required"}"#) == .subscriptionRequired)
        #expect(DaisySubscriptionError.from(status: 402, body: #"{"error":"trial_used"}"#) == .trialUsed)
        #expect(DaisySubscriptionError.from(status: 429, body: #"{"error":"monthly_limit"}"#) == .monthlyLimit)
        #expect(DaisySubscriptionError.from(status: 503, body: #"{"error":"busy"}"#) == .busy)
        #expect(DaisySubscriptionError.from(status: 502, body: #"{"error":"provider_failed"}"#) == nil)
    }

    @Test("every task has the server's name for it")
    func taskNames() {
        #expect(DaisySubscriptionSummarizer.taskName(.standard) == "meeting")
        #expect(DaisySubscriptionSummarizer.taskName(.catchUp) == "catchUp")
        #expect(DaisySubscriptionSummarizer.taskName(.morningBrief) == "morningBrief")
        #expect(DaisySubscriptionSummarizer.taskName(.voiceProfile) == "voiceProfile")
    }

    @Test("the subscription's status parses, and only an https page is kept to manage it")
    func status() throws {
        let raw: [String: Any] = [
            "active": true, "trialRemaining": 0,
            "sources": [
                ["source": "appstore", "renewsAt": "2026-12-27T12:00:00.000Z", "manageUrl": "https://apps.apple.com/account/subscriptions"],
                ["source": "web", "renewsAt": "2026-12-20T12:00:00Z", "willRenew": false, "manageUrl": "javascript:alert(1)"],
                ["source": "elsewhere"],
            ],
        ]
        let status = try #require(DaisySubscriptionStatus.parse(raw))
        #expect(status.active)
        #expect(status.sources.count == 2)
        #expect(status.primary?.kind == .web)
        #expect(status.primary?.manageURL == nil)
        #expect(status.primary?.willRenew == false)
        #expect(status.sources[0].renewsAt != nil)
        #expect(status.sources[1].renewsAt != nil)
        #expect(DaisySubscriptionStatus.parse(["sources": []]) == nil)
        let free = try #require(DaisySubscriptionStatus.parse(["active": false, "sources": [], "trialRemaining": 2]))
        #expect(!free.active && free.trialRemaining == 2 && free.primary == nil)
    }

    @Test("sign-in refusals read as the iPhone's")
    func accountFailures() {
        #expect(DaisyAccountFailure.from(status: 400, json: ["error": "wrong_code", "triesLeft": 3]) == .wrongCode(triesLeft: 3))
        #expect(DaisyAccountFailure.from(status: 429, json: ["error": "too_many_codes"]) == .tooManyCodes)
        #expect(DaisyAccountFailure.from(status: 409, json: ["error": "already_subscribed"]) == .alreadySubscribed)
        #expect(DaisyAccountFailure.from(status: 404, json: ["error": "not_found"]) == .checkoutUnavailable)
        #expect(DaisyAccountFailure.from(status: 429, json: ["error": "rate_limit"]) == .tooManyTries)
        #expect(DaisyAccountFailure.from(status: 401, json: nil) == .signedOut)
        #expect(DaisyAccountFailure.from(status: 503, json: nil) == .unavailable)
        #expect(DaisyAccountFailure.from(status: 500, json: nil) == .server)
    }

    @Test("daisy://subscription is the way back from the website")
    func link() {
        #expect(DaisyLink(URL(string: "daisy://subscription")!) == .subscription(paymentFailed: false))
        #expect(DaisyLink(URL(string: "daisy://subscription/")!) == .subscription(paymentFailed: false))
        // The page that says the payment wasn't completed adds this; anything else is the usual way back.
        #expect(DaisyLink(URL(string: "daisy://subscription?status=failed")!) == .subscription(paymentFailed: true))
        #expect(DaisyLink(URL(string: "daisy://subscription/?status=FAILED")!) == .subscription(paymentFailed: true))
        #expect(DaisyLink(URL(string: "daisy://subscription?status=success")!) == .subscription(paymentFailed: false))
        #expect(DaisyLink(URL(string: "daisy://subscription?other=failed")!) == .subscription(paymentFailed: false))
        #expect(DaisyLink(URL(string: "daisy://subscription/x")!) == nil)
        #expect(DaisyLink(URL(string: "daisy://session/2026-11-27_meet")!) == .session("2026-11-27_meet"))
    }
}
