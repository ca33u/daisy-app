//
//  DaisyLocalSummarizerTests.swift
//  DaisyTests
//
//  «Локальная модель Daisy» as a summary provider, Л-3: what it sends the
//  helper (the two-level schema, the language, this Mac's limits), what it
//  makes of the answer, its errors in words, waiting out a live recording
//  on a ≤16 GB Mac, the ledger, and which tasks go where. The helper is an
//  anonymous listener in this process with a scripted model; nothing here
//  writes the real prefs (Summarizer.shared is only read).
//

import DaisyLLMKit
import Foundation
import Testing
@testable import Daisy

/// The model's side: answers with `reply` (or throws `failure`) and keeps
/// every request it got.
private final class Model: DaisyLLMBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [DaisyLLMRequest] = []
    let reply: String
    let failure: DaisyLLMFailure?

    init(reply: String = Model.answer, failure: DaisyLLMFailure? = nil) {
        self.reply = reply
        self.failure = failure
    }

    var requests: [DaisyLLMRequest] { lock.withLock { _requests } }

    static let answer = #"{"title":"План запуска","summary":"Обсудили запуск.","sections":[{"title":"Сроки","bullets":[{"text":"Релиз в пятницу","children":[{"text":"после QA"}]}]}],"actionItems":["Анна: собрать сборку"],"clientFollowUp":""}"#

    func run(_ request: DaisyLLMRequest, progress: @escaping @Sendable (DaisyLLMProgress.Stage) -> Void) async throws -> DaisyLLMResponse {
        lock.withLock { _requests.append(request) }
        if let failure { throw failure }
        return DaisyLLMResponse(
            id: request.id, text: reply, promptTokens: 12_300, outputTokens: 640,
            loadSeconds: 2, promptSeconds: 80, generateSeconds: 30, peakMemoryBytes: 5_000_000_000,
            language: request.language)
    }
}

/// A helper in this process and a provider pointed at it.
private final class Rig: @unchecked Sendable {
    let model: Model
    let service: DaisyLLMService
    let listener = NSXPCListener.anonymous()
    let client: DaisyLLMClient

    init(_ model: Model = Model()) {
        self.model = model
        service = DaisyLLMService(backend: model, onIdle: {}, onStuck: {})
        listener.delegate = service
        listener.resume()
        nonisolated(unsafe) let endpoint = listener.endpoint
        client = DaisyLLMClient(
            makeConnection: { NSXPCConnection(listenerEndpoint: endpoint) },
            peerRequirement: DaisyLLMCodeSigning.requirement(forIdentifier: DaisyLLMCodeSigning.appIdentifier))
    }

    /// Spend goes here, never to the real ledger (which writes the prefs)
    /// nor through `TokenLedgerSink.testRecorder`, which another suite owns.
    let spend = Spend()

    func provider(
        installed: Bool = true,
        memory: UInt64 = 32 << 30,
        recordingIsLive: @escaping @Sendable () async -> Bool = { false }
    ) -> DaisyLocalSummarizer {
        let spend = spend
        return DaisyLocalSummarizer(
            client: client, modelFolder: URL(fileURLWithPath: "/models/qwen"), isInstalled: { installed },
            physicalMemory: memory, recordingIsLive: recordingIsLive, liveCheckInterval: .milliseconds(20),
            recordSpend: { spend.add($0, $1, $2) })
    }

    func close() {
        client.invalidate()
        listener.invalidate()
    }
}

private let transcript = String(repeating: "Анна: релиз в пятницу, после QA. Борис: согласен. ", count: 8)

private final class Spend: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(SummaryProviderKind, String, TokenSpend)] = []
    func add(_ kind: SummaryProviderKind, _ model: String, _ spend: TokenSpend) { lock.withLock { list.append((kind, model, spend)) } }
    var entries: [(SummaryProviderKind, String, TokenSpend)] { lock.withLock { list } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

@Suite(.enabled(if: DaisyLLMClient.runsOnThisMac), .timeLimit(.minutes(1)), .serialized)
struct DaisyLocalSummarizerTests {
    @Test func itAsksTheHelperForTheTwoLevelShapeInTheMeetingsLanguage() async throws {
        let rig = Rig()
        defer { rig.close() }

        let summary = try await rig.provider().summarize(
            transcript: transcript, title: "Созвон", localeHint: "ru", task: .standard)

        let request = try #require(rig.model.requests.first)
        #expect(request.jsonSchema == MeetingSummaryJSONSchema.localModelJSON)
        #expect(request.language == "ru")
        #expect(request.modelDirectory == "/models/qwen")
        #expect(request.systemPrompt == SummaryPrompt.systemInstructions(localeHint: "ru", task: .standard))
        #expect(request.userPrompt.contains("Анна: релиз в пятницу"))
        #expect(summary.title == "План запуска")
        #expect(summary.sections.first?.bullets.first?.children.first?.text == "после QA")
        #expect(summary.actionItems == ["Анна: собрать сборку"])
    }

    @Test func itsTokensGoToTheLedgerAtNoCost() async throws {
        let rig = Rig()
        defer { rig.close() }

        _ = try await rig.provider().summarize(transcript: transcript, title: "T", localeHint: "ru", task: .standard)

        let entry = try #require(rig.spend.entries.first)
        #expect(entry.0 == .daisyLocal)
        #expect(entry.1 == LocalSummaryModel.displayName)
        #expect(entry.2.inputTokens == 12_300)
        #expect(entry.2.outputTokens == 640)
        #expect(!TokenLedger.isBilled(.daisyLocal))
    }

    @Test func withoutTheModelItSaysSoAndSendsNothing() async throws {
        let rig = Rig()
        defer { rig.close() }
        let provider = rig.provider(installed: false)
        #expect(await !provider.isReady())
        do {
            _ = try await provider.summarize(transcript: transcript, title: "T", localeHint: "ru", task: .standard)
            Issue.record("summarized without a model")
        } catch SummaryProviderError.modelUnavailable(_, let reason) {
            #expect(reason == "The Daisy local model isn’t on this Mac yet.")
        }
        #expect(rig.model.requests.isEmpty)
    }

    @Test func theHelpersFailuresArriveInWords() async throws {
        let rig = Rig(Model(failure: .promptTooLong(tokens: 60_000, limit: 48_000)))
        defer { rig.close() }
        do {
            _ = try await rig.provider().summarize(transcript: transcript, title: "T", localeHint: "ru", task: .standard)
            Issue.record("a refused prompt became a summary")
        } catch SummaryProviderError.modelUnavailable(let provider, let reason) {
            #expect(provider == DaisyLocalSummarizer.providerName)
            #expect(reason == "This meeting is too long for the local model on this Mac. Choose another provider for it.")
        }
    }

    @Test func anAnswerThatIsntASummaryIsAParseFailure() async throws {
        let rig = Rig(Model(reply: "not json"))
        defer { rig.close() }
        await #expect(throws: SummaryProviderError.self) {
            try await rig.provider().summarize(transcript: transcript, title: "T", localeHint: "ru", task: .standard)
        }
    }

    @Test func onSixteenGigabytesItWaitsForALiveRecordingToEnd() async throws {
        let rig = Rig()
        defer { rig.close() }
        let checks = Counter()
        // Live for the first three looks, then the meeting ends.
        let provider = rig.provider(memory: 16 << 30, recordingIsLive: { checks.next() <= 3 })

        _ = try await provider.summarize(transcript: transcript, title: "T", localeHint: "ru", task: .standard)

        #expect(checks.count == 4)
        #expect(rig.model.requests.count == 1)
    }

    @Test func withMoreMemoryItDoesntWait() async throws {
        let rig = Rig()
        defer { rig.close() }
        let checks = Counter()
        let provider = rig.provider(memory: 32 << 30, recordingIsLive: { _ = checks.next(); return true })
        _ = try await provider.summarize(transcript: transcript, title: "T", localeHint: "ru", task: .standard)
        #expect(checks.count == 0)
    }

    @Test func aWaitThatIsCancelledEndsAsACancel() async throws {
        let rig = Rig()
        defer { rig.close() }
        let provider = rig.provider(memory: 8 << 30, recordingIsLive: { true })
        let task = Task { try await provider.summarize(transcript: transcript, title: "T", localeHint: "ru", task: .standard) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(rig.model.requests.isEmpty)
    }

    @Test func limitsFollowThisMacsMemory() {
        let eight = DaisyLocalSummarizer.limits(physicalMemory: 8 << 30)
        #expect(eight.prefillStepSize == 512)
        #expect(eight.maxPromptTokens == 16_000)
        let sixteen = DaisyLocalSummarizer.limits(physicalMemory: 16 << 30)
        #expect(sixteen.maxPromptTokens == 48_000)
        let more = DaisyLocalSummarizer.limits(physicalMemory: 32 << 30)
        #expect(more.maxPromptTokens == nil)
        #expect(more.prefillStepSize == nil)
        #expect([eight, sixteen, more].allSatisfy { $0.maxOutputTokens == 4096 })
        #expect(DaisyLocalSummarizer.waitsForLiveRecordings(physicalMemory: 16 << 30))
        #expect(!DaisyLocalSummarizer.waitsForLiveRecordings(physicalMemory: 24 << 30))
    }

    @Test func aLongMeetingGetsMoreTimeUpToACeiling() {
        let short = DaisyLocalSummarizer.timeout(promptChars: 6_000)
        let hour = DaisyLocalSummarizer.timeout(promptChars: 64_000)
        #expect(short >= .seconds(300))
        #expect(hour > short)
        #expect(DaisyLocalSummarizer.timeout(promptChars: 10_000_000) == .seconds(45 * 60))
    }

    // MARK: Which tasks go where

    @Test func onlyTheInteractiveRouteLeavesTheLocalModel() {
        #expect(Summarizer.provider(for: .main, chosen: .daisyLocal, interactiveFallback: .anthropic) == .daisyLocal)
        #expect(Summarizer.provider(for: .interactive, chosen: .daisyLocal, interactiveFallback: .anthropic) == .anthropic)
        // With any other provider chosen, both routes are that provider.
        #expect(Summarizer.provider(for: .interactive, chosen: .ollama, interactiveFallback: .anthropic) == .ollama)
        #expect(Summarizer.provider(for: .main, chosen: .gemini, interactiveFallback: .anthropic) == .gemini)
        // A fallback that is somehow the local model itself stays local.
        #expect(Summarizer.provider(for: .interactive, chosen: .daisyLocal, interactiveFallback: .daisyLocal) == .daisyLocal)
        // Nothing recorded (the hidden default set from outside): the
        // interactive route stays on this Mac, never a provider not chosen.
        #expect(Summarizer.provider(for: .interactive, chosen: .daisyLocal, interactiveFallback: nil) == .daisyLocal)
    }

    @Test func aTimeoutAndACutOffAnswerKeepTheirOwnKinds() async throws {
        let slow = Rig(Model(failure: .timedOut(seconds: 1500)))
        defer { slow.close() }
        do {
            _ = try await slow.provider().summarize(transcript: transcript, title: "T", localeHint: "ru", task: .standard)
            Issue.record("a timeout became a summary")
        } catch SummaryProviderError.timedOut(_, let seconds, _) {
            #expect(seconds == 1500)
        }
        let cut = Rig(Model(failure: .outputIncomplete(tokens: 4096)))
        defer { cut.close() }
        do {
            _ = try await cut.provider().summarize(transcript: transcript, title: "T", localeHint: "ru", task: .standard)
            Issue.record("a cut-off answer became a summary")
        } catch SummaryProviderError.outputTruncated {
        }
    }

    @MainActor
    @Test func theLocalModelCountsAsLocalForEveryPrivacyGate() {
        #expect(Summarizer.shared.isEffectivelyLocal(.daisyLocal))
        #expect(SummaryProviderKind.daisyLocal.isLocal)
        #expect(!SummaryProviderKind.daisyLocal.requiresAPIKey)
        #expect(SummaryProviderKind.daisyLocal.privacyTag == "On this Mac — nothing is sent anywhere.")
        #expect(SummaryProviderKind.daisyLocal.displayName == "Daisy local model")
        #expect(ImprovementStats.publishedNames.contains("summary.daisy_local"))
    }
}
