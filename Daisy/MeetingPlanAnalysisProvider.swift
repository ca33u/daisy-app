//
//  MeetingPlanAnalysisProvider.swift
//  Daisy
//
//  Narrow raw-JSON transport for plan analysis. It intentionally does not
//  return MeetingSummary and never touches CloudSummaryDTO's tolerant parser.
//

import Foundation
import os

nonisolated protocol MeetingPlanAnalysisProviding: Sendable {
    func generate(
        developerInstructions: String,
        userPrompt: String,
        schema: Data
    ) async throws -> Data
}

nonisolated enum MeetingPlanAnalysisProviderError: LocalizedError {
    case unsupportedProvider(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let provider):
            return String(localized: "Plan analysis is not available for \(provider) yet. Choose OpenAI in \(SettingsRow.summaryProvider.path), then retry.")
        case .invalidResponse(let provider):
            return String(localized: "\(provider) returned an invalid structured plan analysis.")
        }
    }
}

nonisolated struct UnsupportedMeetingPlanAnalysisProvider: MeetingPlanAnalysisProviding {
    let providerName: String

    func generate(
        developerInstructions: String,
        userPrompt: String,
        schema: Data
    ) async throws -> Data {
        throw MeetingPlanAnalysisProviderError.unsupportedProvider(providerName)
    }
}

nonisolated struct CodexMeetingPlanAnalysisProvider: MeetingPlanAnalysisProviding {
    let model: String
    let executableOverride: String
    let service: any CodexAppServerServing

    init(
        model: String,
        executableOverride: String,
        service: any CodexAppServerServing = CodexAppServerService.shared
    ) {
        self.model = model
        self.executableOverride = executableOverride
        self.service = service
    }

    func generate(
        developerInstructions: String,
        userPrompt: String,
        schema: Data
    ) async throws -> Data {
        let object = try JSONSerialization.jsonObject(with: schema)
        let outputSchema = try CodexJSON(jsonObject: object)
        let text = try await service.summarize(
            prompt: userPrompt,
            developerInstructions: developerInstructions,
            model: model.isEmpty ? nil : model,
            outputSchema: outputSchema,
            executableOverride: executableOverride
        )
        guard let data = text.data(using: .utf8) else {
            throw MeetingPlanAnalysisProviderError.invalidResponse("ChatGPT")
        }
        return data
    }
}

nonisolated struct OpenAIMeetingPlanAnalysisProvider: MeetingPlanAnalysisProviding {
    let model: String
    let urlSession: URLSession
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "PlanAnalysis")

    init(model: String, urlSession: URLSession = .shared) {
        self.model = model
        self.urlSession = urlSession
    }

    func generate(
        developerInstructions: String,
        userPrompt: String,
        schema: Data
    ) async throws -> Data {
        guard let apiKey = KeychainStore.get(account: SecretKey.openaiAPIKey), !apiKey.isEmpty else {
            throw SummaryProviderError.missingAPIKey(provider: "OpenAI")
        }
        let schemaObject = try JSONSerialization.jsonObject(with: schema)
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": developerInstructions],
                ["role": "user", "content": userPrompt]
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "meeting_plan_analysis",
                    "strict": true,
                    "schema": schemaObject
                ]
            ]
        ]
        if OpenAIAPISummarizer.usesGPT5ParameterSet(model) {
            body["max_completion_tokens"] = 8_192
        } else {
            body["max_tokens"] = 4_096
            body["temperature"] = 0.2
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await CloudHTTPRetry.fetch(
            request: request,
            session: urlSession,
            log: log
        )
        guard let http = response as? HTTPURLResponse else {
            throw MeetingPlanAnalysisProviderError.invalidResponse("OpenAI")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SummaryProviderError.httpError(
                provider: "OpenAI",
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "<empty>"
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeetingPlanAnalysisProviderError.invalidResponse("OpenAI")
        }
        TokenLedgerSink.record(
            provider: .openai,
            model: model,
            spend: .openAICompatible(from: json)
        )
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8) else {
            throw MeetingPlanAnalysisProviderError.invalidResponse("OpenAI")
        }
        return contentData
    }
}

extension Summarizer {
    func makeMeetingPlanAnalysisProvider() -> any MeetingPlanAnalysisProviding {
        guard providerKind == .openai else {
            return UnsupportedMeetingPlanAnalysisProvider(providerName: providerKind.shortName)
        }
        if openAIConnectionMethod == .account {
            return CodexMeetingPlanAnalysisProvider(
                model: openAIAccountModel,
                executableOverride: agentCLIPath
            )
        }
        return OpenAIMeetingPlanAnalysisProvider(model: openaiModel)
    }
}
