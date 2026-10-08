//
//  CloudHTTPRetry.swift
//  DaisyCore
//
//  Copied from daisy-app/Daisy/CloudHTTPRetry.swift @ 1.0.7.72,
//  2026-09-19. Transient failures (429, 5xx, timeouts, dropped
//  connections) retry with 1s → 2s → 4s backoff; anything else is
//  returned at once.
//

import Foundation
import os

nonisolated enum CloudHTTPRetry {
    static func fetch(request: URLRequest, session: URLSession, log: Logger, maxAttempts: Int = 3) async throws -> (Data, URLResponse) {
        var lastError: (any Error)?
        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, isTransientStatus(http.statusCode), attempt < maxAttempts {
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
        throw lastError ?? URLError(.unknown)
    }

    static func isTransientStatus(_ code: Int) -> Bool {
        code == 429 || (500...599).contains(code)
    }

    static func isTransientURLError(_ error: any Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
             NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
            return true
        default:
            return false
        }
    }

    static func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
        pow(2.0, Double(attempt - 1))
    }
}
