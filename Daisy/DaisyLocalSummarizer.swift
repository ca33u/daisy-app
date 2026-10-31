//
//  DaisyLocalSummarizer.swift
//  Daisy
//
//  «Локальная модель Daisy» as a summary provider (plan 2026-10-28, Л-3):
//  the same prompts as every provider (`SummaryPrompt`), sent to the
//  DaisyLLM helper on this Mac, the answer constrained to the two-level
//  summary schema and decoded like any other (`CloudSummaryDTO`). Nothing
//  leaves the Mac. Opt-in, never the default (Egor, 28.10).
//
//  Background work only: meetings, notes, imports and what is built from
//  them. The Daisy key's commands and the selection rewrite go to the
//  interactive provider instead (`SummaryRoute.interactive`) — a 4B model
//  reading a prompt for 10+ seconds isn't interactive — once the person
//  has one recorded; the quick passes with second-long deadlines are
//  skipped (`Summarizer.runsQuickPasses`).
//
//  On a Mac with 16 GB or less it doesn't start while a recording is live:
//  Whisper and the 4–7 GB model together are what macOS kills first, and
//  the summary can wait for the meeting to end.
//

import DaisyLLMKit
import Foundation
import os

nonisolated struct DaisyLocalSummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .daisyLocal

    private let client: DaisyLLMClient
    private let modelFolder: URL?
    private let isInstalled: @Sendable () -> Bool
    private let physicalMemory: UInt64
    private let recordingIsLive: @Sendable () async -> Bool
    private let liveCheckInterval: Duration
    private let recordSpend: @Sendable (SummaryProviderKind, String, TokenSpend) -> Void
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "DaisyLocalSummarizer")
    static var providerName: String { SummaryProviderKind.daisyLocal.shortName }

    init(
        client: DaisyLLMClient = .shared,
        modelFolder: URL? = LocalSummaryModel.directory,
        isInstalled: @escaping @Sendable () -> Bool = { LocalSummaryModel.isInstalled },
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        recordingIsLive: @escaping @Sendable () async -> Bool = { await MainActor.run { RecordingSession.isRecordingLive } },
        liveCheckInterval: Duration = .seconds(5),
        recordSpend: @escaping @Sendable (SummaryProviderKind, String, TokenSpend) -> Void = {
            TokenLedgerSink.record(provider: $0, model: $1, spend: $2)
        }
    ) {
        self.client = client
        self.modelFolder = modelFolder
        self.isInstalled = isInstalled
        self.physicalMemory = physicalMemory
        self.recordingIsLive = recordingIsLive
        self.liveCheckInterval = liveCheckInterval
        self.recordSpend = recordSpend
    }

    func isReady() async -> Bool {
        DaisyLLMClient.runsOnThisMac && isInstalled()
    }

    /// Why it isn't ready, in words.
    static func unavailableReason() -> String {
        if !DaisyLLMClient.runsOnThisMac { return DaisyLLMFailure.unsupportedHardware.localizedDescription }
        return DaisyLLMFailure.modelNotFound(path: "").localizedDescription
    }

    func summarize(
        transcript: String,
        title: String,
        localeHint: String?,
        task: SummaryTask
    ) async throws -> MeetingSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else { throw SummaryProviderError.transcriptTooShort }
        guard DaisyLLMClient.runsOnThisMac, isInstalled(), let modelFolder else {
            throw SummaryProviderError.modelUnavailable(
                provider: Self.providerName, reason: Self.unavailableReason())
        }
        let system = SummaryPrompt.systemInstructions(localeHint: localeHint, task: task)
        let user = SummaryPrompt.userPrompt(title: title, transcript: trimmed, task: task)

        if Self.waitsForLiveRecordings(physicalMemory: physicalMemory) {
            var logged = false
            while await recordingIsLive() {
                if !logged {
                    Self.log.info("A recording is live on a ≤16 GB Mac — the local summary waits for it to end")
                    logged = true
                }
                try await Task.sleep(for: liveCheckInterval)
            }
        }

        let promptChars = system.count + user.count
        let request = DaisyLLMRequest(
            modelDirectory: modelFolder.path, systemPrompt: system, userPrompt: user,
            language: localeHint, jsonSchema: MeetingSummaryJSONSchema.localModelJSON,
            limits: Self.limits(physicalMemory: physicalMemory))
        let response: DaisyLLMResponse
        do {
            response = try await client.generate(request, timeout: Self.timeout(promptChars: promptChars))
        } catch let failure as DaisyLLMFailure {
            switch failure {
            case .timedOut(let seconds):
                throw SummaryProviderError.timedOut(provider: Self.providerName, seconds: seconds, midAnswer: false)
            case .outputIncomplete:
                throw SummaryProviderError.outputTruncated(provider: Self.providerName)
            case .engine(let detail):
                Self.log.error("Local model failed: \(detail, privacy: .public)")
                throw SummaryProviderError.modelUnavailable(provider: Self.providerName, reason: failure.localizedDescription)
            default:
                throw SummaryProviderError.modelUnavailable(provider: Self.providerName, reason: failure.localizedDescription)
            }
        }
        Self.log.info("""
            Local summary: prompt \(response.promptTokens) tokens in \(response.promptSeconds, format: .fixed(precision: 1)) s, \
            answer \(response.outputTokens) in \(response.generateSeconds, format: .fixed(precision: 1)) s
            """)
        var spend = TokenSpend()
        spend.inputTokens = response.promptTokens
        spend.outputTokens = response.outputTokens
        recordSpend(.daisyLocal, LocalSummaryModel.displayName, spend)
        do {
            return try CloudSummaryDTO.decode(from: response.text).toMeetingSummary()
        } catch {
            throw SummaryProviderError.parseFailed(provider: Self.providerName, message: error.localizedDescription)
        }
    }

    /// ≤ 16 GB: the model doesn't run beside live transcription.
    static func waitsForLiveRecordings(physicalMemory: UInt64) -> Bool {
        physicalMemory <= 16 << 30
    }

    /// What this Mac's memory allows. Qwen 3.5 4B peaked at 3.8 / 5.0 /
    /// 6.0 / 6.8 GB for 1.7k / 12k / 23k / 32k prompt tokens (spike, 28.10).
    /// 8 GB: shorter chunks and up to ~45 minutes of Russian speech until
    /// Л-0 measures a real 8 GB Mac; 16 GB: up to ~2 hours; more: no cap.
    static func limits(physicalMemory: UInt64) -> DaisyLLMLimits {
        if physicalMemory <= 8 << 30 {
            return DaisyLLMLimits(maxOutputTokens: 4096, maxPromptTokens: 16_000, prefillStepSize: 512)
        }
        if physicalMemory <= 16 << 30 {
            return DaisyLLMLimits(maxOutputTokens: 4096, maxPromptTokens: 48_000, prefillStepSize: 1024)
        }
        return DaisyLLMLimits(maxOutputTokens: 4096)
    }

    /// The whole call's limit: five minutes plus a second per 25 prompt
    /// tokens, at most 45 minutes. The slowest run measured — 32k tokens
    /// under heavy load — took 14 minutes; this gives it 26.
    static func timeout(promptChars: Int) -> Duration {
        let tokens = LocalContextGuard.estimatedTokens(promptChars: promptChars)
        return .seconds(min(45 * 60, 300 + tokens / 25))
    }
}
