//
//  DaisyLLMSmoke.swift
//  Daisy
//
//  A hidden way to run «Локальная модель Daisy» by hand before it has a
//  provider or a Settings row (Л-1):
//
//      Daisy.app/Contents/MacOS/Daisy --daisy-llm-smoke <model-folder> \
//          <system.txt> <user.txt> [--lang ru] [--free | --schema <file>] [--cancel-after <s>] [--linger <s>]
//
//  One generation through DaisyLLM.xpc — constrained to
//  MeetingSummaryJSONSchema unless `--free` or `--schema <file>` (to try
//  another shape on the model) — the answer on stdout, the
//  progress and the numbers on stderr, then the process exits (after
//  `--linger` seconds, to watch the helper leave on its own idle clock
//  while Daisy is still there). It runs
//  before DaisyApp sets anything up (no window, no Sentry, no MCP port),
//  so it can run next to the Daisy in /Applications. Like
//  `--benchmark-record`, nobody passes it by accident.
//

import Foundation
import DaisyLLMKit

nonisolated enum DaisyLLMSmoke {
    static let flag = "--daisy-llm-smoke"

    /// Returns at once without the flag; with it, never returns.
    static func runIfRequested(_ arguments: [String] = CommandLine.arguments) {
        guard let index = arguments.firstIndex(of: flag) else { return }
        let rest = Array(arguments[(index + 1)...])
        guard rest.count >= 3 else {
            FileHandle.standardError.write(Data("usage: Daisy \(flag) <model-folder> <system.txt> <user.txt> [--lang ru] [--free | --schema <file>] [--cancel-after <s>] [--linger <s>]\n".utf8))
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

    private static func run(_ arguments: [String]) async -> Int32 {
        let request: DaisyLLMRequest
        do {
            let schema: String? = try value(after: "--schema", in: arguments)
                .map { try String(contentsOfFile: $0, encoding: .utf8) }
                ?? (arguments.contains("--free") ? nil : MeetingSummaryJSONSchema.json)
            request = DaisyLLMRequest(
                modelDirectory: arguments[0],
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
