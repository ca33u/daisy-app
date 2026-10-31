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

    /// One call on the wire. Every call — and its resend — goes out under a
    /// fresh id, so a late reply or a stale cancel only ever meets its own.
    nonisolated private struct Pending {
        let continuation: CheckedContinuation<DaisyLLMResponse, any Error>
        let onProgress: @Sendable (DaisyLLMProgress.Stage) -> Void
        let isRetry: Bool
        var sawProgress = false
    }

    private let makeConnection: @Sendable () -> NSXPCConnection
    private let peerRequirement: String?
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var pending: [UUID: Pending] = [:]

    /// `makeConnection` and `peerRequirement` are for the tests (an
    /// anonymous listener in this process); by default the peer must be
    /// Daisy's helper signed by this process's team.
    init(
        makeConnection: @escaping @Sendable () -> NSXPCConnection = {
            NSXPCConnection(serviceName: DaisyLLMWire.serviceName)
        },
        peerRequirement: String? = DaisyLLMCodeSigning.requirement(forIdentifier: DaisyLLMCodeSigning.helperIdentifier)
    ) {
        self.makeConnection = makeConnection
        self.peerRequirement = peerRequirement
    }

    /// `timeout` bounds the call: past it the helper is told to stop and
    /// this throws `.timedOut` (the caller picks it from the prompt's length,
    /// as the Ollama path does). It counts awake time only — a Mac asleep
    /// with the lid closed isn't a slow model — and starts over once when
    /// the helper starts this call, so a wait behind another summary in the
    /// helper's queue doesn't eat into it. Off the main actor: nothing here
    /// should wait for the UI thread.
    @concurrent
    func generate(
        _ request: DaisyLLMRequest,
        timeout: Duration = .seconds(45 * 60),
        onProgress: @escaping @Sendable (DaisyLLMProgress.Stage) -> Void = { _ in }
    ) async throws -> DaisyLLMResponse {
        guard Self.runsOnThisMac else { throw DaisyLLMFailure.unsupportedHardware }
        let clock = SuspendingClock()
        let deadline = Deadline(clock.now + timeout)
        let started: @Sendable (DaisyLLMProgress.Stage) -> Void = { stage in
            deadline.restartOnce(at: clock.now + timeout)
            onProgress(stage)
        }
        return try await withThrowingTaskGroup(of: DaisyLLMResponse?.self) { group in
            group.addTask { try await self.sendWithResend(request, onProgress: started) }
            group.addTask {
                while clock.now < deadline.instant {
                    try await Task.sleep(until: deadline.instant, clock: clock)
                }
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            guard let response = first else {
                throw DaisyLLMFailure.timedOut(seconds: Int(timeout.components.seconds))
            }
            return response
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

    private func sendWithResend(
        _ request: DaisyLLMRequest,
        onProgress: @escaping @Sendable (DaisyLLMProgress.Stage) -> Void
    ) async throws -> DaisyLLMResponse {
        do {
            return try await attempt(request, onProgress: onProgress, isRetry: false)
        } catch DaisyLLMFailure.serviceRestarting {
            return try await attempt(request, onProgress: onProgress, isRetry: true)
        }
    }

    private func attempt(
        _ request: DaisyLLMRequest,
        onProgress: @escaping @Sendable (DaisyLLMProgress.Stage) -> Void,
        isRetry: Bool
    ) async throws -> DaisyLLMResponse {
        var wire = request
        wire.id = UUID()
        let id = wire.id
        let data = try DaisyLLMWire.encode(wire)
        var response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    pending[id] = Pending(continuation: continuation, onProgress: onProgress, isRetry: isRetry)
                }
                // Cancelled before the handler could see this call.
                if Task.isCancelled {
                    cancel(id)
                    return
                }
                // Still waiting (`invalidate()` may have failed it meanwhile):
                // only then take a connection and send.
                let connection: NSXPCConnection? = lock.withLock {
                    pending[id] == nil ? nil : currentConnectionLocked()
                }
                guard let connection else { return }
                let identity = ObjectIdentifier(connection)
                let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
                    self?.dropped(id, error, connection: identity)
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
            cancel(id)
        }
        response.id = request.id
        return response
    }

    private func cancel(_ id: UUID) {
        guard resolve(id, .failure(CancellationError())) else { return }
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
    /// replying. Before any progress it never started: worth one more try —
    /// on a new connection if this one is dead for good.
    private func dropped(_ id: UUID, _ error: any Error, connection identity: ObjectIdentifier) {
        let nsError = error as NSError
        let request: Pending? = lock.withLock {
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSXPCConnectionInvalid,
               let current = connection, ObjectIdentifier(current) == identity {
                connection = nil
            }
            return pending[id]
        }
        guard let request else { return }
        // A peer failing our signing check also lands here, as a plain
        // invalidation (4099, tested 31.10) that can't be told from a refused
        // connection; such a misbuilt pair runs the request twice, then fails.
        let retry = !request.sawProgress && !request.isRetry
        resolve(id, .failure(retry
            ? DaisyLLMFailure.serviceRestarting
            : DaisyLLMFailure.serviceUnavailable(detail: error.localizedDescription)))
    }

    fileprivate func received(_ event: Data) {
        guard let progress = try? DaisyLLMWire.decode(DaisyLLMProgress.self, from: event) else { return }
        // A call that already replied drops its late progress: NSXPC may run
        // a reply block before progress messages sent just ahead of it.
        let handler: (@Sendable (DaisyLLMProgress.Stage) -> Void)? = lock.withLock {
            pending[progress.id]?.sawProgress = true
            return pending[progress.id]?.onProgress
        }
        handler?(progress.stage)
    }

    /// Resumes the call's continuation once; false if it already was.
    @discardableResult
    private func resolve(_ id: UUID, _ result: Result<DaisyLLMResponse, any Error>) -> Bool {
        guard let request = lock.withLock({ pending.removeValue(forKey: id) }) else { return false }
        request.continuation.resume(with: result)
        return true
    }

    /// Call with `lock` held.
    private func currentConnectionLocked() -> NSXPCConnection {
        if let connection { return connection }
        let fresh = makeConnection()
        if let peerRequirement {
            // XPC checks every message from the peer and drops the connection
            // on a mismatch. It guards the answers, not the request: that is
            // the helper's own check of Daisy. A service connection can only
            // reach the helper inside this signed bundle anyway.
            fresh.setCodeSigningRequirement(peerRequirement)
        }
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

/// When a call's time runs out; moved once, when the helper starts it.
nonisolated private final class Deadline: @unchecked Sendable {
    private let lock = NSLock()
    private var at: SuspendingClock.Instant
    private var restarted = false

    init(_ at: SuspendingClock.Instant) {
        self.at = at
    }

    var instant: SuspendingClock.Instant { lock.withLock { at } }

    func restartOnce(at new: SuspendingClock.Instant) {
        lock.withLock {
            guard !restarted else { return }
            restarted = true
            at = new
        }
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
            String(localized: "This meeting is too long for the local model on this Mac. Choose another provider for it.")
        case .invalidSchema:
            String(localized: "Daisy asked the local model for a summary format it can’t follow.")
        case .outputIncomplete:
            String(localized: "The summary didn’t fit in the local model’s answer length limit.")
        case .cancelled:
            String(localized: "The summary was cancelled.")
        case .unsupportedHardware:
            String(localized: "The Daisy local model needs a Mac with Apple silicon.")
        case .protocolMismatch:
            String(localized: "The local model’s helper is from another version of Daisy. Quit Daisy and open it again.")
        case .timedOut(let seconds):
            String(localized: "The local model didn’t finish in \(max(1, seconds / 60)) min — on this Mac it’s too slow for a meeting this long. Choose another provider for it.")
        case .serviceRestarting, .serviceUnavailable:
            String(localized: "The local model stopped before it finished. Try again.")
        case .engine(let detail):
            String(localized: "The local model failed: \(detail)")
        }
    }
}
