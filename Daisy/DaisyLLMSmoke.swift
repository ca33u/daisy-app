//
//  DaisyLLMSmoke.swift
//  Daisy
//
//  A hidden way to run «Локальная модель Daisy» by hand before it has a
//  provider or a Settings row (Л-1):
//
//      Daisy.app/Contents/MacOS/Daisy --daisy-llm-smoke <model-folder> \
//          <system.txt> <user.txt> [--lang ru] [--free | --recursive | --schema <file>] [--cancel-after <s>] [--linger <s>]
//
//  One generation through DaisyLLM.xpc — constrained to
//  MeetingSummaryJSONSchema.localModelJSON (the two-level shape Л-3 sends)
//  unless `--free`, `--recursive` (the full recursive schema, which long
//  meetings collapse under) or `--schema <file>` (to try another shape) — the answer on stdout, the
//  progress and the numbers on stderr, then the process exits (after
//  `--linger` seconds, to watch the helper leave on its own idle clock
//  while Daisy is still there). It runs
//  before DaisyApp sets anything up (no window, no Sentry, no MCP port),
//  so it can run next to the Daisy in /Applications. Like
//  `--benchmark-record`, nobody passes it by accident.
//
//  `Daisy --daisy-llm-summary <model-folder> <transcript.txt> [--lang ru]`
//  goes the provider's whole way instead — Daisy's own prompts
//  (SummaryPrompt), the two-level schema, the answer as a MeetingSummary —
//  and prints that summary.
//
//  `installed` as the model folder means the downloaded model
//  (LocalSummaryModel); `Daisy --daisy-llm-download` fetches it (3 GB,
//  mirror then pinned Hugging Face) and exits — the way to get it on a Mac
//  before Settings has a button (Л-4).
//

import Foundation
import DaisyLLMKit
import os

nonisolated enum DaisyLLMSmoke {
    static let flag = "--daisy-llm-smoke"
    static let downloadFlag = "--daisy-llm-download"
    static let summaryFlag = "--daisy-llm-summary"

    /// Returns at once without either flag; with one, never returns.
    static func runIfRequested(_ arguments: [String] = CommandLine.arguments) {
        if arguments.contains(downloadFlag) {
            Task.detached { exit(await download()) }
            dispatchMain()
        }
        if let index = arguments.firstIndex(of: summaryFlag), arguments.count > index + 2 {
            let rest = Array(arguments[(index + 1)...])
            Task.detached { exit(await summary(rest)) }
            dispatchMain()
        }
        guard let index = arguments.firstIndex(of: flag) else { return }
        let rest = Array(arguments[(index + 1)...])
        guard rest.count >= 3 else {
            FileHandle.standardError.write(Data("usage: Daisy \(flag) <model-folder> <system.txt> <user.txt> [--lang ru] [--free | --recursive | --schema <file>] [--cancel-after <s>] [--linger <s>]\n".utf8))
            exit(64)
        }
        Task.detached {
            let code = await run(rest)
            if let linger = value(after: "--linger", in: rest).flatMap(Double.init) {
                say("lingering \(linger) s")
                try? await Task.sleep(for: .seconds(linger))
            }
            exit(code)
        }
        dispatchMain()
    }

    private static func value(after option: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: option), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    private static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func download() async -> Int32 {
        let total = LocalSummaryModel.downloadBytes() ?? 0
        say("downloading \(LocalSummaryModel.repo), \(total) bytes, into \(LocalSummaryModel.directory?.path ?? "?")")
        let shown = OSAllocatedUnfairLock(initialState: -1)
        do {
            try await LocalSummaryModel.download(progress: { share in
                let percent = Int(share * 100)
                if shown.withLock({ last in
                    guard percent > last else { return false }
                    last = percent
                    return true
                }) { say("\(percent) %") }
            })
            say("done: \(LocalSummaryModel.state())")
            return 0
        } catch {
            say("failed: \(error.localizedDescription)")
            return 1
        }
    }

    private static func summary(_ arguments: [String]) async -> Int32 {
        let folder = arguments[0] == "installed" ? LocalSummaryModel.directory : URL(fileURLWithPath: arguments[0])
        guard let transcript = try? String(contentsOfFile: arguments[1], encoding: .utf8) else {
            say("can't read \(arguments[1])")
            return 66
        }
        // Not into the person's token ledger: this is a test run.
        let provider = DaisyLocalSummarizer(modelFolder: folder, isInstalled: { true }, recordSpend: { _, _, _ in })
        let started = ContinuousClock.now
        do {
            let summary = try await provider.summarize(
                transcript: transcript, title: "Smoke", localeHint: value(after: "--lang", in: arguments), task: .standard)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(summary), as: UTF8.self))
            say("summary in \(ContinuousClock.now - started): \(summary.sections.count) sections, \(summary.sections.reduce(0) { $0 + $1.bullets.count }) bullets, \(summary.actionItems.count) actions")
            return 0
        } catch {
            say("failed: \(error.localizedDescription)")
            return 1
        }
    }

    private static func run(_ arguments: [String]) async -> Int32 {
        let request: DaisyLLMRequest
        do {
            let schema: String? = try value(after: "--schema", in: arguments)
                .map { try String(contentsOfFile: $0, encoding: .utf8) }
                ?? (arguments.contains("--free") ? nil
                    : arguments.contains("--recursive") ? MeetingSummaryJSONSchema.json
                    : MeetingSummaryJSONSchema.localModelJSON)
            let folder = arguments[0] == "installed" ? LocalSummaryModel.directory?.path ?? "" : arguments[0]
            request = DaisyLLMRequest(
                modelDirectory: folder,
                systemPrompt: try String(contentsOfFile: arguments[1], encoding: .utf8),
                userPrompt: try String(contentsOfFile: arguments[2], encoding: .utf8),
                language: value(after: "--lang", in: arguments),
                jsonSchema: schema)
        } catch {
            say("can't read the prompts: \(error)")
            return 66
        }
        let started = ContinuousClock.now
        let generation = Task {
            try await DaisyLLMClient.shared.generate(request) { stage in
                switch stage {
                case .loadingModel: say("loading the model…")
                case .reading(let processed, let total): say("reading \(processed)/\(total)")
                case .writing(let tokens): if tokens % 128 == 0 { say("writing \(tokens)") }
                }
            }
        }
        if let delay = value(after: "--cancel-after", in: arguments).flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(delay))
                say("cancelling after \(delay) s")
                generation.cancel()
            }
        }
        do {
            let response = try await generation.value
            let wall = ContinuousClock.now - started
            print(response.text)
            let json = (try? JSONSerialization.jsonObject(with: Data(response.text.utf8))) != nil
            let summary = (try? CloudSummaryDTO.decode(from: response.text)) != nil
            say(String(format: """
                prompt_tokens %d · read %.1f s (%.0f tok/s) · out_tokens %d · write %.1f s (%.1f tok/s) \
                · load %.1f s · peak %.2f GB · wall %.1f s · json %@ · CloudSummaryDTO %@
                """,
                response.promptTokens, response.promptSeconds,
                Double(response.promptTokens) / max(response.promptSeconds, 0.001),
                response.outputTokens, response.generateSeconds,
                Double(response.outputTokens) / max(response.generateSeconds, 0.001),
                response.loadSeconds, Double(response.peakMemoryBytes) / 1e9,
                Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18,
                json ? "valid" : "INVALID", summary ? "decodes" : "FAILS"))
            return 0
        } catch is CancellationError {
            say("cancelled (CancellationError) after \(ContinuousClock.now - started)")
            return 130
        } catch {
            say("failed: \(error.localizedDescription) — \(error)")
            return 1
        }
    }
}
