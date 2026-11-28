//
//  DaisySubscriptionSummarizer.swift
//  Daisy
//
//  «Подписка Daisy» as the summary provider (27.11, Egor: summaries through
//  the subscription «и всё, что у нас сейчас через API и модели идёт»,
//  dictation polish included). Every job the Mac gives a provider — the
//  meeting summary and its templates, the brief, dictation and transcript
//  polish, speaker names, catch-up, the morning brief, Daisy-key commands —
//  goes to daisy-api's POST /v1/complete with the signed-in account's
//  session. The prompts are the Mac's own (`SummaryPrompt`), the reply held
//  to the same schema as on the person's own Anthropic key; the model, its
//  key and the bill are ours. The reply streams back as Anthropic's events
//  and is read exactly as AnthropicAPISummarizer reads its own.
//
//  One task is asked differently (28.11): a dictation corrected by context
//  (`dictationCleanup`) goes without a schema and comes back as plain text,
//  on the server's fast model with thinking off — someone is waiting for
//  their words to be inserted.
//
//  The text leaves the Mac as for every cloud provider: pseudonymized when
//  the person turned that on (`Summarizer.summarizeProtected`). The server
//  passes it to Anthropic and keeps no word of it.
//
//  Signed in without a subscription: the three free summaries, meeting
//  summaries only, through /api/summary with the server's own prompt (as on
//  the iPhone; daisy-api review 27.11: the free three are no open model).
//  Anything else needs the subscription.
//

import Foundation
import os

nonisolated enum DaisySubscriptionError: LocalizedError, Equatable {
    case signedOut
    case trialUsed
    case subscriptionRequired
    case consentNeeded
    case dailyLimit
    case monthlyLimit
    case busy

    var errorDescription: String? {
        switch self {
        case .signedOut:
            String(localized: "You're signed out of Daisy. The transcript is safe; sign in to get the summary")
        case .trialUsed:
            String(localized: "Your three free summaries are used. The transcript is safe; subscribe to Daisy to get the summary")
        case .subscriptionRequired:
            String(localized: "This needs a Daisy Subscription. The free summaries cover meeting summaries only")
        case .consentNeeded:
            String(localized: "Open the Daisy Subscription in Settings and confirm sending text through Daisy's server")
        case .dailyLimit:
            String(localized: "Today's Daisy Subscription allowance is used up. The transcript is safe; try again tomorrow")
        case .monthlyLimit:
            String(localized: "This month's Daisy Subscription allowance is used up. The transcript is safe")
        case .busy:
            String(localized: "Daisy's summary service is busy. The transcript is safe; try again later")
        }
    }

    /// Our server's refusals (src/complete.ts in daisy-api). Nil: not ours to word.
    static func from(status: Int, body: String) -> DaisySubscriptionError? {
        let code = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["error"] as? String
        switch (status, code) {
        case (401, _): return .signedOut
        case (402, "trial_used"): return .trialUsed
        case (402, _): return .subscriptionRequired
        case (429, "daily_limit"): return .dailyLimit
        case (429, "monthly_limit"): return .monthlyLimit
        case (429, _), (503, _): return .busy
        default: return nil
        }
    }
}

nonisolated struct DaisySubscriptionSummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .daisySubscription

    static let endpoint = URL(string: "https://api.mydaisy.io/v1/complete")!
    /// The free summaries (src/handler.ts in daisy-api).
    static let freeEndpoint = URL(string: "https://api.mydaisy.io/api/summary")!
    /// What the server runs (ANTHROPIC_MODEL in daisy-api): decides the
    /// schema and the ceiling as for the person's own Claude key.
    static let serverModel = "claude-sonnet-5"
    static let providerName = "Daisy"

    let urlSession: URLSession
    /// Tests only: a session and a subscription state that bypass the account store.
    let sessionOverride: String?
    let subscribedOverride: Bool?
    /// The account to act for; nil is the app's own (`DaisyAccountStore.shared`).
    let accountStore: DaisyAccountStore?

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "DaisySubscription")

    init(urlSession: URLSession = .shared, sessionOverride: String? = nil, subscribedOverride: Bool? = nil,
         accountStore: DaisyAccountStore? = nil) {
        self.accountStore = accountStore
        self.urlSession = urlSession
        self.sessionOverride = sessionOverride
        self.subscribedOverride = subscribedOverride
    }

    func isReady() async -> Bool { await readiness() == .ready }

    private func store() async -> DaisyAccountStore {
        if let accountStore { return accountStore }
        return await MainActor.run { DaisyAccountStore.shared }
    }

    /// Signed in, and a subscription or a free summary left. No answer
    /// from the server is not «not set up».
    func readiness() async -> SummaryReadiness {
        if sessionOverride != nil { return .ready }
        let store = await store()
        let (signedIn, status, failed) = await MainActor.run { () -> (Bool, DaisySubscriptionStatus?, Bool) in
            (store.isSignedIn && store.hasAcknowledgedCloudDisclosure, store.subscription, store.subscriptionCheckFailed)
        }
        guard signedIn else { return .notReady }
        let fresh = await store.currentSubscription()
        // The check may have found the session over and signed out.
        guard await MainActor.run(body: { store.isSignedIn }) else { return .notReady }
        guard let known = fresh ?? (failed ? nil : status) else {
            return .checkFailed(String(localized: "Daisy's server can't be reached. Try again"))
        }
        return known.active || known.trialRemaining > 0 ? .ready : .notReady
    }

    /// The task's name on the server (COMPLETE_TASKS in src/complete.ts).
    static func taskName(_ task: SummaryTask) -> String {
        switch task {
        case .meeting: "meeting"
        case .preMeetingBrief: "preMeetingBrief"
        case .voiceProfile: "voiceProfile"
        case .dictationPolish: "dictationPolish"
        case .dictationCleanup: "dictationCleanup"
        case .transcriptPolish: "transcriptPolish"
        case .speakerNames: "speakerNames"
        case .catchUp: "catchUp"
        case .morningBrief: "morningBrief"
        case .voiceCommand: "voiceCommand"
        case .templatedSummary: "templatedSummary"
        case .templateStructure: "templateStructure"
        }
    }

    /// The answer's ceiling. It is also what the server reserves against
    /// the account's day before the request runs, so a short job asks for
    /// little: a polish writes back about what it read, plus thinking.
    static func maxTokens(for task: SummaryTask, userChars: Int) -> Int {
        let ceiling = AnthropicAPISummarizer.maxOutputTokens(for: serverModel)
        switch task {
        // No thinking there, and the server's own cap for the task is 2,048.
        case .dictationCleanup: return DictationCleanup.maxTokens(userChars: userChars)
        case .dictationPolish, .voiceCommand: return min(ceiling, userChars + 4_000)
        case .transcriptPolish: return min(ceiling, userChars + 8_000)
        case .speakerNames: return 4_000
        default: return ceiling
        }
    }

    func summarize(
        transcript: String,
        title: String,
        localeHint: String?,
        task: SummaryTask
    ) async throws -> MeetingSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // A dictation to correct is often one short phrase; its own floor
        // is `DictationCleanup.minChars`, and the server has none for it.
        let cleanup = task.isDictationCleanup
        guard cleanup || trimmed.count > 40 else { throw SummaryProviderError.transcriptTooShort }
        let store = await store()
        let session: String? = if let sessionOverride { sessionOverride } else {
            await MainActor.run { store.sessionToken }
        }
        guard let session else { throw DaisySubscriptionError.signedOut }
        // Nothing goes to our server without the yes given before signing in.
        if sessionOverride == nil {
            guard await MainActor.run(body: { store.hasAcknowledgedCloudDisclosure }) else {
                throw DaisySubscriptionError.consentNeeded
            }
        }

        // The free path only when the status is known and not active: a
        // subscriber whose status couldn't be read goes to /v1/complete, and
        // its 402 sends a meeting to the free path if it really has to.
        let subscribed: Bool?
        if let subscribedOverride {
            subscribed = subscribedOverride
        } else if cleanup {
            // The status as it was last read, never a request for it: the
            // cleanup has 2.5 s in all, and a status read alone can take
            // that. Only a subscription known to be active sends. A
            // session given from outside (the bench) is not the store's,
            // whose status says nothing about it: the server judges.
            if sessionOverride != nil {
                subscribed = true
            } else {
                subscribed = await MainActor.run { store.subscription?.active } ?? false
            }
        } else {
            subscribed = await store.currentSubscription()?.active
        }
        if cleanup, subscribed != true {
            // No free cleanup: the three free summaries are meetings'.
            throw DaisySubscriptionError.subscriptionRequired
        }
        if subscribed == false {
            return try await freeSummary(task: task, transcript: trimmed, title: title, localeHint: localeHint,
                                         session: session, store: store)
        }

        let system = SummaryPrompt.systemInstructions(localeHint: localeHint, task: task, plainText: cleanup)
        let user = SummaryPrompt.userPrompt(title: title, transcript: trimmed, task: task)
        let schemaPlaceholder = "daisy-reply-schema-\(UUID().uuidString)"
        var body: [String: Any] = [
            "task": Self.taskName(task),
            "system": system,
            "user": user,
            "maxTokens": Self.maxTokens(for: task, userChars: user.count),
        ]
        // The cleanup's answer is the text itself: the server refuses a
        // schema sent with it.
        if !cleanup { body["schema"] = schemaPlaceholder }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = CloudStreaming.idleTimeout
        // The schema goes in as its own text, as for the Anthropic key
        // (`constrainedReplyJSON` says why its order matters).
        let replySchema = MeetingSummaryJSONSchema.constrainedReplyJSON(includesTitle: task.asksForTitle)
        request.httpBody = Data(String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
            .replacingOccurrences(of: "\"\(schemaPlaceholder)\"", with: replySchema).utf8)

        let bytes: URLSession.AsyncBytes
        do {
            // The cleanup has 2.5 s in all (`DictationCleanup.deadline`):
            // a retry's wait alone is longer.
            bytes = try await openRetrying(request, attempts: cleanup ? 1 : Self.maxAttempts)
        } catch SummaryProviderError.httpError(_, let status, let body) {
            if let ours = DaisySubscriptionError.from(status: status, body: body) {
                // A session handed in from outside (a test, the bench) is
                // not the store's: the server refusing IT says nothing
                // about the account signed in on this Mac, which must not
                // be signed out for it.
                if ours == .signedOut, sessionOverride == nil { await MainActor.run { store.signOut() } }
                if ours == .subscriptionRequired, cleanup {
                    // The status read was wrong: read again for the next
                    // dictation, without this one waiting for it.
                    if sessionOverride == nil { Task { await store.refreshSubscription() } }
                    throw ours
                }
                if ours == .subscriptionRequired {
                    // The subscription ended since the status was read: the
                    // free summaries, if any are left, for a meeting.
                    await store.refreshSubscription()
                    if case .meeting = task {
                        return try await freeSummary(task: task, transcript: trimmed, title: title, localeHint: localeHint,
                                                     session: session, store: store)
                    }
                }
                throw ours
            }
            throw SummaryProviderError.httpError(provider: Self.providerName, status: status, body: "")
        }

        var stream = AnthropicStreamAccumulator()
        do {
            try await CloudStreaming.forEachData(in: bytes) { stream.consume($0) }
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if (error as? URLError)?.code == .timedOut {
                throw CloudStreaming.timeoutWorded(error, provider: Self.providerName, request: request, midAnswer: true)
            }
            throw SummaryProviderError.streamInterrupted(provider: Self.providerName, message: error.localizedDescription)
        }
        if let message = stream.streamError {
            log.error("Daisy stream error event: \(message, privacy: .public)")
            throw SummaryProviderError.streamInterrupted(provider: Self.providerName, message: message)
        }
        // No stop reason: the stream ended before Anthropic finished — the
        // server's time ran out, or the connection broke. Not a summary.
        guard stream.stopReason != nil else {
            throw SummaryProviderError.streamInterrupted(provider: Self.providerName,
                                                         message: String(localized: "The answer was cut off"))
        }
        if cleanup {
            // Only a reply the model finished by itself is the text: one
            // cut at the ceiling or a refusal comes back as HTTP 200 too.
            try DictationCleanup.requireFinished(stopReason: stream.stopReason, provider: Self.providerName)
            return MeetingSummary(summary: "", sections: [], actionItems: [], clientFollowUp: stream.text)
        }
        switch stream.stopReason {
        case "max_tokens": throw SummaryProviderError.outputTruncated(provider: Self.providerName)
        case "refusal": throw SummaryProviderError.refused(provider: Self.providerName)
        default: break
        }
        let text = stream.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log.error("Daisy reply had no text block (types: \(stream.blockTypes.joined(separator: ","), privacy: .public))")
            throw SummaryProviderError.invalidResponse(provider: Self.providerName)
        }
        return try Self.decode(text)
    }

    /// Retries what costs nothing and may pass in a second: a connection
    /// that never opened, and Anthropic overloaded or unreachable (the
    /// server gave the reservation back). Never our own refusals — a limit,
    /// no subscription, the subscribers' day — which don't change in a
    /// second and would be counted again.
    static let maxAttempts = 3

    private func openRetrying(_ request: URLRequest, attempts: Int = maxAttempts) async throws -> URLSession.AsyncBytes {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await CloudStreaming.open(request, session: urlSession, provider: Self.providerName, log: log,
                                                     maxAttempts: 1)
            } catch SummaryProviderError.httpError(let provider, let status, let body) {
                guard attempt < attempts, Self.isRetryable(status: status, body: body) else {
                    throw SummaryProviderError.httpError(provider: provider, status: status, body: body)
                }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                guard attempt < attempts, CloudHTTPRetry.isTransient(error),
                      (error as? URLError)?.code != .timedOut else { throw error }
            }
            log.warning("Daisy: retry \(attempt, privacy: .public)/\(attempts, privacy: .public)")
            try await Task.sleep(for: .seconds(CloudHTTPRetry.backoff(attempt)))
        }
    }

    static func isRetryable(status: Int, body: String) -> Bool {
        let code = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["error"] as? String
        switch code {
        case "provider_busy", "provider_unreachable": return true
        case nil: return status >= 500
        default: return false
        }
    }

    private static func decode(_ text: String) throws -> MeetingSummary {
        do {
            return try CloudSummaryDTO.decode(from: text).toMeetingSummary()
        } catch {
            throw SummaryProviderError.parseFailed(provider: providerName, message: error.localizedDescription)
        }
    }

    /// One of the three free summaries: POST /api/summary with the session,
    /// the server's prompt, `{text, trialRemaining}` back. A plain meeting
    /// summary only: the server's prompt drafts no follow-up on request, so
    /// «Draft follow-up» would spend a free summary for nothing.
    private func freeSummary(task: SummaryTask, transcript: String, title: String, localeHint: String?,
                             session: String, store: DaisyAccountStore) async throws -> MeetingSummary {
        guard case .meeting(let forceFollowUp, let oneVoice) = task, !forceFollowUp else {
            throw DaisySubscriptionError.subscriptionRequired
        }
        var body: [String: Any] = ["title": title, "transcript": transcript, "singleVoice": oneVoice, "sessionToken": session]
        if let localeHint { body["localeHint"] = localeHint }
        var request = URLRequest(url: Self.freeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw SummaryProviderError.httpError(provider: Self.providerName, status: 0, body: "")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let left = json?["trialRemaining"] as? Int {
            await MainActor.run { store.noteTrialRemaining(left) }
        }
        guard status == 200 else {
            let code = json?["error"] as? String
            if status == 400, code == "transcript_too_short" { throw SummaryProviderError.transcriptTooShort }
            if status == 401 {
                if sessionOverride == nil { await MainActor.run { store.signOut() } }
                throw DaisySubscriptionError.signedOut
            }
            if status == 402 { throw DaisySubscriptionError.trialUsed }
            if status == 429 || status == 503 { throw DaisySubscriptionError.busy }
            throw SummaryProviderError.httpError(provider: Self.providerName, status: status, body: "")
        }
        guard let text = json?["text"] as? String else {
            throw SummaryProviderError.invalidResponse(provider: Self.providerName)
        }
        return try Self.decode(text)
    }
}
