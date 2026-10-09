//
//  CrashReportsTracingTests.swift
//  DaisyTests
//
//  Swizzling is on for uncaught NSExceptions alone (2026-10-09): no outgoing
//  request — Anthropic, OpenAI, Notion, Google, Sparkle — may carry a
//  `sentry-trace` or `baggage` header. The control run (network tracking on,
//  as Sentry ships) shows the test can see one.
//

import Foundation
import Sentry
import Testing
@testable import Daisy

/// Answers every request locally and keeps the headers it was sent.
final class HeaderCapture: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var headers: [String: String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.headers = request.allHTTPHeaderFields ?? [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A DSN that parses but goes nowhere: the test must not send sessions or
/// reports to the real project on every run.
private let offlineDSN = "https://key@sentry.invalid/1"

// MainActor: started from the main thread the SDK installs its hooks
// inline, with no wait to guess.
@MainActor
@Suite(.serialized)
struct CrashReportsTracingTests {
    private func headers(after configure: @escaping (Options) -> Void) async throws -> [String: String] {
        SentrySDK.start { options in configure(options) }
        defer { SentrySDK.close() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeaderCapture.self]
        let session = URLSession(configuration: config)
        HeaderCapture.headers = [:]
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            session.dataTask(with: url) { _, _, _ in done.resume() }.resume()
        }
        return HeaderCapture.headers
    }

    @Test func noTraceHeadersWithDaisysOptions() async throws {
        let sent = try await headers { options in
            CrashReports.configure(options)
            options.dsn = offlineDSN
        }
        #expect(sent["sentry-trace"] == nil)
        #expect(sent["baggage"] == nil)
    }

    @Test func controlTrackingOnAddsTheHeader() async throws {
        let sent = try await headers { options in
            options.dsn = offlineDSN
            options.enableAutoSessionTracking = false
            options.enableCaptureFailedRequests = false
            options.enableSwizzling = true
            options.enableNetworkTracking = true
            options.tracesSampleRate = 1
            options.beforeSend = { _ in nil }
        }
        #expect(sent["sentry-trace"] != nil)
    }
}
