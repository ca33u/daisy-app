//
//  SummaryProxyClient.swift
//  DaisyCore
//
//  Backlog 19 А-1/А-2а: the phone-only subscriber's summary. The
//  transcript leaves the phone for the first time here, so everything
//  that can be kept back is kept back: names, contacts and secrets are
//  replaced by markers on the device (`PseudonymSession`, always on, no
//  switch), the server gets the markers and the Apple-signed transaction,
//  and the markers are put back only here, after the answer.
//
//  The server (`daisy-api`) owns the prompt and the answer's shape; this
//  sends text and parameters, never a prompt.
//

import Foundation

/// What lets the phone use Daisy's proxy (backlog 19 А-1): a live
/// subscription Apple signed, or the trial — the first three summaries or
/// questions, counted by the server per device token.
public nonisolated enum ProxyCredential: Sendable, Equatable {
    case subscription(String)
    case trial(String)

    var fields: [String: Any] {
        switch self {
        case .subscription(let jws): ["signedTransaction": jws]
        case .trial(let token): ["trialToken": token]
        }
    }
}

public nonisolated struct SummaryProxyClient: Sendable {
    /// Where `daisy-api` answers. Not live until it is deployed.
    public static let defaultEndpoint = URL(string: "https://api.mydaisy.io/api/summary")!

    public enum Failure: LocalizedError, Equatable, Sendable {
        /// The subscription ran out, was refunded, or the receipt is not ours.
        case subscription
        /// The free three are used; a subscription is next.
        case trialUsed
        /// Today's characters are spent, or too many requests this minute.
        case limit
        /// The provider refused or answered with something that is not a summary.
        case provider
        /// Our server could not be reached or failed.
        case server
        case tooShort

        public var errorDescription: String? {
            switch self {
            case .subscription: String(localized: "The summary subscription isn't active. The transcript is safe; renew to get the summary.")
            case .trialUsed: String(localized: "Your free summaries and questions are used. The transcript is safe; subscribe to get the summary.")
            case .limit: String(localized: "Today's summary allowance is used up. The transcript is safe; the summary will be made later.")
            case .provider: String(localized: "The summary service couldn't make this summary. The transcript is safe; Daisy will try again.")
            case .server: String(localized: "Daisy's summary server can't be reached. The transcript is safe; Daisy will try again.")
            case .tooShort: String(localized: "The transcript is too short to summarize.")
            }
        }
    }

    public struct Result: Sendable {
        public let summary: MeetingSummary
        /// What was replaced before sending — shown to the person.
        public let report: SensitiveDataProtectionReport
        /// Free uses left, when this one was on the trial.
        public let trialRemaining: Int?
    }

    let endpoint: URL
    let session: URLSession

    public init(endpoint: URL = defaultEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public func summarize(
        transcript: String, title: String, localeHint: String?, singleVoice: Bool,
        credential: ProxyCredential, knownPeople: [String]
    ) async throws -> Result {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else { throw Failure.tooShort }

        var pseudonyms = PseudonymSession(knownPeople: knownPeople)
        let sentTitle = pseudonyms.protect(title)
        let sentTranscript = pseudonyms.protect(trimmed)
        let body: [String: Any] = [
            "title": sentTitle,
            "transcript": sentTranscript,
            "localeHint": localeHint as Any,
            "singleVoice": singleVoice,
        ].merging(credential.fields) { a, _ in a }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.server
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 401: throw Failure.subscription
        case 402: throw Failure.trialUsed
        case 429: throw Failure.limit
        case 502: throw Failure.provider
        case 400:
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw code == "transcript_too_short" ? Failure.tooShort : Failure.server
        default: throw Failure.server
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else { throw Failure.provider }
        let summary = try CloudSummaryCall.decode(text, provider: "Daisy")
        return Result(summary: pseudonyms.restore(summary), report: pseudonyms.report,
                      trialRemaining: json["trialRemaining"] as? Int)
    }
}
