//
//  DaisyTests.swift
//  DaisyTests
//
//  Pure-function smoke suite. Locks in the highest-bug-yield logic
//  surfaces the pre-1.0.3 audit recommended. No async, no UI, no
//  network — each test is a few-millisecond pure unit assertion.
//

import Testing
import Foundation
import AVFoundation
import AppKit
import Carbon.HIToolbox
@testable import Daisy

@Suite("Smoke suite (pure-function regression locks)")
struct DaisyTests {

    // MARK: - Token cost estimate

    @Test("Claude estimate includes cache and web-search pricing")
    func tokenCostEstimate_anthropicIncludesAllBillableUnits() {
        let estimate = TokenCostEstimator.estimate(
            provider: .anthropic,
            model: "claude-sonnet-4-6",
            spend: TokenSpend(
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                cachedInputTokens: 1_000_000,
                cacheWriteTokens: 1_000_000,
                webSearches: 2
            )
        )
        #expect(estimate.hasPricedUsage)
        #expect(!estimate.hasUnpricedBilledUsage)
        #expect(abs(estimate.usd - 22.07) < 0.000_001)
    }

    @Test("Sonnet 5 kept $2/$10; the 5.5 generation is priced on its own")
    func tokenCostEstimate_claude5Generations() {
        // The increase planned for 2026-09-01 never came, and the 5.5 /
        // 5.1 ids must not fall through to their older siblings' prefix
        // (`claude-opus-5` is a prefix of `claude-opus-5-5`).
        let spend = TokenSpend(inputTokens: 1_000_000, outputTokens: 1_000_000)
        func usd(_ model: String) -> Double {
            TokenCostEstimator.estimate(provider: .anthropic, model: model, spend: spend, on: "2026-10-08").usd
        }
        #expect(abs(usd("claude-sonnet-5") - 12.0) < 0.000_001)    // $2 + $10
        #expect(abs(usd("claude-sonnet-5-5") - 12.0) < 0.000_001)  // $2 + $10
        #expect(abs(usd("claude-opus-5-5") - 24.0) < 0.000_001)    // $4 + $20
        #expect(abs(usd("claude-opus-5") - 30.0) < 0.000_001)      // $5 + $25
        #expect(abs(usd("claude-fable-5-1") - 60.0) < 0.000_001)   // $10 + $50
        #expect(abs(usd("claude-haiku-5-5") - 0.60) < 0.000_001)   // $0.10 + $0.50
    }

    // MARK: - The token card's window

    @Test("The token window is 28 days ending today, oldest first")
    func tokenLedger_windowDayKeysCoverTheWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let end = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let keys = TokenLedger.windowDayKeys(endingAt: end)

        #expect(keys.count == TokenLedger.windowDays)
        // Today is IN the window — a card that excluded it would show
        // nothing for the summary that was just written.
        #expect(keys.last == "2026-08-01")
        // 28 days back from 1 August is 5 July, and the list runs
        // forwards from it: the chart draws in this order.
        #expect(keys.first == "2026-07-05")
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
        // The window has to fit inside what the ledger keeps, or the
        // oldest bars would be silently empty.
        #expect(TokenLedger.windowDays <= TokenLedger.retentionDays)
    }

    @Test("Token chart uses calendar-aware resolution without dropping days")
    func tokenLedger_dashboardChartBucketsMatchPeriod() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = .current
        let end = calendar.date(from: DateComponents(year: 2026, month: 8, day: 16))!

        let expectations: [(DashboardPeriod, TokenChartInterval)] = [
            (.sevenDays, .day),
            (.thirtyDays, .day),
            (.ninetyDays, .week),
            (.year, .month),
        ]

        for (period, interval) in expectations {
            #expect(period.tokenChartInterval == interval)
            let keys = period.dayKeys(endingAt: end, calendar: calendar)
            let buckets = TokenLedger.chartBuckets(
                dayKeys: keys,
                interval: interval,
                calendar: calendar
            )
            let flattened = buckets.flatMap(\.dayKeys)
            #expect(flattened == keys)
            #expect(Set(flattened).count == keys.count)

            switch period {
            case .sevenDays:
                #expect(buckets.count == 7)
            case .thirtyDays:
                #expect(buckets.count == 30)
            case .ninetyDays:
                #expect((13...14).contains(buckets.count))
            case .year:
                // A rolling 365-day window normally touches 13 calendar
                // months because both edge months are partial.
                #expect(buckets.count == 13)
            }
        }
    }

    @Test("Claude Opus 5 is priced at its 2026 list rates")
    func tokenCostEstimate_anthropicOpus5() {
        let estimate = TokenCostEstimator.estimate(
            provider: .anthropic,
            model: "claude-opus-5",
            spend: TokenSpend(
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                cachedInputTokens: 1_000_000,
                cacheWriteTokens: 1_000_000,
                webSearches: 2
            )
        )
        // $5 + $25 + $0.50 + $6.25 + 2 × $0.01
        #expect(estimate.hasPricedUsage)
        #expect(abs(estimate.usd - 36.77) < 0.000_001)
    }

    @Test("GPT-5.6 Terra is priced at its October 2026 list rates")
    func tokenCostEstimate_openAITerra() {
        let estimate = TokenCostEstimator.estimate(
            provider: .openai,
            model: "gpt-5.6-terra",
            spend: TokenSpend(
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                cachedInputTokens: 1_000_000
            )
        )
        // $2 + $12 + $0.20. No cache writes in this spend (they're
        // priced separately, see the cache-write test).
        #expect(estimate.hasPricedUsage)
        #expect(abs(estimate.usd - 14.20) < 0.000_001)
    }

    @Test("OpenAI's cache write is priced on its own, at 1.25x input")
    func tokenCostEstimate_openAICacheWrite() {
        // gpt-6.1-sol's usage on a two-hour transcript (2026-10-10).
        let spend = TokenSpend.openAICompatible(from: ["usage": [
            "prompt_tokens": 35_866,
            "completion_tokens": 272,
            "prompt_tokens_details": ["cached_tokens": 0, "cache_write_tokens": 35_863],
        ]])
        #expect(spend.inputTokens == 3)
        #expect(spend.cacheWriteTokens == 35_863)
        let usd = TokenCostEstimator.estimate(provider: .openai, model: "gpt-6.1-sol", spend: spend).usd
        // 3 × $2 + 35 863 × $2.50 + 272 × $10, per million.
        #expect(abs(usd - (3 * 2 + 35_863 * 2.5 + 272 * 10) / 1_000_000) < 0.000_001)
    }

    @Test("Every model Settings offers has a price")
    func tokenCostEstimate_shippedModelsAreAllPriced() {
        let spend = TokenSpend(inputTokens: 1_000, outputTokens: 1_000)
        for model in AnthropicAPISummarizer.availableModels.map(\.id) {
            let estimate = TokenCostEstimator.estimate(provider: .anthropic, model: model, spend: spend)
            #expect(estimate.hasPricedUsage, "unpriced Anthropic model: \(model)")
        }
        for model in OpenAIAPISummarizer.availableModels.map(\.id) {
            let estimate = TokenCostEstimator.estimate(provider: .openai, model: model, spend: spend)
            #expect(estimate.hasPricedUsage, "unpriced OpenAI model: \(model)")
        }
        for model in KimiAPISummarizer.availableModels.map(\.id) {
            let estimate = TokenCostEstimator.estimate(provider: .kimi, model: model, spend: spend)
            #expect(estimate.hasPricedUsage, "unpriced Kimi model: \(model)")
        }
        for model in GeminiAPISummarizer.availableModels.map(\.id) {
            let estimate = TokenCostEstimator.estimate(provider: .gemini, model: model, spend: spend)
            #expect(estimate.hasPricedUsage, "unpriced Gemini model: \(model)")
        }
    }

    @Test("Saved Claude models move to their same-tier successors, once")
    func summaryModelMigrationChains() throws {
        let suite = "daisy.tests.modelMigration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("claude-sonnet-4-6", forKey: "daisy.anthropicModel")
        UserDefaultsMigration.migrateSummaryModels(defaults: defaults)
        // 4.6 → 5 (2026-07) → 5.5 (2026-10) in the same launch.
        #expect(defaults.string(forKey: "daisy.anthropicModel") == "claude-sonnet-5-5")

        // Each mapping runs once: a later pick of an older model stays.
        defaults.set("claude-opus-5", forKey: "daisy.anthropicModel")
        UserDefaultsMigration.migrateSummaryModels(defaults: defaults)
        #expect(defaults.string(forKey: "daisy.anthropicModel") == "claude-opus-5")

        for (from, to) in [("claude-opus-5", "claude-opus-5-5"), ("claude-fable-5", "claude-fable-5-1"),
                           ("claude-haiku-4-5-20251001", "claude-haiku-4-5-20251001"), ("my-own-id", "my-own-id")] {
            let fresh = "daisy.tests.modelMigration.\(UUID().uuidString)"
            let other = try #require(UserDefaults(suiteName: fresh))
            defer { other.removePersistentDomain(forName: fresh) }
            other.set(from, forKey: "daisy.anthropicModel")
            UserDefaultsMigration.migrateSummaryModels(defaults: other)
            #expect(other.string(forKey: "daisy.anthropicModel") == to, "\(from)")
        }
    }

    @Test("GPT-5 generation gets the newer Chat Completions parameters")
    func openAIParameterDialect() {
        #expect(OpenAIAPISummarizer.usesGPT5ParameterSet("gpt-5.6-terra"))
        #expect(OpenAIAPISummarizer.usesGPT5ParameterSet("gpt-5.6-sol"))
        #expect(OpenAIAPISummarizer.usesGPT5ParameterSet("o3-mini"))
        #expect(OpenAIAPISummarizer.usesGPT5ParameterSet("gpt-6.1-sol"))
        #expect(OpenAIAPISummarizer.takesLowReasoningEffort("gpt-6-astra"))
        #expect(!OpenAIAPISummarizer.usesGPT5ParameterSet("gpt-4o"))
        #expect(!OpenAIAPISummarizer.usesGPT5ParameterSet("gpt-4-turbo"))
    }

    // MARK: - Local context guard

    @Test("A server that read half of what we sent is treated as truncation")
    func contextGuard_reportedCountWins() {
        // 30k-token prompt, model read 4096 — a stock LM Studio window.
        #expect(LocalContextGuard.truncationSuspected(
            estimatedTokens: 30_000, reportedPromptTokens: 4_096, windowTokens: 4_096
        ))
        // Read nearly all of it: the model is at fault, not the window.
        #expect(!LocalContextGuard.truncationSuspected(
            estimatedTokens: 25_000, reportedPromptTokens: 20_000, windowTokens: 4_096
        ))
        // An honest count OVERRIDES a suspicious window — this is the
        // Re-summarize case, where a warm cache used to make Daisy
        // accuse a 256k model of truncating.
        #expect(!LocalContextGuard.truncationSuspected(
            estimatedTokens: 30_000, reportedPromptTokens: 30_500, windowTokens: 4_096
        ))
    }

    @Test("Without a reported count the window we asked for decides")
    func contextGuard_windowFallback() {
        #expect(LocalContextGuard.truncationSuspected(
            estimatedTokens: 30_000, reportedPromptTokens: nil, windowTokens: 4_096
        ))
        // Ollama sizes num_ctx from the prompt, so this is the normal
        // case there and must NOT read as an overflow.
        #expect(!LocalContextGuard.truncationSuspected(
            estimatedTokens: 30_000, reportedPromptTokens: nil, windowTokens: 34_096
        ))
    }

    @Test("A missing or zero token count is not a count of zero")
    func contextGuard_positive() {
        #expect(LocalContextGuard.positive(nil) == nil)
        #expect(LocalContextGuard.positive(0) == nil)
        #expect(LocalContextGuard.positive(-3) == nil)
        #expect(LocalContextGuard.positive("nope") == nil)
        #expect(LocalContextGuard.positive(4_096) == 4_096)
        #expect(LocalContextGuard.positive(NSNumber(value: 512)) == 512)
    }

    @Test("Unknown cloud model is never shown as free")
    func tokenCostEstimate_unknownCloudModelIsUnpriced() {
        let estimate = TokenCostEstimator.estimate(
            provider: .openai,
            model: "future-gpt",
            spend: TokenSpend(inputTokens: 100, outputTokens: 50)
        )
        #expect(!estimate.hasPricedUsage)
        #expect(estimate.hasUnpricedBilledUsage)
    }

    @Test("A web search alone counts as token-ledger activity")
    func tokenSpend_webSearchIsActivity() {
        #expect(TokenSpend(webSearches: 1).hasActivity)
    }

    // MARK: - resolveSummaryLocaleHint precedence
    //
    // 1.0.3 flipped precedence: explicit picker wins over content
    // detection. This test pins that contract so a future refactor
    // doesn't silently restore detection-first behaviour and
    // recreate the "I picked Polish, why is it Russian?" UX bug.

    @Test("Explicit picker beats content detection")
    func summaryLocaleHint_explicitPickerWins() {
        let hint = RecordingSession.resolveSummaryLocaleHint(
            transcript: "Спасибо за встречу. Передам команде вашу позицию по бюджету и срокам. Завтра пришлю комментарии.",
            transcriptLocale: "ru-RU",
            summaryLanguageOverride: "pl"
        )
        #expect(hint == "pl")
    }

    @Test("Auto + content detection returns detected language")
    func summaryLocaleHint_autoUsesDetector() {
        let hint = RecordingSession.resolveSummaryLocaleHint(
            transcript: "Спасибо за встречу. Передам команде вашу позицию по бюджету и срокам. Завтра пришлю комментарии.",
            transcriptLocale: "auto",
            summaryLanguageOverride: SummaryLanguage.auto.id
        )
        #expect(hint == "ru")
    }

    @Test("Empty transcript with explicit picker still returns picker")
    func summaryLocaleHint_emptyTranscriptStillRespectsPicker() {
        let hint = RecordingSession.resolveSummaryLocaleHint(
            transcript: "",
            transcriptLocale: "auto",
            summaryLanguageOverride: "de"
        )
        #expect(hint == "de")
    }

    // MARK: - CloudSummaryDTO decode tolerance
    //
    // Pre-1.0.3 the decoder threw keyNotFound the moment Sonnet
    // emitted {"lede": "...", "sections": [...]}. 1.0.3 added
    // alias remapping + balanced-brace JSON extraction. These tests
    // pin that tolerance.

    @Test("Decodes the canonical schema cleanly")
    func cloudDTO_decodeCanonical() throws {
        let json = """
        {
          "summary": "Sales call with Altabel.",
          "sections": [
            {
              "title": "Pricing",
              "bullets": [
                { "text": "Monthly subscription with included credits", "children": [] }
              ]
            }
          ],
          "actionItems": ["Maria: send the contract by Thursday"],
          "clientFollowUp": "Thanks for the call..."
        }
        """
        let dto = try CloudSummaryDTO.decode(from: json)
        let summary = dto.toMeetingSummary()
        #expect(summary.summary == "Sales call with Altabel.")
        #expect(summary.sections.count == 1)
        #expect(summary.sections.first?.title == "Pricing")
        #expect(summary.actionItems.count == 1)
        #expect(summary.actionItems.first?.hasPrefix("Maria") == true)
    }

    @Test("Decodes 'lede' alias as summary")
    func cloudDTO_aliasLedeBecomesSummary() throws {
        let json = """
        {
          "lede": "Pricing call recap.",
          "outline": [],
          "action_items": [],
          "follow_up": ""
        }
        """
        let dto = try CloudSummaryDTO.decode(from: json)
        let summary = dto.toMeetingSummary()
        #expect(summary.summary == "Pricing call recap.")
    }

    @Test("Strips Markdown fences and trailing prose")
    func cloudDTO_stripFencesAndTrailingProse() throws {
        let json = """
        Here is the meeting summary:

        ```json
        {
          "summary": "Test.",
          "sections": [],
          "actionItems": [],
          "clientFollowUp": ""
        }
        ```

        Hope that helps!
        """
        let dto = try CloudSummaryDTO.decode(from: json)
        #expect(dto.toMeetingSummary().summary == "Test.")
    }

    // MARK: - RecordingSession.folderAllowed
    //
    // Auto-send folder allow-list. Empty set means "any folder";
    // non-empty restricts. Used by both Notion and MCP auto-send
    // paths. If this regresses, sessions silently route to the
    // wrong destination or get blocked.

    @Test("Empty allow-list permits every folder")
    func folderAllowed_emptyAllowsAll() {
        #expect(RecordingSession.folderAllowed("work", allowed: []) == true)
        #expect(RecordingSession.folderAllowed("personal", allowed: []) == true)
        #expect(RecordingSession.folderAllowed("notes", allowed: []) == true)
    }

    @Test("Non-empty allow-list restricts to listed slugs")
    func folderAllowed_restrictsToListed() {
        let allowed: Set<String> = ["work", "client-x"]
        #expect(RecordingSession.folderAllowed("work", allowed: allowed) == true)
        #expect(RecordingSession.folderAllowed("client-x", allowed: allowed) == true)
        #expect(RecordingSession.folderAllowed("personal", allowed: allowed) == false)
        #expect(RecordingSession.folderAllowed("notes", allowed: allowed) == false)
    }

    // MARK: - LanguageDetector confidence + scope gating
    //
    // Pinned because hallucinated language detection on short or
    // mixed text is what triggers the "summary came back in
    // Japanese" class of bugs. The detector intentionally returns
    // nil below threshold so the fallback path runs.

    @Test("Sub-16-char input returns nil")
    func languageDetector_tooShortReturnsNil() {
        #expect(LanguageDetector.detect("hi") == nil)
        #expect(LanguageDetector.detect("привет!") == nil)
    }

    @Test("Confident Russian detection")
    func languageDetector_clearRussianReturnsRu() {
        let detected = LanguageDetector.detect(
            "Спасибо за встречу. Передам команде вашу позицию по бюджету. Завтра пришлю комментарии."
        )
        #expect(detected == "ru")
    }

    @Test("Confident English detection")
    func languageDetector_clearEnglishReturnsEn() {
        let detected = LanguageDetector.detect(
            "Thanks for jumping on the call. I'll send the budget breakdown by Thursday morning."
        )
        #expect(detected == "en")
    }

    @Test("Transcription picker exposes the same 12 languages as summaries")
    func transcriptionLocales_matchSummaryLanguages() {
        let transcriptionCodes = Set(Transcriber.availableLocales.map(\.id).filter { $0 != "auto" })
        let summaryCodes = Set(SummaryLanguage.allCases.map(\.id).filter { $0 != "auto" })
        #expect(transcriptionCodes.count == 12)
        #expect(transcriptionCodes == summaryCodes)
    }

    // MARK: - SummaryLabels localisation
    //
    // The UI structural headers (Meeting / Next actions / Follow-up
    // for client / partner) follow the summary language. 1.0.2
    // shipped this for 11 languages — pin so a future refactor
    // doesn't silently revert one of the translations.

    @Test("Russian labels match expected Cyrillic")
    func summaryLabels_russianMatch() {
        let labels = SummaryLabels.for(language: "ru")
        #expect(labels.meeting == "Встреча")
        #expect(labels.nextActions == "Следующие шаги")
        #expect(labels.followUp == "Ответ клиенту / партнёру")
    }

    @Test("Unknown / nil language falls through to English")
    func summaryLabels_unknownReturnsEnglish() {
        let labels1 = SummaryLabels.for(language: nil)
        let labels2 = SummaryLabels.for(language: "xx-XX")
        let labels3 = SummaryLabels.for(language: "auto")
        for labels in [labels1, labels2, labels3] {
            #expect(labels.meeting == "Meeting")
            #expect(labels.nextActions == "Next actions")
            #expect(labels.followUp == "Follow-up for client / partner")
        }
    }
}

// MARK: - Shared audio test helpers
//
// Deterministic synthetic signals only — no microphone, no models,
// no network. AVFoundation's converter/file APIs are pure DSP + file
// IO and run fine on CI without audio hardware.

/// Mono/stereo Float32 PCM buffer filled with a phase-continuous sine
/// on every channel. Returns nil only on allocation failure.
private func makeSineBuffer(
    format: AVAudioFormat,
    frames: AVAudioFrameCount,
    frequency: Double,
    amplitude: Float
) -> AVAudioPCMBuffer? {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
    buffer.frameLength = frames
    guard let channels = buffer.floatChannelData else { return nil }
    let increment = 2.0 * Double.pi * frequency / format.sampleRate
    for ch in 0..<Int(format.channelCount) {
        var phase = 0.0
        for i in 0..<Int(frames) {
            channels[ch][i] = amplitude * Float(sin(phase))
            phase += increment
        }
    }
    return buffer
}

/// Raw Float sine samples with an explicit start phase, so chunked
/// callers can keep the waveform continuous across slices.
private func sineSamples(
    count: Int,
    frequency: Double,
    sampleRate: Double,
    amplitude: Float,
    startPhase: Double = 0
) -> (samples: [Float], endPhase: Double) {
    var phase = startPhase
    let increment = 2.0 * Double.pi * frequency / sampleRate
    var out = [Float](repeating: 0, count: count)
    for i in 0..<count {
        out[i] = amplitude * Float(sin(phase))
        phase += increment
    }
    return (out, phase)
}

/// Write a mono Float32 sine `.caf` to `url`. The AVAudioFile writer is
/// scoped so it deallocates (finalizing the header) before the caller
/// reads the file back.
private func writeSineCAF(
    to url: URL,
    sampleRate: Double,
    frames: AVAudioFrameCount
) throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ))
    let buffer = try #require(makeSineBuffer(
        format: format, frames: frames, frequency: 440, amplitude: 0.5
    ))
    let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    try file.write(from: buffer)
}

// MARK: - Audio format conversion (route-change regression locks)
//
// The most expensive historical bug class: a wired-headset/route
// change mid-recording flips the hardware between 44.1 kHz and
// 48 kHz. The fix pins one AVAudioConverter per format and rolls the
// archive into `microphone.partN.caf` parts, each converted
// independently (1.0.7.11 + the full-transcript archive final pass in
// 1.0.7.17). These tests lock the conversion invariants that fix
// relies on: any input rate yields the same 16 kHz duration, and a
// mixed-rate multi-part archive decodes end-to-end.

@Suite("Audio format conversion (route-change regression locks)")
@MainActor
struct AudioFormatConversionTests {

    @Test("44.1 kHz mono input converts to ~1 s of 16 kHz mono output")
    func converter_441kMonoToWhisperFormat() throws {
        let input = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        let converter = try #require(AudioConverter(inputFormat: input))
        #expect(converter.outputFormat.sampleRate == 16_000)
        #expect(converter.outputFormat.channelCount == 1)

        let buffer = try #require(makeSineBuffer(
            format: input, frames: 44_100, frequency: 440, amplitude: 0.5))
        let samples = try #require(converter.convert(buffer))
        // 1 s of input must come out as ~1 s at 16 kHz (resampler
        // priming may withhold a small head; capacity caps the tail).
        #expect(samples.count > 15_000)
        #expect(samples.count <= 16_100)
        // Amplitude survives resampling (440 Hz is far below Nyquist).
        let maxAbs = samples.map { abs($0) }.max() ?? 0
        #expect(maxAbs > 0.25)
        #expect(maxAbs < 0.75)
    }

    @Test("48 kHz stereo input downmixes + resamples to ~1 s of 16 kHz mono")
    func converter_48kStereoToWhisperFormat() throws {
        let input = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let converter = try #require(AudioConverter(inputFormat: input))

        let buffer = try #require(makeSineBuffer(
            format: input, frames: 48_000, frequency: 440, amplitude: 0.5))
        let samples = try #require(converter.convert(buffer))
        #expect(samples.count > 15_000)
        #expect(samples.count <= 16_100)
        let maxAbs = samples.map { abs($0) }.max() ?? 0
        #expect(maxAbs > 0.25)
        #expect(maxAbs < 0.75)
    }

    @Test("Same wall-clock duration converts to the same 16 kHz length for 44.1k and 48k inputs")
    func converter_durationInvariantAcrossRates() throws {
        let f441 = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        let f480 = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let c441 = try #require(AudioConverter(inputFormat: f441))
        let c480 = try #require(AudioConverter(inputFormat: f480))

        let b441 = try #require(makeSineBuffer(
            format: f441, frames: 44_100, frequency: 440, amplitude: 0.5))
        let b480 = try #require(makeSineBuffer(
            format: f480, frames: 48_000, frequency: 440, amplitude: 0.5))
        let out441 = try #require(c441.convert(b441))
        let out480 = try #require(c480.convert(b480))
        // The route-change fix depends on this: one second of audio is
        // one second of 16 kHz samples no matter what the hardware
        // rate was when the buffer arrived.
        #expect(abs(out441.count - out480.count) < 800)
    }

    @Test("Mixed-rate multi-part .caf archive decodes to the full duration")
    func archiveDecoder_mixedRatePartsDecodeFully() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Simulates a mid-session route change: part 1 recorded at
        // 44.1 kHz, part 2 at 48 kHz — 0.5 s each.
        let part1 = dir.appendingPathComponent("microphone.caf")
        let part2 = dir.appendingPathComponent("microphone.part2.caf")
        try writeSineCAF(to: part1, sampleRate: 44_100, frames: 22_050)
        try writeSineCAF(to: part2, sampleRate: 48_000, frames: 24_000)

        let samples = try #require(AudioArchiveDecoder.decodeToMono16k(urls: [part1, part2]))
        // ~1 s total at 16 kHz, allowing per-part resampler priming.
        #expect(samples.count > 14_500)
        #expect(samples.count < 16_500)
        let maxAbs = samples.map { abs($0) }.max() ?? 0
        #expect(maxAbs > 0.25)
    }

    @Test("Decoder returns nil for empty input and missing files")
    func archiveDecoder_nilWhenNothingDecodes() {
        #expect(AudioArchiveDecoder.decodeToMono16k(urls: []) == nil)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-tests-missing-\(UUID().uuidString).caf")
        #expect(AudioArchiveDecoder.decodeToMono16k(urls: [missing]) == nil)
    }

    @Test("Header-only zero-frame part is skipped, not crashed on")
    func archiveDecoder_zeroFramePartSkipped() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let huskURL = dir.appendingPathComponent("microphone.caf")
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        do {
            // Open + close a writer without writing any frames —
            // exactly the husk a crash-during-start leaves behind.
            _ = try AVAudioFile(
                forWriting: huskURL,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        }
        // Nothing decodable → nil (caller falls back to the in-memory
        // buffer), and no crash on the zero-frame file.
        #expect(AudioArchiveDecoder.decodeToMono16k(urls: [huskURL]) == nil)
    }
}

// MARK: - SpectrumAnalyzer (frozen-petals regression locks)
//
// Root cause of the "frozen petals" bug (fixed b7dd919): CoreAudio
// hands ~256–512-frame IO slices, and zero-padding a lone slice into
// the 2048-pt Hann window left it under the near-zero rising edge →
// every band read 0 → the noise gate never opened → petals froze at
// baseline. The fix is a rolling sample window. These tests pin that
// behaviour with synthetic sines — no audio hardware involved.

@Suite("SpectrumAnalyzer (frozen-petals regression locks)")
@MainActor
struct SpectrumAnalyzerTests {

    private let sampleRate: Double = 48_000

    @Test("440 Hz sine lights the 320-640 Hz band hardest")
    func sineLightsCorrectBand() {
        let analyzer = SpectrumAnalyzer()
        let (sine, _) = sineSamples(
            count: 2048, frequency: 440, sampleRate: sampleRate, amplitude: 0.8)
        var bands: [Float] = []
        // Several calls so the asymmetric attack smoothing converges.
        for _ in 0..<10 {
            bands = sine.withUnsafeBufferPointer {
                analyzer.bands(from: $0, sampleRate: sampleRate)
            }
        }
        #expect(bands.count == SpectrumAnalyzer.bandCount)
        // Band 2 spans 320-640 Hz — where 440 Hz lives.
        #expect(bands[2] > 0.5)
        for (i, value) in bands.enumerated() {
            #expect(value >= 0)
            #expect(value <= 1)
            if i != 2 {
                #expect(value <= bands[2])
            }
        }
    }

    @Test("Silence after speech decays every band back to rest")
    func silenceDecaysToZero() {
        let analyzer = SpectrumAnalyzer()
        let (sine, _) = sineSamples(
            count: 2048, frequency: 440, sampleRate: sampleRate, amplitude: 0.8)
        var bands: [Float] = []
        for _ in 0..<5 {
            bands = sine.withUnsafeBufferPointer {
                analyzer.bands(from: $0, sampleRate: sampleRate)
            }
        }
        // Sanity: the excitation actually registered before we test decay.
        #expect(bands[2] > 0.5)

        let zeros = [Float](repeating: 0, count: 2048)
        for _ in 0..<40 {
            bands = zeros.withUnsafeBufferPointer {
                analyzer.bands(from: $0, sampleRate: sampleRate)
            }
        }
        for value in bands {
            #expect(value < 0.01)
        }
    }

    @Test("Empty buffer neither crashes nor disturbs state")
    func emptyBufferIsSafe() {
        let analyzer = SpectrumAnalyzer()
        let empty: [Float] = []
        let bands = empty.withUnsafeBufferPointer {
            analyzer.bands(from: $0, sampleRate: sampleRate)
        }
        #expect(bands.count == SpectrumAnalyzer.bandCount)
        for value in bands {
            #expect(value >= 0)
            #expect(value <= 1)
        }
    }

    @Test("256-sample CoreAudio-style slices accumulate via the rolling window")
    func smallSlicesAccumulateSpectrum() {
        // THE frozen-petals scenario: tiny IO slices. With the old
        // zero-padded single-buffer FFT these stayed under the Hann
        // rising edge and every band read 0 forever. The rolling
        // window must build a full spectrum out of them.
        let analyzer = SpectrumAnalyzer()
        var phase = 0.0
        var bands: [Float] = []
        for _ in 0..<40 {
            let (chunk, endPhase) = sineSamples(
                count: 256, frequency: 440, sampleRate: sampleRate,
                amplitude: 0.8, startPhase: phase)
            phase = endPhase
            bands = chunk.withUnsafeBufferPointer {
                analyzer.bands(from: $0, sampleRate: sampleRate)
            }
        }
        #expect(bands[2] > 0.3)
        #expect((bands.max() ?? 0) > 0.3)
    }

    @Test("reset() clears the rolling window, not just the smoothing")
    func resetClearsRollingWindow() {
        let analyzer = SpectrumAnalyzer()
        let (sine, _) = sineSamples(
            count: 2048, frequency: 440, sampleRate: sampleRate, amplitude: 0.8)
        for _ in 0..<5 {
            _ = sine.withUnsafeBufferPointer {
                analyzer.bands(from: $0, sampleRate: sampleRate)
            }
        }
        analyzer.reset()
        // An empty call FFTs whatever is left in the window. If reset
        // didn't clear history, the previous recording's tail would
        // re-light the bands here.
        let empty: [Float] = []
        let bands = empty.withUnsafeBufferPointer {
            analyzer.bands(from: $0, sampleRate: sampleRate)
        }
        for value in bands {
            #expect(value < 0.01)
        }
    }
}

// MARK: - Level meters (-160 dB sentinel locks)
//
// The Bluetooth capture watchdog keys off the -160 dB sentinel
// (BT-output drags the mic to silence → -160 → pause/warning). If
// these helpers ever return NaN/-inf instead, the watchdog and the
// red-widget warning both misbehave.

@Suite("Level meters (-160 dB sentinel locks)")
@MainActor
struct AudioLevelMeterTests {

    @Test("Silent buffer reads exactly the -160 sentinel")
    func silenceReadsSentinel() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try #require(makeSineBuffer(
            format: format, frames: 1024, frequency: 440, amplitude: 0))  // amplitude 0 == explicit silence
        #expect(CoreAudioMicRecorder.peakLevelDB(of: buffer) == -160)
        #expect(CoreAudioMicRecorder.rmsLevelDB(of: buffer) == -160)
    }

    @Test("Zero-length buffer reads -160, never NaN or -inf")
    func zeroFramesReadSentinel() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 0
        #expect(CoreAudioMicRecorder.peakLevelDB(of: buffer) == -160)
        #expect(CoreAudioMicRecorder.rmsLevelDB(of: buffer) == -160)
    }

    @Test("Full-scale sine: peak ~0 dBFS, RMS ~-3 dB")
    func fullScaleSineLevels() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        // 4800 frames at 440 Hz / 48 kHz = exactly 44 periods, so the
        // RMS is exactly 1/sqrt(2) up to sampling granularity.
        let buffer = try #require(makeSineBuffer(
            format: format, frames: 4800, frequency: 440, amplitude: 1.0))
        let peak = CoreAudioMicRecorder.peakLevelDB(of: buffer)
        #expect(peak > -0.2)
        #expect(peak <= 0.01)
        let rms = CoreAudioMicRecorder.rmsLevelDB(of: buffer)
        #expect(abs(rms - (-3.01)) < 0.2)
    }
}

// MARK: - Search tokenizer (inverted-index prefilter locks)
//
// `SessionStore.sessionsMatching` prefilters with an inverted token
// index whose correctness contract is: tokenization must split and
// lowercase EXACTLY like `StoredSession.matches` lowercases, or the
// index drops true matches (silent search misses — the worst kind).

@Suite("Search tokenizer (inverted-index prefilter locks)")
@MainActor
struct SearchTokenizerTests {

    @Test("Cyrillic, Latin, and digits tokenize lowercased")
    func mixedAlphabetsTokenize() {
        #expect(SessionStore.searchTokens(in: "Встреча с MediaCube — бюджет 2026!")
            == ["встреча", "с", "mediacube", "бюджет", "2026"])
        #expect(SessionStore.searchTokens(in: "v2.0-beta") == ["v2", "0", "beta"])
        #expect(SessionStore.searchTokens(in: "ПРИВЕТ-Отчёт") == ["привет", "отчёт"])
    }

    @Test("Punctuation-only and empty input yield no tokens")
    func punctuationYieldsNothing() {
        #expect(SessionStore.searchTokens(in: "") == [])
        #expect(SessionStore.searchTokens(in: "?!… — ,,, ///") == [])
        #expect(SessionStore.searchTokens(in: "   \n\t  ") == [])
    }

    @Test("Order is preserved and duplicates are kept")
    func orderAndDuplicatesPreserved() {
        // sessionsMatching's multi-token candidate logic (suffix /
        // exact / prefix positions) depends on token ORDER, so the
        // tokenizer must not Set-ify.
        #expect(SessionStore.searchTokens(in: "так и так") == ["так", "и", "так"])
        #expect(SessionStore.searchTokens(in: "hello world hello") == ["hello", "world", "hello"])
    }
}

// MARK: - WhisperEngine.DecodeProfile knob locks
//
// Cheap lock so a refactor can't silently swap the live-pass `.lite`
// knobs onto the quality path (or vice versa). `.dictationFinal`'s
// single retry exists because its output is pasted verbatim — see the
// DecodeProfile doc comment.

@Suite("WhisperEngine.DecodeProfile knob locks")
@MainActor
struct DecodeProfileTests {

    @Test(".full keeps the historical quality knobs: 3 retries, topK 5, 16 workers")
    func fullProfileKnobs() {
        let p = WhisperEngine.DecodeProfile.full
        #expect(p.temperatureFallbackCount == 3)
        #expect(p.topK == 5)
        #expect(p.concurrentWorkerCount == 16)
    }

    @Test(".lite is greedy and retry-free: 0 retries, topK 1, 4 workers")
    func liteProfileKnobs() {
        let p = WhisperEngine.DecodeProfile.lite
        #expect(p.temperatureFallbackCount == 0)
        #expect(p.topK == 1)
        #expect(p.concurrentWorkerCount == 4)
    }

    @Test(".dictationFinal sits between: 1 retry, topK 1, 4 workers")
    func dictationFinalProfileKnobs() {
        let p = WhisperEngine.DecodeProfile.dictationFinal
        #expect(p.temperatureFallbackCount == 1)
        #expect(p.topK == 1)
        #expect(p.concurrentWorkerCount == 4)
    }
}

// MARK: - HotkeyChoice recording safety
//
// A global hotkey with no ⌃/⌥ is indistinguishable from a system or
// app shortcut, and Carbon registers it anyway — it was possible to
// record bare ⌘C as "rewrite in my voice" and lose system-wide Copy
// for as long as Daisy ran. `fromKeyCode` must refuse every such
// combo, not just the one that got caught by hand.

@Suite("HotkeyChoice recording safety")
@MainActor
struct HotkeyChoiceTests {

    @Test("Bare Cmd+letter system shortcuts are refused")
    func fromKeyCode_refusesBareCommandSystemShortcuts() {
        let reserved: [UInt16] = [
            UInt16(kVK_ANSI_C), UInt16(kVK_ANSI_V), UInt16(kVK_ANSI_X), UInt16(kVK_ANSI_A),
            UInt16(kVK_ANSI_Z), UInt16(kVK_ANSI_S), UInt16(kVK_ANSI_W), UInt16(kVK_ANSI_Q),
            UInt16(kVK_ANSI_N), UInt16(kVK_ANSI_T), UInt16(kVK_ANSI_F), UInt16(kVK_ANSI_P),
        ]
        for keyCode in reserved {
            #expect(HotkeyChoice.fromKeyCode(keyCode, modifierFlags: .command) == nil)
        }
    }

    @Test("Cmd+Shift with no Control/Option is refused too")
    func fromKeyCode_refusesCommandShiftWithoutControlOrOption() {
        #expect(HotkeyChoice.fromKeyCode(UInt16(kVK_ANSI_R), modifierFlags: [.command, .shift]) == nil)
    }

    @Test("A bare letter with no modifier at all is refused")
    func fromKeyCode_refusesBareLetter() {
        #expect(HotkeyChoice.fromKeyCode(UInt16(kVK_ANSI_R), modifierFlags: []) == nil)
    }

    @Test("Control or Option present is accepted, Cmd riding along or not")
    func fromKeyCode_acceptsControlOrOptionCombos() {
        #expect(HotkeyChoice.fromKeyCode(UInt16(kVK_ANSI_C), modifierFlags: [.control, .command]) != nil)
        #expect(HotkeyChoice.fromKeyCode(UInt16(kVK_ANSI_C), modifierFlags: .option) != nil)
        #expect(HotkeyChoice.fromKeyCode(UInt16(kVK_ANSI_R), modifierFlags: [.control, .option, .command]) != nil)
    }

    @Test("A bare function key is still accepted with no modifier")
    func fromKeyCode_acceptsBareFunctionKey() {
        #expect(HotkeyChoice.fromKeyCode(UInt16(kVK_F5), modifierFlags: []) != nil)
    }
}

// MARK: - LayoutFixExceptions (undo-taught word list)
//
// A word this list has learned must be refused fast and without
// touching the dictionary — this is the hottest path `judge` has,
// running on every automatically-typed word. Each instance gets its
// own UserDefaults suite so tests never share state with each other
// or with the real app's preferences.

@Suite("LayoutFixExceptions (undo-taught word list)")
@MainActor
struct LayoutFixExceptionsTests {

    private func freshDefaults() -> UserDefaults {
        let suite = "test.layoutFixExceptions.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test("A word is remembered case-insensitively")
    func add_isCaseInsensitive() {
        let store = LayoutFixExceptions(defaults: freshDefaults())
        store.add("Ghbdtn")
        #expect(store.contains("ghbdtn"))
        #expect(store.contains("GHBDTN"))
        #expect(store.count == 1)
    }

    @Test("Adding the same word twice does not duplicate it")
    func add_isIdempotent() {
        let store = LayoutFixExceptions(defaults: freshDefaults())
        store.add("ghbdtn")
        store.add("Ghbdtn")
        #expect(store.count == 1)
    }

    @Test("Overflow past the cap evicts the oldest words first")
    func add_evictsOldestWordsOnOverflow() {
        let store = LayoutFixExceptions(defaults: freshDefaults())
        for i in 0..<(LayoutFixExceptions.cap + 5) {
            store.add("word\(i)")
        }
        #expect(store.count == LayoutFixExceptions.cap)
        #expect(!store.contains("word0"))
        #expect(!store.contains("word4"))
        #expect(store.contains("word5"))
        #expect(store.contains("word\(LayoutFixExceptions.cap + 4)"))
    }

    @Test("A second instance on the same UserDefaults sees what the first stored")
    func roundTrips_throughUserDefaults() {
        let defaults = freshDefaults()
        let first = LayoutFixExceptions(defaults: defaults)
        first.add("привет")
        let second = LayoutFixExceptions(defaults: defaults)
        #expect(second.contains("привет"))
        #expect(second.count == 1)
    }

    @Test("Clear empties the list and the empty state persists")
    func clear_persistsEmptyState() {
        let defaults = freshDefaults()
        let first = LayoutFixExceptions(defaults: defaults)
        first.add("ghbdtn")
        first.clear()
        let second = LayoutFixExceptions(defaults: defaults)
        #expect(second.count == 0)
    }
}

// MARK: - LayoutFix.judge × learned exceptions
//
// Proof of ORDER, not just outcome: "daisyundotestwordxyz" is neither a
// real word nor something that would convert to one, so if the
// exceptions gate weren't checked first, judge would fall through to
// `.nothingRealOnTheOtherSide` or `.noDictionaryForTargetLayout` — not
// `.learnedException`. Getting exactly that refusal is what shows the
// gate runs before any dictionary lookup, without needing to mock
// NSSpellChecker directly.

@Suite("LayoutFix.judge refuses learned exceptions first")
@MainActor
struct LayoutFixJudgeExceptionsTests {

    @Test("A word in the exceptions list is refused before any dictionary check")
    func judge_refusesLearnedExceptionBeforeDictionaryLookup() {
        // `judge` takes its exceptions store as a parameter for exactly
        // this reason: a throwaway instance here means this test never
        // touches `.shared` — which is the real, UserDefaults-backed
        // list a person's undos have taught, and used to get wiped by
        // this test's old `.shared.clear()` cleanup.
        let before = LayoutFixExceptions.shared.words
        let word = "daisyundotestwordxyz"
        let isolated = LayoutFixExceptions(defaults: UserDefaults(suiteName: "test.judge.\(UUID().uuidString)")!)
        isolated.add(word)

        let result = LayoutFix.judge(word, exceptions: isolated)
        #expect(result.fix == nil)
        #expect(result.refusal == .learnedException)
        #expect(LayoutFixExceptions.shared.words == before)
    }
}

// MARK: - LayoutFixUndo (fix-key reversal window)
//
// `Record` fields mirror what one undo needs to reverse a fix and
// teach the exceptions list: the word to retype, the boundary that
// ended it, what's on screen to delete, which app it has to still be
// in, and the window past which a keypress is ordinary typing again,
// not an undo.

@Suite("LayoutFixUndo (fix-key reversal window)")
@MainActor
struct LayoutFixUndoTests {

    private func makeRecord(
        bundleID: String = "com.apple.Notes",
        generation: UInt64 = 0,
        at: Date = Date()
    ) -> LayoutFixUndo.Record {
        LayoutFixUndo.Record(
            originalWord: "ghbdtn",
            boundary: " ",
            replacementWord: "привет",
            bundleID: bundleID,
            restoreLayoutID: nil,
            generation: generation,
            at: at
        )
    }

    @Test("A fresh record for the same app is returned")
    func fresh_returnsRecentSameAppRecord() {
        let store = LayoutFixUndo.shared
        store.record(makeRecord())
        #expect(store.fresh(bundleID: "com.apple.Notes") != nil)
    }

    @Test("A record past the undo window is refused")
    func fresh_refusesStaleRecord() {
        let store = LayoutFixUndo.shared
        store.record(makeRecord(at: Date().addingTimeInterval(-10)))
        #expect(store.fresh(bundleID: "com.apple.Notes") == nil)
    }

    @Test("A record for a different app is refused")
    func fresh_refusesDifferentApp() {
        let store = LayoutFixUndo.shared
        store.record(makeRecord(bundleID: "com.apple.Notes"))
        #expect(store.fresh(bundleID: "com.apple.TextEdit") == nil)
    }

    @Test("clear() removes the pending record")
    func clear_removesPendingRecord() {
        let store = LayoutFixUndo.shared
        store.record(makeRecord())
        store.clear()
        #expect(store.fresh(bundleID: "com.apple.Notes") == nil)
    }

    @Test("Undo deletes by grapheme count, not Unicode scalar count — combining marks included")
    func replacementText_countsGraphemesNotScalars() {
        // Base + COMBINING BREVE (U+0306): one grapheme, two Unicode
        // scalars — the exact shape a layout conversion can produce,
        // and the case `presses = replacementText.count` has to get
        // right: one backspace per on-screen character, not per scalar.
        let combiningChar = "и" + "\u{0306}"
        #expect(combiningChar.count == 1)
        #expect(combiningChar.unicodeScalars.count == 2)

        let record = LayoutFixUndo.Record(
            originalWord: "ftq",
            boundary: " ",
            replacementWord: combiningChar + "ес",
            bundleID: "com.apple.Notes",
            restoreLayoutID: nil,
            generation: 0,
            at: Date()
        )
        #expect(record.replacementWord.count == 3)
        #expect(record.replacementText.count == 4)   // + boundary
        #expect(record.replacementText.unicodeScalars.count > record.replacementText.count)
    }

    @Test("generationAllowsUndo tolerates the fix key's own chord (0 or +1), refuses more")
    func generationAllowsUndo_toleratesUpToOneBump() {
        #expect(LayoutFixUndo.generationAllowsUndo(recorded: 10, current: 10))
        #expect(LayoutFixUndo.generationAllowsUndo(recorded: 10, current: 11))
        #expect(!LayoutFixUndo.generationAllowsUndo(recorded: 10, current: 12))
        #expect(!LayoutFixUndo.generationAllowsUndo(recorded: 10, current: 13))
        // Boundary case: recorded 0, only 0 and 1 pass.
        #expect(LayoutFixUndo.generationAllowsUndo(recorded: 0, current: 0))
        #expect(LayoutFixUndo.generationAllowsUndo(recorded: 0, current: 1))
        #expect(!LayoutFixUndo.generationAllowsUndo(recorded: 0, current: 2))
    }

    @Test("WordBuffer.discard() itself bumps generation — settle must read it AFTER calling discard()")
    func bufferGeneration_bumpsOnDiscard() {
        // Proof of the exact ordering bug the task warns about: a
        // generation value cached BEFORE `discard()` is already one
        // behind the value `settle` actually needs to record. This
        // drives the real WordBuffer type `LayoutAutoFix.buffer` is,
        // not a stand-in, so the behaviour it pins is the real one.
        let buffer = WordBuffer()
        _ = buffer.append("g")
        _ = buffer.append("h")
        let beforeDiscard = buffer.generation
        buffer.discard()
        let afterDiscard = buffer.generation
        #expect(afterDiscard == beforeDiscard + 1)
    }
}
