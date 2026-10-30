//
//  DaisyLLMClient.swift
//  Daisy
//
//  Daisy's side of DaisyLLM.xpc, the helper that runs «Локальная модель
//  Daisy» (plan 2026-10-28, Л-1). One generation per call: the prompts go
//  in, the text and its token counts and timings come out; progress
//  arrives while it runs; cancelling the calling task cancels the model in
//  the helper and throws `CancellationError`, as the Ollama path does.
//
//  The helper exits a minute after its last request. A request that meets
//  it on its way out (`.serviceRestarting`, or the connection dropping
//  before anything started) is sent once more and launchd starts a fresh
//  helper; a helper that dies mid-request (memory pressure, an MLX crash)
//  is `.serviceUnavailable` — the summary is retried later, by the caller.
//
//  Not wired into Summarizer or Settings yet (Л-3/Л-4); the only caller is
//  the hidden `--daisy-llm-smoke` launch below.
//

import Foundation
import DaisyLLMKit

nonisolated final class DaisyLLMClient: @unchecked Sendable {
    static let shared = DaisyLLMClient()

    /// MLX needs Apple silicon; the helper is built arm64 only. An Intel
    /// Mac (or Daisy under Rosetta) never launches it.
    static let runsOnThisMac: Bool = {
        #if arch(x86_64)
        return false
        #else
        return true
        #endif
    }()

    nonisolated private struct Pending {
        let continuation: CheckedContinuation<DaisyLLMResponse, any Error>
        /// Which call registered it, so a refused duplicate's cancel can't
        /// reach the request that is really running.
        let attempt: UUID
        let onProgress: @Sendable (DaisyLLMProgress.Stage) -> Void
        let isRetry: Bool
        var sawProgress = false
    }

    private let makeConnection: @Sendable () -> NSXPCConnection
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var pending: [UUID: Pending] = [:]

    /// `makeConnection` is for the tests (an anonymous listener's endpoint).
    init(makeConnection: @escaping @Sendable () -> NSXPCConnection = {
        NSXPCConnection(serviceName: DaisyLLMWire.serviceName)
    }) {
        self.makeConnection = makeConnection
    }

    func generate(
        _ request: DaisyLLMRequest,
        onProgress: @escaping @Sendable (DaisyLLMProgress.Stage) -> Void = { _ in }
    ) async throws -> DaisyLLMResponse {
        guard Self.runsOnThisMac else { throw DaisyLLMFailure.unsupportedHardware }
        do {
            return try await attempt(request, onProgress: onProgress, isRetry: false)
        } catch DaisyLLMFailure.serviceRestarting {
            return try await attempt(request, onProgress: onProgress, isRetry: true)
        }
    }

    /// Drops the connection — the helper cancels what it was running for
    /// it — and fails the requests still waiting; the next call opens a new
    /// connection.
    func invalidate() {
        let (old, waiting) = lock.withLock {
            defer { connection = nil }
            return (connection, Array(pending.keys))
        }
        for id in waiting {
            resolve(id, .failure(DaisyLLMFailure.serviceUnavailable(detail: "Daisy closed the connection")))
        }
        old?.invalidate()
    }

    private func attempt(
        _ request: DaisyLLMRequest,
        onProgress: @escaping @Sendable (DaisyLLMProgress.Stage) -> Void,
        isRetry: Bool
    ) async throws -> DaisyLLMResponse {
        let data = try DaisyLLMWire.encode(request)
        let id = request.id
        let attempt = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let duplicate = lock.withLock {
                    if pending[id] != nil { return true }
                    pending[id] = Pending(
                        continuation: continuation, attempt: attempt, onProgress: onProgress, isRetry: isRetry)
                    return false
                }
                // The same request twice at once would orphan the first caller.
                if duplicate {
                    continuation.resume(throwing: DaisyLLMFailure.engine(detail: "request \(id) is already running"))
                    return
                }
                // Cancelled before the handler could see this request.
                if Task.isCancelled {
                    cancel(id, attempt: attempt)
                    return
                }
                // Still waiting (`invalidate()` may have failed it meanwhile):
                // only then take a connection and send.
                let connection: NSXPCConnection? = lock.withLock {
                    pending[id]?.attempt == attempt ? currentConnectionLocked() : nil
                }
                guard let connection else { return }
                let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
                    self?.dropped(id, error)
                } as? DaisyLLMServiceProtocol
                guard let proxy else {
                    resolve(id, .failure(DaisyLLMFailure.serviceUnavailable(detail: "no proxy for \(DaisyLLMWire.serviceName)")))
                    return
                }
                proxy.generate(data) { [weak self] response, failure in
                    self?.replied(id, response, failure)
                }
            }
        } onCancel: {
            cancel(id, attempt: attempt)
        }
    }

    private func cancel(_ id: UUID, attempt: UUID) {
        guard resolve(id, .failure(CancellationError()), onlyFor: attempt) else { return }
        let connection = lock.withLock { self.connection }
        (connection?.remoteObjectProxyWithErrorHandler { _ in } as? DaisyLLMServiceProtocol)?
            .cancel(id.uuidString)
    }

    private func replied(_ id: UUID, _ response: Data?, _ failure: Data?) {
        if let response, let decoded = try? DaisyLLMWire.decode(DaisyLLMResponse.self, from: response) {
            resolve(id, .success(decoded))
        } else if let failure, let decoded = try? DaisyLLMWire.decode(DaisyLLMFailure.self, from: failure) {
            resolve(id, .failure(decoded == .cancelled ? CancellationError() : decoded))
        } else {
            resolve(id, .failure(DaisyLLMFailure.serviceUnavailable(detail: "unreadable reply")))
        }
    }

    /// The message couldn't be delivered, or the helper went away before
    /// replying. Before any progress it never started: worth one more try.
    private func dropped(_ id: UUID, _ error: any Error) {
        let request = lock.withLock { pending[id] }
        guard let request else { return }
        let retry = !request.sawProgress && !request.isRetry
        resolve(id, .failure(retry
            ? DaisyLLMFailure.serviceRestarting
            : DaisyLLMFailure.serviceUnavailable(detail: error.localizedDescription)))
    }

    fileprivate func received(_ event: Data) {
        guard let progress = try? DaisyLLMWire.decode(DaisyLLMProgress.self, from: event) else { return }
        let handler: (@Sendable (DaisyLLMProgress.Stage) -> Void)? = lock.withLock {
            pending[progress.id]?.sawProgress = true
            return pending[progress.id]?.onProgress
        }
        handler?(progress.stage)
    }

    /// Resumes the request's continuation once; false if it already was
    /// (or, with `onlyFor`, if another call registered this id since).
    @discardableResult
    private func resolve(
        _ id: UUID, _ result: Result<DaisyLLMResponse, any Error>, onlyFor attempt: UUID? = nil
    ) -> Bool {
        let request = lock.withLock { () -> Pending? in
            if let attempt, pending[id]?.attempt != attempt { return nil }
            return pending.removeValue(forKey: id)
        }
        guard let request else { return false }
        request.continuation.resume(with: result)
        return true
    }

    /// Call with `lock` held.
    private func currentConnectionLocked() -> NSXPCConnection {
        if let connection { return connection }
        let fresh = makeConnection()
        fresh.remoteObjectInterface = DaisyLLMInterfaces.service()
        fresh.exportedInterface = DaisyLLMInterfaces.progress()
        fresh.exportedObject = ProgressReceiver(client: self)
        let identity = ObjectIdentifier(fresh)
        // Interrupted (the helper exited): the same connection relaunches
        // it on the next message. Invalidated: open a new one next time.
        fresh.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                if let current = self.connection, ObjectIdentifier(current) == identity {
                    self.connection = nil
                }
            }
        }
        fresh.resume()
        connection = fresh
        return fresh
    }
}

nonisolated private final class ProgressReceiver: NSObject, DaisyLLMProgressProtocol, @unchecked Sendable {
    weak var client: DaisyLLMClient?

    init(client: DaisyLLMClient) {
        self.client = client
    }

    func progress(_ event: Data) {
        client?.received(event)
    }
}

extension DaisyLLMFailure: @retroactive LocalizedError {
    nonisolated public var errorDescription: String? {
        switch self {
        case .modelNotFound:
            String(localized: "The Daisy local model isn’t on this Mac yet.")
        case .modelUnreadable:
            String(localized: "Daisy couldn’t read the local model’s files. Download the model again.")
        case .promptTooLong:
            String(localized: "This meeting is too long for the local model on this Mac. Choose a cloud provider for it.")
        case .invalidSchema:
            String(localized: "Daisy asked the local model for a summary format it can’t follow.")
        case .outputIncomplete:
            String(localized: "The local model ran out of room before it finished the summary.")
        case .cancelled:
            String(localized: "The summary was cancelled.")
        case .unsupportedHardware:
            String(localized: "The Daisy local model needs a Mac with Apple silicon.")
        case .protocolMismatch:
            String(localized: "The local model’s helper is from another version of Daisy. Quit Daisy and open it again.")
        case .serviceRestarting, .serviceUnavailable:
            String(localized: "The local model stopped before it finished. Try again.")
        case .engine(let detail):
            String(localized: "The local model failed: \(detail)")
        }
    }
}
