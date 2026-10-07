//
//  CloudHTTPRetry.swift
//  Daisy
//
//  Shared HTTP retry helper for cloud LLM provider calls (Anthropic,
//  OpenAI, future Gemini, etc.) and any other cloud endpoint that
//  benefits from transient-failure recovery.
//
//  Pre-1.0.7.3 this lived as `nonisolated static func` methods on
//  `AnthropicAPISummarizer`, and `OpenAIAPISummarizer` called it as
//  `AnthropicAPISummarizer.fetchWithRetry(...)` — functionally
//  correct but the cross-provider naming was awkward and made the
//  ownership unclear. Lifted out into a stand-alone enum namespace
//  so neither provider "owns" the helper.
//
//  Backoff strategy: 1s → 2s → 4s geometric over 3 attempts total.
//  Long enough to wait through a transient gateway hiccup, short
//  enough that the user-visible summary task doesn't sit pending
//  for more than ~8s on the worst case before falling through to
//  the actual error.
//

import Foundation
import os

/// Enum namespace for HTTP retry utilities. No instances — pure
/// static functions over the URLSession arg.
nonisolated enum CloudHTTPRetry {

    /// Run an HTTP request with exponential-backoff retries on
    /// transient failures: 429 (rate limit), 5xx server errors, and
    /// URLSession transient network errors (timeout / connection
    /// dropped / DNS hiccup). Up to 3 attempts total with delays
    /// 1s → 2s → 4s between them.
    ///
    /// Permanent failures (4xx other than 429, malformed responses,
    /// any error that isn't in the transient list) are returned
    /// immediately so the caller sees the actual error.
    nonisolated static func fetch(
        request: URLRequest,
        session: URLSession,
        log: Logger,
        maxAttempts: Int = 3
    ) async throws -> (Data, URLResponse) {
        var lastError: (any Error)?
        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse,
                   isTransientStatus(http.statusCode),
                   attempt < maxAttempts {
                    let delay = backoffDelay(forAttempt: attempt)
                    log.warning("HTTP \(http.statusCode, privacy: .public) — retry in \(Int(delay), privacy: .public)s (attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public))")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                return (data, response)
            } catch {
                lastError = error
                if isTransientURLError(error), attempt < maxAttempts {
                    let delay = backoffDelay(forAttempt: attempt)
                    log.warning("Network error — retry in \(Int(delay), privacy: .public)s (attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
        // Unreachable — the `for` loop always returns or throws.
        // Compiler satisfaction throw.
        throw lastError ?? URLError(.unknown)
    }

    nonisolated static func isTransientStatus(_ code: Int) -> Bool {
        return code == 429 || (500...599).contains(code)
    }

    nonisolated private static func isTransientURLError(_ error: any Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorDNSLookupFailed,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost:
            return true
        default:
            return false
        }
    }

    /// For `CloudStreaming.open`, which retries only before a stream starts.
    nonisolated static func isTransient(_ error: any Error) -> Bool { isTransientURLError(error) }
    nonisolated static func backoff(_ attempt: Int) -> TimeInterval { backoffDelay(forAttempt: attempt) }

    nonisolated private static func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
        // 1s, 2s, 4s — geometric backoff. Plenty for transient
        // gateway hiccups, short enough not to time out the summary
        // task entirely (which has its own timeout ceiling upstream).
        return pow(2.0, Double(attempt - 1))
    }
}
