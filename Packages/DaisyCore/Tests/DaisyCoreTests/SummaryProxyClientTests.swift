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
    **[0:57 · Мария]** Кирилл, добрый день! Пишите на kirill@aiby.com, договор пришлю Владу.
    """

    @Test func namesAndContactsNeverLeaveThePhone() async throws {
        ProxyStub.status = 200
        ProxyStub.reply = ["text": #"{"summary":"[[DAISY_PERSON_001]] передаёт клиентов [[DAISY_PERSON_002]]","sections":[],"actionItems":["Написать [[DAISY_EMAIL_001]]"],"clientFollowUp":""}"#]
        let result = try await client().summarize(
            transcript: transcript, title: "AIBY | Мария и Влад", localeHint: "ru", singleVoice: false,
            signedTransaction: "jws", knownPeople: ["Мария", "Влад", "Кирилл"])

        let sent = String(describing: ProxyStub.lastBody)
        for secret in ["Мария", "Влад", "Кирилл", "kirill@aiby.com"] {
            #expect(!sent.contains(secret), "\(secret) left the phone")
        }
        #expect(ProxyStub.lastBody["signedTransaction"] as? String == "jws")
        #expect(ProxyStub.lastBody["localeHint"] as? String == "ru")
        #expect(ProxyStub.lastBody["prompt"] == nil && ProxyStub.lastBody["system"] == nil)

        #expect(result.summary.summary == "Мария передаёт клиентов Влад")
        #expect(result.summary.actionItems == ["Написать kirill@aiby.com"])
        #expect(result.report.replacementsByKind[.email] == 1)
    }

    @Test func threeFailuresAreThreeDifferentThings() async {
        let cases: [(Int, SummaryProxyClient.Failure)] = [(401, .subscription), (429, .limit), (502, .provider), (500, .server)]
        for (status, expected) in cases {
            ProxyStub.status = status
            ProxyStub.reply = ["error": "x"]
            await #expect(throws: expected) {
                try await client().summarize(transcript: transcript, title: "t", localeHint: nil, singleVoice: false,
                                             signedTransaction: "jws", knownPeople: [])
            }
        }
    }
}
