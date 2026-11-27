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

/// Its own stub, so this suite can run beside CloudStreamingTests.
final class DaisyServerStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [(status: Int, body: String, headers: [String: String])] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
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
        Self.bodies.append(data)
        let next = Self.responses.isEmpty ? (status: 500, body: "no stub", headers: [:]) : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1",
                                       headerFields: next.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Daisy Subscription on the Mac", .serialized)
struct DaisySubscriptionTests {
    /// The stores' defaults: suites of this suite's own, gone with it (no
    /// plist left in ~/Library/Preferences).
    private let scratch = ScratchDefaults("DaisySubscription")

    private func session(_ responses: [(Int, String, [String: String])]) -> URLSession {
        DaisyServerStub.responses = responses.map { (status: $0.0, body: $0.1, headers: $0.2) }
        DaisyServerStub.requests = []
        DaisyServerStub.bodies = []
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
                         defaults: UserDefaults? = nil) -> DaisyAccountStore {
        let store = DaisyAccountStore(
            session: session(responses),
            defaults: defaults ?? scratch.make(),
            readStored: false,
            restoring: (token: "s1.session.sig", account: DaisyAccountInfo(id: "acct", email: nil, providers: ["email"])))
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
        #expect(DaisyLink(URL(string: "daisy://subscription")!) == .subscription)
        #expect(DaisyLink(URL(string: "daisy://subscription/")!) == .subscription)
        #expect(DaisyLink(URL(string: "daisy://subscription/x")!) == nil)
        #expect(DaisyLink(URL(string: "daisy://session/2026-11-27_meet")!) == .session("2026-11-27_meet"))
    }
}
