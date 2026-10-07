import Foundation
import Testing
@testable import DaisyCore

/// Stands in for `daisy-api`: records what the phone sent, answers as told.
nonisolated final class ProxyStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastBody: [String: Any] = [:]
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var reply: [String: Any] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 4096); if n <= 0 { break }; data.append(buffer, count: n) }
            body = data
        }
        Self.lastBody = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: Self.reply))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("The phone's side of the summary proxy", .serialized)
struct SummaryProxyClientTests {
    private func client() -> SummaryProxyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProxyStub.self]
        return SummaryProxyClient(endpoint: URL(string: "https://example.invalid/api/summary")!, session: URLSession(configuration: config))
    }

    private let transcript = """
    **[0:29 · Мария]** Привет, Влад! Я решила тебе отдать этих ребят.
    **[0:57 · Мария]** Кирилл, добрый день! Пишите на kirill@example.com, договор пришлю Владу.
    """

    @Test func namesAndContactsNeverLeaveThePhone() async throws {
        ProxyStub.status = 200
        ProxyStub.reply = ["text": #"{"summary":"[[DAISY_PERSON_001]] передаёт клиентов [[DAISY_PERSON_002]]","sections":[],"actionItems":["Написать [[DAISY_EMAIL_001]]"],"clientFollowUp":""}"#]
        let result = try await client().summarize(
            transcript: transcript, title: "AIBY | Мария и Влад", localeHint: "ru", singleVoice: false,
            credential: .subscription("jws"), knownPeople: ["Мария", "Влад", "Кирилл"])

        let sent = String(describing: ProxyStub.lastBody)
        for secret in ["Мария", "Влад", "Кирилл", "kirill@example.com"] {
            #expect(!sent.contains(secret), "\(secret) left the phone")
        }
        #expect(ProxyStub.lastBody["signedTransaction"] as? String == "jws")
        #expect(ProxyStub.lastBody["localeHint"] as? String == "ru")
        #expect(ProxyStub.lastBody["prompt"] == nil && ProxyStub.lastBody["system"] == nil)

        #expect(result.summary.summary == "Мария передаёт клиентов Влад")
        #expect(result.summary.actionItems == ["Написать kirill@example.com"])
        #expect(result.report.replacementsByKind[.email] == 1)
    }

    @Test func takeFeedbackGoesWithoutNamesOrAPrompt() async throws {
        ProxyStub.status = 200
        ProxyStub.reply = ["text": "- «[[DAISY_PERSON_001]]» в начале звучит сухо"]
        let text = try await client().feedback(
            script: "Привет! Меня зовут Мария.", take: "Привет! Меня зовут [Мария → Маша].",
            facts: "Length: 0:05", language: "ru", signedTransaction: "jws", knownPeople: ["Мария"])
        let sent = String(describing: ProxyStub.lastBody)
        #expect(!sent.contains("Мария"))
        #expect(ProxyStub.lastBody["system"] == nil && ProxyStub.lastBody["prompt"] == nil)
        #expect(ProxyStub.lastBody["facts"] as? String == "Length: 0:05")
        #expect(text == "- «Мария» в начале звучит сухо")
    }

    @Test func threeFailuresAreThreeDifferentThings() async {
        let cases: [(Int, SummaryProxyClient.Failure)] = [(401, .subscription), (402, .trialUsed), (429, .limit),
                                                          (502, .provider), (500, .server)]
        for (status, expected) in cases {
            ProxyStub.status = status
            ProxyStub.reply = ["error": "x"]
            await #expect(throws: expected) {
                try await client().summarize(transcript: transcript, title: "t", localeHint: nil, singleVoice: false,
                                             credential: .subscription("jws"), knownPeople: [])
            }
        }
    }

    /// Backlog 19 А-1: before a subscription, the device token goes instead
    /// of a transaction, and the server's count of free uses comes back.
    @Test func theTrialSendsTheTokenAndReadsWhatIsLeft() async throws {
        ProxyStub.status = 200
        ProxyStub.reply = ["text": #"{"summary":"s","sections":[],"actionItems":[],"clientFollowUp":""}"#, "trialRemaining": 2]
        let result = try await client().summarize(transcript: transcript, title: "t", localeHint: nil, singleVoice: false,
                                                  credential: .trial("3F2504E0-4F89-41D3-9A0C-0305E82C3301"), knownPeople: [])
        #expect(ProxyStub.lastBody["trialToken"] as? String == "3F2504E0-4F89-41D3-9A0C-0305E82C3301")
        #expect(ProxyStub.lastBody["signedTransaction"] == nil)
        #expect(result.trialRemaining == 2)
    }
}
