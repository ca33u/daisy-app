//
//  DaisyLLMWire.swift
//  DaisyLLMKit
//
//  What Daisy and DaisyLLM.xpc say to each other. Every message is one of
//  these Codable values as JSON `Data`, so the NSXPC interfaces carry only
//  `Data` and `String` and adding a field never needs a new selector.
//  `protocolVersion` changes only when an old helper couldn't read a new
//  request (a helper from another Daisy build answers `.protocolMismatch`).
//

import Foundation

public enum DaisyLLMWire {
    /// The XPC service's bundle identifier inside Daisy.app.
    public static let serviceName = "app.essazanov.Daisy.LLM"
    public static let protocolVersion = 1

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

/// One generation: the prompts Daisy's `SummaryPrompt` built, the model
/// folder on disk and the limits for this Mac.
public struct DaisyLLMRequest: Codable, Sendable, Equatable {
    public var id: UUID
    public var protocolVersion: Int
    /// A folder in the mlx-community layout (`config.json`,
    /// `model.safetensors`, `tokenizer.json`, `chat_template.jinja`).
    public var modelDirectory: String
    public var systemPrompt: String
    public var userPrompt: String
    /// The output language Daisy resolved ("ru", "en"…). The prompts
    /// already say it; the helper only logs it and echoes it back.
    public var language: String?
    /// When set, the output is constrained token by token to this JSON
    /// Schema (Daisy passes `MeetingSummaryJSONSchema.json`), so it can't
    /// leave the schema or trail text after the object.
    public var jsonSchema: String?
    public var limits: DaisyLLMLimits

    public init(
        id: UUID = UUID(),
        modelDirectory: String,
        systemPrompt: String,
        userPrompt: String,
        language: String? = nil,
        jsonSchema: String? = nil,
        limits: DaisyLLMLimits = DaisyLLMLimits()
    ) {
        self.id = id
        self.protocolVersion = DaisyLLMWire.protocolVersion
        self.modelDirectory = modelDirectory
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.language = language
        self.jsonSchema = jsonSchema
        self.limits = limits
    }
}

public struct DaisyLLMLimits: Codable, Sendable, Equatable {
    /// Tokens the model may write. With a schema it is steered to close
    /// the JSON as this nears, and fails `.outputIncomplete` past it.
    public var maxOutputTokens: Int
    /// The longest prompt this Mac should read; longer fails
    /// `.promptTooLong` before any work. nil — no ceiling (Qwen 3.5 reads
    /// 256K; memory is the real limit, which is Л-3's call per Mac).
    public var maxPromptTokens: Int?
    /// Prompt tokens read per forward pass. nil — 2 048, what the spike
    /// measured; 8 GB Macs will want 512 (Л-0).
    public var prefillStepSize: Int?
    /// A ceiling for MLX's allocator in bytes; nil leaves MLX's default.
    public var memoryLimitBytes: Int?

    public init(
        maxOutputTokens: Int = 4096,
        maxPromptTokens: Int? = nil,
        prefillStepSize: Int? = nil,
        memoryLimitBytes: Int? = nil
    ) {
        self.maxOutputTokens = maxOutputTokens
        self.maxPromptTokens = maxPromptTokens
        self.prefillStepSize = prefillStepSize
        self.memoryLimitBytes = memoryLimitBytes
    }
}

public struct DaisyLLMResponse: Codable, Sendable, Equatable {
    public var id: UUID
    public var text: String
    public var promptTokens: Int
    public var outputTokens: Int
    /// 0 when the model was already loaded in this helper.
    public var loadSeconds: Double
    /// Reading the prompt (prefill).
    public var promptSeconds: Double
    /// Writing the answer.
    public var generateSeconds: Double
    /// MLX's peak since the helper started.
    public var peakMemoryBytes: Int
    public var language: String?

    public init(
        id: UUID, text: String, promptTokens: Int, outputTokens: Int,
        loadSeconds: Double, promptSeconds: Double, generateSeconds: Double,
        peakMemoryBytes: Int, language: String?
    ) {
        self.id = id
        self.text = text
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.loadSeconds = loadSeconds
        self.promptSeconds = promptSeconds
        self.generateSeconds = generateSeconds
        self.peakMemoryBytes = peakMemoryBytes
        self.language = language
    }
}

/// Sent while a request runs, for «Читаю расшифровку… 40 %», then «Пишу…».
public struct DaisyLLMProgress: Codable, Sendable, Equatable {
    public var id: UUID
    public var stage: Stage

    public enum Stage: Codable, Sendable, Equatable {
        case loadingModel
        /// Prompt tokens read so far; (0, total) first, (total, total) when
        /// the answer starts.
        case reading(processed: Int, total: Int)
        /// Pieces of the answer so far, about one per token.
        case writing(tokens: Int)
    }

    public init(id: UUID, stage: Stage) {
        self.id = id
        self.stage = stage
    }
}

/// Why a request didn't produce text. The helper sends these as data;
/// Daisy turns them into words (RU+EN) — the helper has no strings.
public enum DaisyLLMFailure: Error, Codable, Sendable, Equatable {
    case modelNotFound(path: String)
    case modelUnreadable(detail: String)
    case promptTooLong(tokens: Int, limit: Int)
    case invalidSchema(detail: String)
    /// `maxOutputTokens` ran out before the JSON closed.
    case outputIncomplete(tokens: Int)
    case cancelled
    case unsupportedHardware
    case protocolMismatch(service: Int, client: Int)
    /// The helper was exiting on idle when the request arrived; sending
    /// it again starts a fresh helper.
    case serviceRestarting
    /// Client side: the helper couldn't be reached or went away mid-request
    /// (crashed, killed under memory pressure).
    case serviceUnavailable(detail: String)
    /// Client side: the request ran past the caller's time limit and was
    /// cancelled (a model too slow for this prompt on this Mac, or stuck).
    case timedOut(seconds: Int)
    case engine(detail: String)
}
