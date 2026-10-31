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
//     to a fresh helper;
//   • a cancelled generation that still hasn't stopped `cancelGrace` later
//     (a GPU hang, a load that can't be interrupted) calls `onStuck`: the
//     helper exits rather than hold the queue — and its memory — forever;
//   • only a peer meeting `peerRequirement` (Daisy, signed by this team)
//     may connect.
//
//  The state lives in an actor of its own, not on the main thread: the
//  helper's main thread only runs XPC, and in the test host the app's main
//  thread can stall for seconds.
//
//  Request ids are per call (the client sends each call and each resend
//  under a fresh id), so a late cancel or a stale reply can only ever meet
//  the call it belongs to.
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

/// The listener's delegate: checks the caller, hands every call to the
/// coordinator.
public final class DaisyLLMService: NSObject, NSXPCListenerDelegate, Sendable {
    private let coordinator: Coordinator
    private let inbox: AsyncStream<Event>.Continuation
    private let peerRequirement: String?
    private let status = Status()

    /// The helper is on its way out (idle or stuck): new requests are told
    /// to start a fresh one.
    public var isExiting: Bool { status.read { $0.isExiting } }
    /// Requests that reached the service, refused ones included (tests, logs).
    public var requestsReceived: Int { status.read { $0.requestsReceived } }
    /// Requests waiting behind the running one (tests, logs).
    public var requestsQueued: Int { status.read { $0.requestsQueued } }

    /// `peerRequirement` defaults to Daisy from this process's team.
    public init(
        backend: any DaisyLLMBackend,
        idleTimeout: Duration = .seconds(60),
        cancelGrace: Duration = .seconds(30),
        peerRequirement: String? = DaisyLLMCodeSigning.requirement(forIdentifier: DaisyLLMCodeSigning.appIdentifier),
        onIdle: @escaping @Sendable () -> Void,
        onStuck: @escaping @Sendable () -> Void
    ) {
        self.peerRequirement = peerRequirement
        let coordinator = Coordinator(
            backend: backend, idleTimeout: idleTimeout, cancelGrace: cancelGrace,
            status: status, onIdle: onIdle, onStuck: onStuck)
        self.coordinator = coordinator
        // Every call goes through one ordered inbox, so requests start in
        // the order XPC delivered them and a cancel sent after its request
        // is handled after it.
        let (events, inbox) = AsyncStream<Event>.makeStream()
        self.inbox = inbox
        Task {
            for await event in events { await coordinator.handle(event) }
        }
    }

    deinit {
        inbox.finish()
    }

    /// Starts the idle clock: a helper launched and never asked anything
    /// leaves too.
    public func start() {
        inbox.yield(.start)
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        if let peerRequirement {
            // XPC checks every message from the caller; a mismatch drops it.
            connection.setCodeSigningRequirement(peerRequirement)
        }
        let handler = ConnectionHandler(inbox: inbox)
        handler.connection = connection
        connection.exportedInterface = DaisyLLMInterfaces.service()
        connection.exportedObject = handler
        connection.remoteObjectInterface = DaisyLLMInterfaces.progress()
        let connectionID = handler.connectionID
        connection.invalidationHandler = { [inbox] in
            inbox.yield(.connectionClosed(connectionID))
        }
        connection.resume()
        return true
    }

    nonisolated static func failure(for error: any Error) -> DaisyLLMFailure {
        if let failure = error as? DaisyLLMFailure { return failure }
        if error is CancellationError { return .cancelled }
        return .engine(detail: String(describing: error))
    }
}

/// What the tests and the delegate read without waiting for the actor.
private final class Status: @unchecked Sendable {
    struct Values {
        var isExiting = false
        var requestsReceived = 0
        var requestsQueued = 0
    }

    private let lock = NSLock()
    private var values = Values()

    func read<T>(_ body: (Values) -> T) -> T { lock.withLock { body(values) } }
    func update(_ body: (inout Values) -> Void) { lock.withLock { body(&values) } }
}

private enum Event: Sendable {
    case start
    case enqueue(Job)
    case cancel(UUID)
    case connectionClosed(UUID)
    case shutdown
}

private struct Job: Sendable {
    let request: DaisyLLMRequest
    let connectionID: UUID
    let reply: @Sendable (Data?, Data?) -> Void
    let progress: @Sendable (DaisyLLMProgress) -> Void
}

private actor Coordinator {
    private let backend: any DaisyLLMBackend
    private let idleTimeout: Duration
    private let cancelGrace: Duration
    private let status: Status
    private let onIdle: @Sendable () -> Void
    private let onStuck: @Sendable () -> Void

    private var waiting: [Job] = []
    private var running: (job: Job, task: Task<Void, Never>)?
    /// A cancel sent on another connection can arrive before its request;
    /// the request then starts cancelled.
    private var cancelledBeforeArrival: [UUID] = []
    /// Likewise a request can arrive after its connection's close.
    private var closedConnections: Set<UUID> = []
    private var idleTask: Task<Void, Never>?
    private var isExiting = false
    /// Asked to leave: exit once the running job has stopped.
    private var exitWhenStopped = false

    init(
        backend: any DaisyLLMBackend, idleTimeout: Duration, cancelGrace: Duration, status: Status,
        onIdle: @escaping @Sendable () -> Void, onStuck: @escaping @Sendable () -> Void
    ) {
        self.backend = backend
        self.idleTimeout = idleTimeout
        self.cancelGrace = cancelGrace
        self.status = status
        self.onIdle = onIdle
        self.onStuck = onStuck
    }

    func handle(_ event: Event) {
        switch event {
        case .start: scheduleIdleExit()
        case .enqueue(let job): enqueue(job)
        case .cancel(let id): cancel(id)
        case .connectionClosed(let id): connectionClosed(id)
        case .shutdown: shutdown()
        }
    }

    private func enqueue(_ job: Job) {
        status.update { $0.requestsReceived += 1 }
        if isExiting || exitWhenStopped {
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
        publishQueue()
    }

    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.request.id == id }) {
            let job = waiting.remove(at: index)
            Self.send(.failure(DaisyLLMFailure.cancelled), to: job)
            publishQueue()
            scheduleIdleExitIfQuiet()
        } else if let running, running.job.request.id == id {
            cancelRunning(running)
        } else {
            // Either its request is still on the way, or it already finished
            // (ids are per call, so a stale entry never matches another call).
            cancelledBeforeArrival.append(id)
            if cancelledBeforeArrival.count > 32 { cancelledBeforeArrival.removeFirst() }
        }
    }

    /// Daisy quit, crashed or dropped the connection: nobody is waiting
    /// for its requests any more.
    private func connectionClosed(_ connectionID: UUID) {
        closedConnections.insert(connectionID)
        let gone = waiting.filter { $0.connectionID == connectionID }
        waiting.removeAll { $0.connectionID == connectionID }
        publishQueue()
        for job in gone { Self.send(.failure(DaisyLLMFailure.cancelled), to: job) }
        if let running, running.job.connectionID == connectionID {
            cancelRunning(running)
        }
        scheduleIdleExitIfQuiet()
    }

    private func shutdown() {
        let queued = waiting
        waiting.removeAll()
        publishQueue()
        for job in queued { Self.send(.failure(DaisyLLMFailure.cancelled), to: job) }
        if let running {
            exitWhenStopped = true
            cancelRunning(running)
        } else if !isExiting {
            markExiting()
            onIdle()
        }
    }

    /// Cancels the running job and gives it `cancelGrace` to stop.
    private func cancelRunning(_ running: (job: Job, task: Task<Void, Never>)) {
        running.task.cancel()
        let id = running.job.request.id
        let grace = cancelGrace
        Task {
            // A sleeping Mac isn't a stuck model: the grace counts awake time.
            try? await Task.sleep(for: grace, clock: .suspending)
            self.stuckCheck(id)
        }
    }

    private func stuckCheck(_ id: UUID) {
        guard running?.job.request.id == id, !isExiting else { return }
        markExiting()
        onStuck()
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
        if exitWhenStopped, !isExiting {
            markExiting()
            onIdle()
            return
        }
        startNext()
        publishQueue()
        scheduleIdleExitIfQuiet()
    }

    private func publishQueue() {
        let count = waiting.count
        status.update { $0.requestsQueued = count }
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
            guard !Task.isCancelled else { return }
            self.idleCheck()
        }
    }

    private func idleCheck() {
        guard running == nil, waiting.isEmpty, !isExiting else { return }
        markExiting()
        onIdle()
    }

    private func markExiting() {
        isExiting = true
        status.update { $0.isExiting = true }
    }

    private static func send(_ result: Result<DaisyLLMResponse, any Error>, to job: Job) {
        switch result {
        case .success(let response):
            if let data = try? DaisyLLMWire.encode(response) {
                job.reply(data, nil)
            } else {
                job.reply(nil, try? DaisyLLMWire.encode(DaisyLLMFailure.engine(detail: "couldn't encode the response")))
            }
        case .failure(let error):
            job.reply(nil, try? DaisyLLMWire.encode(DaisyLLMService.failure(for: error)))
        }
    }
}

/// One per connection; XPC calls it on its own queues and it hands every
/// call to the coordinator's inbox.
private final class ConnectionHandler: NSObject, DaisyLLMServiceProtocol, @unchecked Sendable {
    let inbox: AsyncStream<Event>.Continuation
    let connectionID = UUID()
    weak var connection: NSXPCConnection?

    init(inbox: AsyncStream<Event>.Continuation) {
        self.inbox = inbox
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
        let job = Job(request: request, connectionID: connectionID, reply: reply, progress: { sink.send($0) })
        inbox.yield(.enqueue(job))
    }

    func cancel(_ requestID: String) {
        guard let id = UUID(uuidString: requestID) else { return }
        inbox.yield(.cancel(id))
    }

    func shutdown() {
        inbox.yield(.shutdown)
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
