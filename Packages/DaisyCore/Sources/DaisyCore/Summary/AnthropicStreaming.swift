//
//  AnthropicStreaming.swift
//  DaisyCore
//
//  Anthropic over SSE (2026-10-08), ported from daisy-app's
//  AnthropicAPISummarizer + CloudStreaming (07.10.2026).
//
//  Why: the phone sent one non-streaming request with `max_tokens` 4096
//  and a 60 s timeout. Claude 5 models think by default, and on a long
//  meeting the thinking used the whole 4096 — the reply came back with a
//  thinking block and no text — while the 60 s timeout, an IDLE timeout,
//  fired on a server that writes nothing until the answer is done, and
//  the retry paid for the same generation again. Streamed, bytes arrive
//  the whole time (text deltas, and pings during thinking), so the idle
//  timer only fires on a connection that has really gone quiet, and the
//  ceiling can be high enough for thinking plus the answer.
//
//  Retries only BEFORE the answer starts (a 429/5xx, or a connection
//  that never opened); once a 2xx stream has begun a failure is
//  reported, not retried — a retry would pay for the answer twice.
//

import Foundation
import os

nonisolated enum AnthropicStreaming {
    /// Idle timeout between bytes. Generous: a thinking model can go
    /// quiet between pings; this only has to catch a dead connection.
    static let idleTimeout: TimeInterval = 120

    /// The generations known to take a 64K ceiling and `effort`: the
    /// Claude 5 family (5.5 / 5.1 included) and 4.6–4.8. An allow-list,
    /// so an older id typed by hand isn't sent a parameter it rejects.
    private static let modernPrefixes = [
        "claude-sonnet-5", "claude-opus-5", "claude-fable-5", "claude-mythos-5",
        "claude-haiku-5",
        "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6",
    ]

    static func isModern(_ model: String) -> Bool {
        let id = model.lowercased()
        return modernPrefixes.contains { id.hasPrefix($0) }
    }

    /// Room for thinking AND the answer: 64K on the modern models (they
    /// allow 128K), 32K on Haiku 4.5, the caller's own figure on anything
    /// older. Only generated tokens are billed.
    static func maxOutputTokens(for model: String, atLeast floor: Int) -> Int {
        if isModern(model) { return max(floor, 64_000) }
        if model.lowercased().hasPrefix("claude-haiku-4-5") { return max(floor, 32_000) }
        return floor
    }

    /// A Messages request body, streamed, with the ceiling and — where the
    /// model takes it — `effort` set.
    static func body(model: String, maxTokens: Int, effort: String, system: String,
                     messages: [[String: Any]]) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxOutputTokens(for: model, atLeast: maxTokens),
            "stream": true,
            "system": system,
            "messages": messages,
        ]
        if isModern(model) { body["output_config"] = ["effort": effort] }
        return body
    }

    static func request(apiKey: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = idleTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Stream the request and return the text of every text block, or
    /// throw: a cut-off, refused, broken-off or empty answer each gets
    /// its own error.
    static func text(
        _ request: URLRequest,
        session: URLSession = .shared,
        provider: String = "Anthropic",
        log: Logger
    ) async throws -> String {
        let bytes = try await open(request, session: session, provider: provider, log: log)
        var stream = AnthropicStreamAccumulator()
        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                stream.consume(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            log.error("\(provider, privacy: .public) stream broke off: \(error.localizedDescription, privacy: .public)")
            throw SummaryProviderError.streamInterrupted(provider: provider, message: error.localizedDescription)
        }
        if let message = stream.streamError {
            log.error("\(provider, privacy: .public) stream error: \(message, privacy: .public)")
            throw SummaryProviderError.streamInterrupted(provider: provider, message: message)
        }
        switch stream.stopReason {
        case "max_tokens":
            log.error("\(provider, privacy: .public) reply hit max_tokens (blocks: \(stream.blockTypes.joined(separator: ","), privacy: .public))")
            throw SummaryProviderError.outputTruncated(provider: provider)
        case "refusal":
            throw SummaryProviderError.refused(provider: provider)
        default:
            break
        }
        guard !stream.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log.error("\(provider, privacy: .public) reply had no text (stop: \(stream.stopReason ?? "none", privacy: .public), blocks: \(stream.blockTypes.joined(separator: ","), privacy: .public))")
            throw SummaryProviderError.invalidResponse(provider: provider)
        }
        return stream.text
    }

    /// Open the stream, retrying transient failures before any of the
    /// answer has arrived.
    private static func open(
        _ request: URLRequest,
        session: URLSession,
        provider: String,
        log: Logger,
        maxAttempts: Int = 3
    ) async throws -> URLSession.AsyncBytes {
        var attempt = 0
        while true {
            attempt += 1
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: request)
            } catch {
                if CloudHTTPRetry.isTransientURLError(error), attempt < maxAttempts {
                    log.warning("\(provider, privacy: .public): stream didn't open (\(error.localizedDescription, privacy: .public)) — retry \(attempt, privacy: .public)/\(maxAttempts, privacy: .public)")
                    try await Task.sleep(nanoseconds: UInt64(CloudHTTPRetry.backoffDelay(forAttempt: attempt) * 1_000_000_000))
                    continue
                }
                throw error
            }
            guard let http = response as? HTTPURLResponse else {
                throw SummaryProviderError.invalidResponse(provider: provider)
            }
            if (200..<300).contains(http.statusCode) { return bytes }
            if CloudHTTPRetry.isTransientStatus(http.statusCode), attempt < maxAttempts {
                log.warning("\(provider, privacy: .public): HTTP \(http.statusCode, privacy: .public) — retry \(attempt, privacy: .public)/\(maxAttempts, privacy: .public)")
                try await Task.sleep(nanoseconds: UInt64(CloudHTTPRetry.backoffDelay(forAttempt: attempt) * 1_000_000_000))
                continue
            }
            var data = Data()
            do {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= 64 * 1024 { break }
                }
            } catch {}
            let body = String(decoding: data, as: UTF8.self)
            // Body stays private: 4xx replies can quote the prompt back.
            log.error("\(provider, privacy: .public) HTTP \(http.statusCode, privacy: .public): \(body, privacy: .private)")
            throw SummaryProviderError.httpError(provider: provider, status: http.statusCode, body: body)
        }
    }
}

/// Accumulates an Anthropic Messages SSE stream: the text of every text
/// block, the stop reason, and a mid-stream `error` event if one came.
nonisolated struct AnthropicStreamAccumulator {
    private(set) var text = ""
    private(set) var stopReason: String?
    private(set) var blockTypes: [String] = []
    private(set) var streamError: String?

    mutating func consume(_ payload: String) {
        guard let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        switch type {
        case "content_block_start":
            if let block = event["content_block"] as? [String: Any], let blockType = block["type"] as? String {
                blockTypes.append(blockType)
                if blockType == "text", let initial = block["text"] as? String { text += initial }
            }
        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let piece = delta["text"] as? String {
                text += piece
            }
        case "message_delta":
            if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                stopReason = reason
            }
        case "error":
            let error = event["error"] as? [String: Any]
            streamError = (error?["message"] as? String) ?? (error?["type"] as? String) ?? "stream error"
        default:
            break  // message_start, ping, content_block_stop, message_stop
        }
    }
}
