//
//  CloudStreaming.swift
//  Daisy
//
//  Streaming (SSE) for the cloud summary providers — Anthropic and
//  OpenAI (07.10.2026).
//
//  Why: the summaries were single non-streaming requests with a 60 s
//  `timeoutInterval`, and that interval is an IDLE timeout — a server
//  that writes nothing until the whole answer is ready is idle for the
//  whole generation. A two-hour meeting's summary routinely takes longer
//  than a minute, so the request timed out, `CloudHTTPRetry` counted the
//  timeout as transient and started the same (billed) generation again,
//  up to three times. Streamed, bytes arrive the whole time — text
//  deltas, and Anthropic's pings during thinking — so the idle timer
//  only fires on a connection that has really gone quiet.
//
//  Retries: only BEFORE the answer starts (a 429/5xx status, or a
//  connection that never opened). Once a 2xx stream has begun, a failure
//  is reported, not retried — a retry would pay for the same answer
//  twice.
//
//  The event parsing lives in small accumulator types so it can be
//  tested without a network (DaisyTests/CloudStreamingTests.swift).
//

import Foundation
import os

nonisolated enum CloudStreaming {
    /// Idle timeout between bytes of a stream. Generous: a thinking model
    /// can go quiet between pings, and this only has to catch a dead
    /// connection.
    static let idleTimeout: TimeInterval = 120

    /// Open the stream, retrying transient failures before any of the
    /// answer has arrived. Returns the byte stream of a 2xx response, or
    /// throws `SummaryProviderError.httpError` with the error body.
    static func open(
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
                if CloudHTTPRetry.isTransient(error), attempt < maxAttempts {
                    log.warning("\(provider, privacy: .public): stream didn't open (\(error.localizedDescription, privacy: .public)) — retry \(attempt, privacy: .public)/\(maxAttempts, privacy: .public)")
                    try await Task.sleep(for: .seconds(CloudHTTPRetry.backoff(attempt)))
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
                try await Task.sleep(for: .seconds(CloudHTTPRetry.backoff(attempt)))
                continue
            }
            let body = await readBody(bytes)
            // .private: a 4xx body can quote the prompt, which is someone's meeting.
            log.error("\(provider, privacy: .public) HTTP \(http.statusCode, privacy: .public): \(body, privacy: .private)")
            throw SummaryProviderError.httpError(provider: provider, status: http.statusCode, body: body)
        }
    }

    /// An error body, capped — it's for a message, not for parsing.
    private static func readBody(_ bytes: URLSession.AsyncBytes) async -> String {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 64 * 1024 { break }
            }
        } catch {}
        return String(decoding: data, as: UTF8.self)
    }

    /// Feed every `data:` line of an SSE stream to `consume`.
    static func forEachData(
        in bytes: URLSession.AsyncBytes,
        _ consume: (String) throws -> Void
    ) async throws {
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            try consume(payload)
        }
    }
}

// MARK: - Anthropic Messages stream

/// Accumulates an Anthropic Messages SSE stream: the text of every text
/// block, the stop reason, and usage in the shape `TokenSpend.anthropic`
/// reads (`message_start` carries the input side, `message_delta` the
/// running output count).
nonisolated struct AnthropicStreamAccumulator {
    private(set) var text = ""
    private(set) var stopReason: String?
    private(set) var blockTypes: [String] = []
    private(set) var usage: [String: Any] = [:]
    /// A mid-stream `error` event (e.g. overloaded), if one came.
    private(set) var streamError: String?

    /// The whole message as non-streaming JSON would have had it, for
    /// the token ledger.
    var messageJSON: [String: Any] { ["usage": usage] }

    mutating func consume(_ payload: String) {
        guard let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        switch type {
        case "message_start":
            if let message = event["message"] as? [String: Any],
               let start = message["usage"] as? [String: Any] {
                merge(start)
            }
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
            // Cumulative counts: the latest wins.
            if let more = event["usage"] as? [String: Any] {
                merge(more)
            }
        case "error":
            let error = event["error"] as? [String: Any]
            streamError = (error?["message"] as? String) ?? (error?["type"] as? String) ?? "stream error"
        default:
            break  // ping, content_block_stop, message_stop
        }
    }

    /// Later usage wins, but a `null` never overwrites a count: the
    /// delta may repeat input fields as null, and the input side is most
    /// of a long meeting's cost (review find, 07.10.2026).
    private mutating func merge(_ more: [String: Any]) {
        for (key, value) in more where !(value is NSNull) {
            usage[key] = value
        }
    }
}

// MARK: - OpenAI Chat Completions stream

/// Accumulates an OpenAI-compatible chat-completions SSE stream: content
/// deltas, the finish reason, and the usage chunk that
/// `stream_options.include_usage` adds at the end.
nonisolated struct OpenAIStreamAccumulator {
    private(set) var text = ""
    private(set) var finishReason: String?
    private(set) var usage: [String: Any]?
    private(set) var streamError: String?

    var completionJSON: [String: Any] { usage.map { ["usage": $0] } ?? [:] }

    mutating func consume(_ payload: String) {
        if payload == "[DONE]" { return }
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let error = chunk["error"] as? [String: Any] {
            streamError = (error["message"] as? String) ?? "stream error"
            return
        }
        if let used = chunk["usage"] as? [String: Any] { usage = used }
        guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { return }
        if let delta = choice["delta"] as? [String: Any], let piece = delta["content"] as? String {
            text += piece
        }
        if let reason = choice["finish_reason"] as? String { finishReason = reason }
    }
}
