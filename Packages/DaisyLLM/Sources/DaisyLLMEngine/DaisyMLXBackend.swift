//
//  DaisyMLXBackend.swift
//  DaisyLLMEngine
//
//  The model, through MLX: loads an mlx-community folder (Qwen 3.5 4B
//  4-bit, the spike's layout), keeps it loaded until the helper exits on
//  idle, and runs one request — thinking off, the prompt read in chunks
//  with progress, the answer constrained to the request's JSON Schema.
//  The way the spike ran it (`main.swift`, 28.10), plus the grammar.
//
//  Its own log lines carry counts and timings only, never prompt or
//  answer text. (MLX's guided loop logs a prefix of the answer at info
//  level, which the unified log redacts as private.)
//

import Foundation
import DaisyLLMKit
import MLX
import MLXGuidedGeneration
import MLXLLM
import MLXLMCommon
import os

public actor DaisyMLXBackend: DaisyLLMBackend {
    private struct Loaded {
        let path: String
        let container: ModelContainer
        var grammarTokenizer: GrammarTokenizer?
    }

    private struct Outcome: Sendable {
        var text: String
        var promptTokens: Int
        var outputTokens: Int
        var promptSeconds: Double
        var generateSeconds: Double
    }

    /// The spike read prompts 2 048 tokens a forward (as mlx_lm does).
    static let defaultPrefillStepSize = 2048
    private static let log = Logger(subsystem: DaisyLLMWire.serviceName, category: "engine")

    private var loaded: Loaded?
    /// MLX's own allocator ceiling, put back for a request without one.
    private var defaultMemoryLimit: Int?

    public init() {}

    public func run(
        _ request: DaisyLLMRequest,
        progress: @escaping @Sendable (DaisyLLMProgress.Stage) -> Void
    ) async throws -> DaisyLLMResponse {
        #if !arch(arm64)
        throw DaisyLLMFailure.unsupportedHardware
        #else
        let started = ContinuousClock.now
        let defaultLimit = defaultMemoryLimit ?? Memory.memoryLimit
        defaultMemoryLimit = defaultLimit
        Memory.memoryLimit = request.limits.memoryLimitBytes ?? defaultLimit
        let wasLoaded = loaded?.path == request.modelDirectory
        let container = try await container(for: request.modelDirectory, progress: progress)
        let loadSeconds = wasLoaded ? 0 : Self.seconds(since: started)
        var grammarTokenizer: GrammarTokenizer?
        if request.jsonSchema != nil {
            grammarTokenizer = try await self.grammarTokenizer(for: container)
        }
        try Task.checkCancellation()

        let outcome = try await container.perform { [grammarTokenizer] context in
            try await Self.respond(to: request, context: context, grammarTokenizer: grammarTokenizer, progress: progress)
        }
        let response = DaisyLLMResponse(
            id: request.id, text: outcome.text,
            promptTokens: outcome.promptTokens, outputTokens: outcome.outputTokens,
            loadSeconds: loadSeconds, promptSeconds: outcome.promptSeconds,
            generateSeconds: outcome.generateSeconds,
            peakMemoryBytes: Memory.peakMemory, language: request.language)
        Self.log.info("""
            \(request.id.uuidString, privacy: .public) lang=\(request.language ?? "-", privacy: .public) \
            prompt=\(response.promptTokens) out=\(response.outputTokens) load=\(response.loadSeconds)s \
            read=\(response.promptSeconds)s write=\(response.generateSeconds)s peak=\(response.peakMemoryBytes)
            """)
        return response
        #endif
    }

    /// The loaded model when it is this folder's; otherwise the old one
    /// goes first (two models at once would not fit) and this one loads.
    private func container(
        for path: String,
        progress: @Sendable (DaisyLLMProgress.Stage) -> Void
    ) async throws -> ModelContainer {
        if let loaded, loaded.path == path { return loaded.container }
        loaded = nil
        Memory.clearCache()
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
            throw DaisyLLMFailure.modelNotFound(path: path)
        }
        progress(.loadingModel)
        do {
            // The factory itself rather than the registry lookup, so linking
            // MLXLLM is not left to the dead-code stripper's mercy.
            let container = try await LLMModelFactory.shared.loadContainer(
                from: directory, using: TransformersTokenizerLoader())
            loaded = Loaded(path: path, container: container)
            return container
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DaisyLLMFailure.modelUnreadable(detail: String(describing: error))
        }
    }

    /// Built once per loaded model: it walks the whole vocabulary.
    private func grammarTokenizer(for container: ModelContainer) async throws -> GrammarTokenizer {
        if let cached = loaded?.grammarTokenizer { return cached }
        let tokenizer = try await container.perform { context in
            let vocab = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
            return try GrammarTokenizer(
                vocab: vocab.vocab, vocabType: vocab.vocabType,
                eosTokenId: Int32(context.tokenizer.eosTokenId ?? 0))
        }
        loaded?.grammarTokenizer = tokenizer
        return tokenizer
    }

    private static func respond(
        to request: DaisyLLMRequest,
        context: ModelContext,
        grammarTokenizer: GrammarTokenizer?,
        progress: @escaping @Sendable (DaisyLLMProgress.Stage) -> Void
    ) async throws -> Outcome {
        // Qwen 3.5 thinks first unless the template is told not to; Daisy
        // wants the summary straight away (spike: the answer opens with JSON).
        let input = try await context.processor.prepare(input: UserInput(
            chat: [.system(request.systemPrompt), .user(request.userPrompt)],
            additionalContext: ["enable_thinking": false]))
        let promptTokens = input.text.tokens.size
        if let limit = request.limits.maxPromptTokens, promptTokens > limit {
            throw DaisyLLMFailure.promptTooLong(tokens: promptTokens, limit: limit)
        }
        // MLX reports per chunk only for prompts longer than one chunk and
        // never the last token, so the start and the end are sent here too:
        // the client counts any progress as «the helper has started».
        progress(.reading(processed: 0, total: promptTokens))
        let prefill = PrefillParameters(
            stepSize: request.limits.prefillStepSize ?? defaultPrefillStepSize,
            progress: { processed, total in progress(.reading(processed: processed, total: total)) })
        let maxTokens = request.limits.maxOutputTokens

        guard let schema = request.jsonSchema, let grammarTokenizer else {
            return try await free(
                input: input, promptTokens: promptTokens, context: context,
                maxTokens: maxTokens, prefill: prefill, progress: progress)
        }

        let constraint: GrammarConstraint
        do {
            constraint = try GrammarConstraint(
                tokenizer: grammarTokenizer, jsonSchema: schema,
                fastForward: true, hostTokenizer: context.tokenizer)
        } catch GrammarError.invalidJSONSchema(let message) {
            throw DaisyLLMFailure.invalidSchema(detail: message)
        } catch {
            throw DaisyLLMFailure.invalidSchema(detail: String(describing: error))
        }
        // Near the end of the budget the loop steers towards closing the
        // JSON instead of cutting it off — the reserves MLXFoundationModels
        // uses for the same loop.
        let structural = CompletionReserve.estimate(schemaJSON: schema, tokenizer: context.tokenizer)
        let completionReserve = min(max(structural * 3, maxTokens / 4), maxTokens)
        let hardReserve = min(structural * 8, maxTokens)
        let closing = ClosingTokenBias.compute(tokenizer: context.tokenizer, eosTokenId: context.tokenizer.eosTokenId)
        let whitespace = WhitespaceTokenBias.compute(tokenizer: context.tokenizer)

        let clock = ContinuousClock()
        let start = clock.now
        var firstText: ContinuousClock.Instant?
        var text = ""
        var pieces = 0
        let outputTokens: Int
        do {
            outputTokens = try GuidedGenerationLoop.run(
                input: input, context: context, constraint: constraint,
                maxTokens: maxTokens, vocabSize: grammarTokenizer.vocabSize,
                completionReserve: completionReserve, hardReserve: hardReserve,
                closingBias: closing, whitespaceBias: whitespace.bias,
                whitespaceTokenIDs: whitespace.tokenIDs, prefill: prefill
            ) { delta in
                if firstText == nil {
                    firstText = clock.now
                    progress(.reading(processed: promptTokens, total: promptTokens))
                }
                text += delta
                pieces += 1
                if pieces % 16 == 0 { progress(.writing(tokens: pieces)) }
                return !Task.isCancelled
            }
        } catch GuidedGenerationError.incompleteOutput {
            throw DaisyLLMFailure.outputIncomplete(tokens: maxTokens)
        } catch GuidedGenerationError.prematureEOS {
            throw DaisyLLMFailure.engine(detail: "the model stopped before the JSON was complete")
        }
        try Task.checkCancellation()
        let end = clock.now
        let firstAt = firstText ?? end
        return Outcome(
            text: text, promptTokens: promptTokens, outputTokens: outputTokens,
            // Up to the first piece of the answer: reading plus one token.
            promptSeconds: seconds(firstAt - start), generateSeconds: seconds(end - firstAt))
    }

    /// Without a schema: the spike's sampling, temperature 0.4.
    private static func free(
        input: consuming LMInput,
        promptTokens: Int,
        context: ModelContext,
        maxTokens: Int,
        prefill: PrefillParameters,
        progress: @escaping @Sendable (DaisyLLMProgress.Stage) -> Void
    ) async throws -> Outcome {
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0.4, prefill: prefill)
        let stream = try MLXLMCommon.generate(input: input, parameters: parameters, context: context)
        var text = ""
        var pieces = 0
        var info: GenerateCompletionInfo?
        for await item in stream {
            switch item {
            case .chunk(let piece):
                if pieces == 0 { progress(.reading(processed: promptTokens, total: promptTokens)) }
                text += piece
                pieces += 1
                if pieces % 16 == 0 { progress(.writing(tokens: pieces)) }
            case .info(let completion):
                info = completion
            default:
                break
            }
        }
        try Task.checkCancellation()
        guard let info else { throw DaisyLLMFailure.engine(detail: "generation ended without its statistics") }
        if info.stopReason == .length { throw DaisyLLMFailure.outputIncomplete(tokens: maxTokens) }
        return Outcome(
            text: text, promptTokens: info.promptTokenCount, outputTokens: info.generationTokenCount,
            promptSeconds: info.promptTime, generateSeconds: info.generateTime)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        seconds(ContinuousClock.now - start)
    }
}
