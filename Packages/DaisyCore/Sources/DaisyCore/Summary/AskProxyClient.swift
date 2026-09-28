//
//  AskProxyClient.swift
//  DaisyCore
//
//  Backlog 21 Ч-2: a question to one's recordings for a subscriber with
//  no key — the same road as the summary (SummaryProxyClient): the
//  question, the found pieces and the earlier turns are pseudonymized on
//  the phone, the server adds its own prompt (AskPrompt, exported), and
//  the names come back only here, in the answer.
//

import Foundation

public nonisolated struct AskProxyClient: Sendable {
    public static let defaultEndpoint = URL(string: "https://api.mydaisy.io/api/ask")!

    let endpoint: URL
    let session: URLSession

    public init(endpoint: URL = defaultEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public struct Result: Sendable {
        public let answer: String
        public let report: SensitiveDataProtectionReport
    }

    /// `history` is the earlier turns, oldest first (question, answer).
    public func ask(question: String, sources: [AskPrompt.Source], history: [CloudText.Message],
                    today: String, signedTransaction: String, knownPeople: [String]) async throws -> Result {
        var pseudonyms = PseudonymSession(knownPeople: knownPeople)
        let protectedSources = sources.map { source -> AskPrompt.Source in
            var s = source
            s.title = pseudonyms.protect(s.title)
            s.summary = s.summary.map { pseudonyms.protect($0) }
            s.pieces = s.pieces.map { ($0.0, pseudonyms.protect($0.1)) }
            return s
        }
        let material = AskPrompt.user(question: pseudonyms.protect(question), sources: protectedSources, today: today)
        let turns = history.suffix(AskLimits.historyTurns * 2).map { ["role": $0.role.rawValue, "text": pseudonyms.protect($0.text)] }
        let body: [String: Any] = [
            "signedTransaction": signedTransaction,
            "material": material,
            "history": turns,
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SummaryProxyClient.Failure.server
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401: throw SummaryProxyClient.Failure.subscription
        case 429: throw SummaryProxyClient.Failure.limit
        case 502: throw SummaryProxyClient.Failure.provider
        default: throw SummaryProxyClient.Failure.server
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else { throw SummaryProxyClient.Failure.provider }
        return Result(answer: pseudonyms.restore(text), report: pseudonyms.report)
    }
}
