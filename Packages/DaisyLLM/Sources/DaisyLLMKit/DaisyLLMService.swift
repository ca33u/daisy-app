//
//  DaisyLLMService.swift
//  DaisyLLMKit
//
//  The helper's side of the XPC connection, with the model behind a
//  protocol: DaisyLLM.xpc gives it the MLX backend, the tests a scripted
//  one. What it guarantees, whatever the backend:
//   • one generation at a time (a model is 4–7 GB; two would double it),
//     the rest wait in order;
//   • cancel from Daisy, or Daisy going away, cancels the task running the
//     model — the backend stops between tokens or prompt chunks — and a
//     queued request never starts;
//   • every request replies exactly once;
//   • after `idleTimeout` with nothing running or queued it calls `onIdle`
//     (the helper exits, so the model's memory goes back whole, not
//     whatever MLX's cache gives back). A request that arrives while it
//     is exiting gets `.serviceRestarting` and the client sends it again
//     to a fresh helper.
//

import Foundation

/// Runs one request to the end. Throws `DaisyLLMFailure`,
/// `CancellationError` once the task is cancelled, or anything else
/// (sent as `.engine` with its description).
public protocol DaisyLLMBackend: Sendable {
    func run(
        _ request: DaisyLLMRequest,
        progress: @escaping @Sendable (DaisyLLMProgress.Stage) -> Void
    ) async throws -> DaisyLLMResponse
}

@MainActor
public final class DaisyLLMService: NSObject {
    fileprivate struct Job: Sendable {
        let request: DaisyLLMRequest
        let connectionID: UUID
        let reply: @Sendable (Data?, Data?) -> Void
        let progress: @Sendable (DaisyLLMProgress) -> Void
    }

    private let backend: any DaisyLLMBackend
    private let idleTimeout: Duration
    private let onIdle: @MainActor () -> Void

    private var waiting: [Job] = []
    private var running: (job: Job, task: Task<Void, Never>)?
    /// A cancel can reach the main actor before its own request does (they
    /// come from different XPC threads); the request then starts cancelled.
    private var cancelledBeforeArrival: [UUID] = []
    /// Likewise a request can arrive after its connection's close.
    private var closedConnections: Set<UUID> = []
    private var idleTask: Task<Void, Never>?
    public private(set) var isExiting = false

    public init(
        backend: any DaisyLLMBackend,
        idleTimeout: Duration = .seconds(60),
        onIdle: @escaping @MainActor () -> Void
    ) {
        self.backend = backend
        self.idleTimeout = idleTimeout
        self.onIdle = onIdle
    }

    /// Starts the idle clock: a helper launched and never asked anything
    /// leaves too.
    public func start() {
        scheduleIdleExit()
    }

    fileprivate func enqueue(_ job: Job) {
        if isExiting {
            Self.send(.failure(DaisyLLMFailure.serviceRestarting), to: job)
            return
        }
        if closedConnections.contains(job.connectionID) {
            Self.send(.failure(DaisyLLMFailure.cancelled), to: job)
            return
        }
        if let index = cancelledBeforeArrival.firstIndex(of: job.request.id) {
            cancelledBeforeArrival.remove(at: index)
            Self.send(.failure(DaisyLLMFailure.cancelled), to: job)
            return
        }
        idleTask?.cancel()
        idleTask = nil
        waiting.append(job)
        startNext()
    }

    fileprivate func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.request.id == id }) {
            let job = waiting.remove(at: index)
            Self.send(.failure(DaisyLLMFailure.cancelled), to: job)
            scheduleIdleExitIfQuiet()
        } else if let running, running.job.request.id == id {
            running.task.cancel()
        } else {
            cancelledBeforeArrival.append(id)
            if cancelledBeforeArrival.count > 32 { cancelledBeforeArrival.removeFirst() }
        }
    }

    /// Daisy quit, crashed or dropped the connection: nobody is waiting
    /// for its requests any more.
    fileprivate func connectionClosed(_ connectionID: UUID) {
        closedConnections.insert(connectionID)
        let gone = waiting.filter { $0.connectionID == connectionID }
        waiting.removeAll { $0.connectionID == connectionID }
        for job in gone { Self.send(.failure(DaisyLLMFailure.cancelled), to: job) }
        if let running, running.job.connectionID == connectionID {
            running.task.cancel()
        }
        scheduleIdleExitIfQuiet()
    }

    private func startNext() {
        guard running == nil, !waiting.isEmpty else { return }
        let job = waiting.removeFirst()
        let backend = backend
        let task = Task {
            let result: Result<DaisyLLMResponse, any Error>
            do {
                let response = try await backend.run(job.request) { stage in
                    job.progress(DaisyLLMProgress(id: job.request.id, stage: stage))
                }
                result = .success(response)
            } catch {
                result = .failure(error)
            }
            self.finish(job, result)
        }
        running = (job, task)
    }

    private func finish(_ job: Job, _ result: Result<DaisyLLMResponse, any Error>) {
        Self.send(result, to: job)
        running = nil
        startNext()
        scheduleIdleExitIfQuiet()
    }

    private func scheduleIdleExitIfQuiet() {
        guard running == nil, waiting.isEmpty else { return }
        scheduleIdleExit()
    }

    private func scheduleIdleExit() {
        idleTask?.cancel()
        let timeout = idleTimeout
        idleTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, self.running == nil, self.waiting.isEmpty, !self.isExiting else { return }
            self.isExiting = true
            self.onIdle()
        }
    }

    nonisolated static func failure(for error: any Error) -> DaisyLLMFailure {
        if let failure = error as? DaisyLLMFailure { return failure }
        if error is CancellationError { return .cancelled }
        return .engine(detail: String(describing: error))
    }

    private nonisolated static func send(_ result: Result<DaisyLLMResponse, any Error>, to job: Job) {
        switch result {
        case .success(let response):
            if let data = try? DaisyLLMWire.encode(response) {
                job.reply(data, nil)
            } else {
                job.reply(nil, try? DaisyLLMWire.encode(DaisyLLMFailure.engine(detail: "couldn't encode the response")))
            }
        case .failure(let error):
            job.reply(nil, try? DaisyLLMWire.encode(failure(for: error)))
        }
    }
}

extension DaisyLLMService: NSXPCListenerDelegate {
    nonisolated public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let handler = ConnectionHandler(service: self)
        handler.connection = connection
        connection.exportedInterface = DaisyLLMInterfaces.service()
        connection.exportedObject = handler
        connection.remoteObjectInterface = DaisyLLMInterfaces.progress()
        let connectionID = handler.connectionID
        connection.invalidationHandler = { [service = self] in
            Task { @MainActor in service.connectionClosed(connectionID) }
        }
        connection.resume()
        return true
    }
}

/// One per connection; XPC calls it on its own queues and it hands every
/// call to the service on the main actor.
private final class ConnectionHandler: NSObject, DaisyLLMServiceProtocol, @unchecked Sendable {
    let service: DaisyLLMService
    let connectionID = UUID()
    weak var connection: NSXPCConnection?

    init(service: DaisyLLMService) {
        self.service = service
    }

    func generate(_ requestData: Data, reply: @escaping @Sendable (Data?, Data?) -> Void) {
        let request: DaisyLLMRequest
        do {
            request = try Self.decode(requestData)
        } catch let failure as DaisyLLMFailure {
            reply(nil, try? DaisyLLMWire.encode(failure))
            return
        } catch {
            reply(nil, try? DaisyLLMWire.encode(DaisyLLMFailure.engine(detail: "unreadable request: \(error)")))
            return
        }
        let sink = ProgressSink(connection?.remoteObjectProxyWithErrorHandler { _ in } as? DaisyLLMProgressProtocol)
        let job = DaisyLLMService.Job(
            request: request, connectionID: connectionID, reply: reply,
            progress: { sink.send($0) })
        Task { @MainActor [service] in service.enqueue(job) }
    }

    func cancel(_ requestID: String) {
        guard let id = UUID(uuidString: requestID) else { return }
        Task { @MainActor [service] in service.cancel(id) }
    }

    /// A request from another Daisy build is named as such, not as garbage.
    private static func decode(_ data: Data) throws -> DaisyLLMRequest {
        struct Version: Decodable { let protocolVersion: Int }
        if let version = try? DaisyLLMWire.decode(Version.self, from: data),
           version.protocolVersion != DaisyLLMWire.protocolVersion {
            throw DaisyLLMFailure.protocolMismatch(
                service: DaisyLLMWire.protocolVersion, client: version.protocolVersion)
        }
        return try DaisyLLMWire.decode(DaisyLLMRequest.self, from: data)
    }
}

/// The remote progress proxy is thread-safe; this only carries it across.
private final class ProgressSink: @unchecked Sendable {
    private let proxy: (any DaisyLLMProgressProtocol)?

    init(_ proxy: (any DaisyLLMProgressProtocol)?) {
        self.proxy = proxy
    }

    func send(_ progress: DaisyLLMProgress) {
        guard let proxy, let data = try? DaisyLLMWire.encode(progress) else { return }
        proxy.progress(data)
    }
}
