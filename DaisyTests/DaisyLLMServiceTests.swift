//
//  DaisyLLMServiceTests.swift
//  DaisyTests
//
//  «Локальная модель Daisy», Л-1: the client and the helper's service core
//  over a real NSXPC connection (an anonymous listener in this process),
//  with a scripted model in place of MLX — the wire protocol, progress,
//  one-at-a-time, cancellation, the watchdog, exit on idle, resends, the
//  code-signing check and the errors in words. The real model is checked
//  by hand (`Daisy --daisy-llm-smoke`).
//

import Foundation
import Testing
import DaisyLLMKit
@testable import Daisy

/// Stands in for the MLX backend: says what it is told to, reports the
/// progress a real run would, and records what happened to it by prompt
/// (ids on the wire are per call, not the caller's).
private final class ScriptedLLM: DaisyLLMBackend, @unchecked Sendable {
    enum Step: Sendable {
        case reply(String)
        case replyAfter(Duration, String)
        case fail(any Error)
        /// Runs until cancelled.
        case hang
        /// Ignores its cancel for this long (a stuck GPU), then replies.
        case stubborn(Duration)
    }

    private let lock = NSLock()
    private let script: @Sendable (DaisyLLMRequest) -> Step
    private var _started: [String] = []
    private var _running = 0
    private var _mostAtOnce = 0
    private var _cancelled: [String] = []
    private var _finishedAt: [ContinuousClock.Instant] = []

    init(_ script: @escaping @Sendable (DaisyLLMRequest) -> Step) {
        self.script = script
    }

    var started: [String] { lock.withLock { _started } }
    var mostAtOnce: Int { lock.withLock { _mostAtOnce } }
    var cancelled: [String] { lock.withLock { _cancelled } }
    var finishedAt: [ContinuousClock.Instant] { lock.withLock { _finishedAt } }

    func run(
        _ request: DaisyLLMRequest,
        progress: @escaping @Sendable (DaisyLLMProgress.Stage) -> Void
    ) async throws -> DaisyLLMResponse {
        lock.withLock {
            _started.append(request.userPrompt)
            _running += 1
            _mostAtOnce = max(_mostAtOnce, _running)
        }
        defer { lock.withLock { _running -= 1 } }
        progress(.loadingModel)
        progress(.reading(processed: 2048, total: 4000))
        progress(.reading(processed: 4000, total: 4000))
        let text: String
        do {
            switch script(request) {
            case .reply(let reply):
                text = reply
            case .replyAfter(let delay, let reply):
                try await Task.sleep(for: delay)
                text = reply
            case .fail(let error):
                throw error
            case .hang:
                while true { try await Task.sleep(for: .milliseconds(5)) }
            case .stubborn(let delay):
                // Deaf to the cancel, and not spinning while it waits.
                let nanoseconds = UInt64(delay.components.seconds) * 1_000_000_000
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
                        continuation.resume()
                    }
                }
                text = "late"
            }
        } catch is CancellationError {
            lock.withLock { _cancelled.append(request.userPrompt) }
            throw CancellationError()
        }
        progress(.writing(tokens: 16))
        lock.withLock { _finishedAt.append(.now) }
        return DaisyLLMResponse(
            id: request.id, text: text, promptTokens: 4000, outputTokens: 16,
            loadSeconds: 1.5, promptSeconds: 20, generateSeconds: 0.8,
            peakMemoryBytes: 3_800_000_000, language: request.language)
    }
}

private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Value] = []
    var values: [Value] { lock.withLock { _values } }
    func add(_ value: Value) { lock.withLock { _values.append(value) } }
}

/// Sits between the listener and the service: can turn the first
/// connection away (a helper that died before answering) and cut every
/// accepted one (a helper killed mid-request).
private final class Tap: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let service: DaisyLLMService
    let refuseFirst: Bool
    private let lock = NSLock()
    private var accepted: [NSXPCConnection] = []
    private var offered = 0

    init(service: DaisyLLMService, refuseFirst: Bool) {
        self.service = service
        self.refuseFirst = refuseFirst
    }

    var connectionsOffered: Int { lock.withLock { offered } }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let n = lock.withLock { offered += 1; return offered }
        if refuseFirst, n == 1 { return false }
        let ok = service.listener(listener, shouldAcceptNewConnection: connection)
        lock.withLock { accepted.append(connection) }
        return ok
    }

    func cutEveryConnection() {
        for connection in lock.withLock({ accepted }) { connection.invalidate() }
    }
}

/// The helper's service behind an anonymous listener, and a client on it.
/// Nothing here waits for the main thread, which in the test host is the
/// app's and stalled for 20–40 s in full-suite runs (31.10).
private final class Helper: @unchecked Sendable {
    let backend: ScriptedLLM
    let service: DaisyLLMService
    let tap: Tap
    let listener = NSXPCListener.anonymous()
    let client: DaisyLLMClient
    let idleExits = Recorder<ContinuousClock.Instant>()
    let stuckExits = Recorder<ContinuousClock.Instant>()

    /// `startIdleClock: false` leaves the clock to the first request's end,
    /// so a slow machine can't run it out before the request arrives.
    /// The "helper" here is this process (Daisy), so the client's peer
    /// requirement names Daisy, not DaisyLLM.
    init(
        idleTimeout: Duration = .seconds(30), startIdleClock: Bool = true, cancelGrace: Duration = .seconds(30),
        refuseFirstConnection: Bool = false,
        serviceRequirement: String? = DaisyLLMCodeSigning.requirement(forIdentifier: DaisyLLMCodeSigning.appIdentifier),
        clientRequirement: String? = DaisyLLMCodeSigning.requirement(forIdentifier: DaisyLLMCodeSigning.appIdentifier),
        _ script: @escaping @Sendable (DaisyLLMRequest) -> ScriptedLLM.Step
    ) {
        backend = ScriptedLLM(script)
        let idleExits = idleExits
        let stuckExits = stuckExits
        service = DaisyLLMService(
            backend: backend, idleTimeout: idleTimeout, cancelGrace: cancelGrace,
            peerRequirement: serviceRequirement, onIdle: { idleExits.add(.now) }, onStuck: { stuckExits.add(.now) })
        tap = Tap(service: service, refuseFirst: refuseFirstConnection)
        listener.delegate = tap
        listener.resume()
        if startIdleClock { service.start() }
        nonisolated(unsafe) let endpoint = listener.endpoint
        client = DaisyLLMClient(
            makeConnection: { NSXPCConnection(listenerEndpoint: endpoint) },
            peerRequirement: clientRequirement)
    }

    /// A connection of its own, for messages the client would never send.
    func rawProxy(_ onError: @escaping @Sendable () -> Void) -> (NSXPCConnection, (any DaisyLLMServiceProtocol)?) {
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = DaisyLLMInterfaces.service()
        connection.resume()
        return (connection, connection.remoteObjectProxyWithErrorHandler { _ in onError() } as? DaisyLLMServiceProtocol)
    }

    func close() {
        client.invalidate()
        listener.invalidate()
    }
}

private func request(_ text: String = "transcript") -> DaisyLLMRequest {
    DaisyLLMRequest(
        modelDirectory: "/models/qwen35-4b-4bit", systemPrompt: "system", userPrompt: text,
        language: "ru", jsonSchema: "{}", limits: DaisyLLMLimits(maxOutputTokens: 512))
}

/// Polls until `condition` holds or `timeout` passes; a passing run
/// returns at once.
private func eventually(_ timeout: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// Sends raw `data` and returns the failure the helper replies with (nil
/// if it answered with a response, or the message never got through).
private func rawFailure(_ helper: Helper, sending data: Data) async throws -> DaisyLLMFailure? {
    let failure: Data? = await withCheckedContinuation { continuation in
        // NSXPC runs one of the two for a message with a reply; the guard
        // only makes that a certainty here.
        let once = Recorder<Bool>()
        let finish: @Sendable (Data?) -> Void = { data in
            guard once.values.isEmpty else { return }
            once.add(true)
            continuation.resume(returning: data)
        }
        let (connection, proxy) = helper.rawProxy { finish(nil) }
        guard let proxy else { connection.invalidate(); return finish(nil) }
        proxy.generate(data) { _, failure in
            finish(failure)
            connection.invalidate()
        }
    }
    return try failure.map { try DaisyLLMWire.decode(DaisyLLMFailure.self, from: $0) }
}

private let allFailures: [DaisyLLMFailure] = [
    .modelNotFound(path: "/m"), .modelUnreadable(detail: "d"), .promptTooLong(tokens: 2, limit: 1),
    .invalidSchema(detail: "d"), .outputIncomplete(tokens: 4096), .cancelled, .unsupportedHardware,
    .protocolMismatch(service: 1, client: 2), .serviceRestarting, .serviceUnavailable(detail: "d"),
    .timedOut(seconds: 1800), .memoryPressure, .engine(detail: "Metal"),
]

// The client never launches the helper on an Intel Mac or under Rosetta.
@Suite(.enabled(if: DaisyLLMClient.runsOnThisMac), .timeLimit(.minutes(1)))
struct DaisyLLMServiceTests {
    @Test func everyMessageSurvivesTheWire() throws {
        let original = DaisyLLMRequest(
            modelDirectory: "/m", systemPrompt: "s", userPrompt: "u", language: "en", jsonSchema: "{\"type\":\"object\"}",
            limits: DaisyLLMLimits(maxOutputTokens: 100, maxPromptTokens: 9000, prefillStepSize: 512, memoryLimitBytes: 6_000_000_000))
        #expect(try DaisyLLMWire.decode(DaisyLLMRequest.self, from: DaisyLLMWire.encode(original)) == original)
        #expect(original.protocolVersion == DaisyLLMWire.protocolVersion)

        let progress = DaisyLLMProgress(id: original.id, stage: .reading(processed: 3, total: 7))
        #expect(try DaisyLLMWire.decode(DaisyLLMProgress.self, from: DaisyLLMWire.encode(progress)) == progress)

        for failure in allFailures {
            #expect(try DaisyLLMWire.decode(DaisyLLMFailure.self, from: DaisyLLMWire.encode(failure)) == failure)
        }
    }

    @Test func theAnswerComesBackWithItsNumbersUnderTheCallersID() async throws {
        let helper = Helper { _ in .reply("{\"title\":\"Встреча\"}") }
        defer { helper.close() }
        let sent = request()

        let response = try await helper.client.generate(sent)

        #expect(response.id == sent.id)
        #expect(response.text == "{\"title\":\"Встреча\"}")
        #expect(response.promptTokens == 4000)
        #expect(response.outputTokens == 16)
        #expect(response.loadSeconds == 1.5)
        #expect(response.language == "ru")
    }

    /// Checked on a request still running: NSXPC may run a reply block
    /// before progress messages sent just ahead of it, and progress for a
    /// request that already finished is dropped.
    @Test func progressArrivesInOrderWhileItRuns() async throws {
        let helper = Helper { _ in .hang }
        defer { helper.close() }
        let stages = Recorder<DaisyLLMProgress.Stage>()
        let task = Task { try await helper.client.generate(request()) { stages.add($0) } }
        let expected: [DaisyLLMProgress.Stage] = [
            .loadingModel, .reading(processed: 2048, total: 4000), .reading(processed: 4000, total: 4000),
        ]
        #expect(await eventually { stages.values == expected }, "\(stages.values)")
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func theHelpersFailureArrivesAsItWasSent() async {
        let helper = Helper { _ in .fail(DaisyLLMFailure.promptTooLong(tokens: 300_000, limit: 120_000)) }
        defer { helper.close() }
        await #expect(throws: DaisyLLMFailure.promptTooLong(tokens: 300_000, limit: 120_000)) {
            try await helper.client.generate(request())
        }
    }

    @Test func anythingElseTheEngineThrowsKeepsItsDescription() async {
        struct MetalTrouble: Error, CustomStringConvertible { var description: String { "Metal command buffer failed" } }
        let helper = Helper { _ in .fail(MetalTrouble()) }
        defer { helper.close() }
        await #expect(throws: DaisyLLMFailure.engine(detail: "Metal command buffer failed")) {
            try await helper.client.generate(request())
        }
    }

    @Test func cancellingTheCallerStopsTheModel() async throws {
        let helper = Helper { request in request.userPrompt == "long" ? .hang : .reply("ok") }
        defer { helper.close() }
        let task = Task { try await helper.client.generate(request("long")) }
        #expect(await eventually { helper.backend.started == ["long"] })

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await eventually { helper.backend.cancelled == ["long"] })
        // The helper is free again.
        #expect(try await helper.client.generate(request("short")).text == "ok")
    }

    @Test func aQueuedRequestThatIsCancelledNeverStarts() async throws {
        let helper = Helper { request in request.userPrompt == "first" ? .hang : .reply("second") }
        defer { helper.close() }
        let firstTask = Task { try await helper.client.generate(request("first")) }
        #expect(await eventually { helper.backend.started == ["first"] })
        let secondTask = Task { try await helper.client.generate(request("second")) }
        #expect(await eventually { helper.service.requestsReceived == 2 })

        secondTask.cancel()
        await #expect(throws: CancellationError.self) { try await secondTask.value }
        firstTask.cancel()
        await #expect(throws: CancellationError.self) { try await firstTask.value }

        #expect(await eventually { helper.backend.cancelled == ["first"] })
        #expect(helper.backend.started == ["first"])
    }

    @Test func oneGenerationAtATime() async throws {
        let helper = Helper { request in .replyAfter(.milliseconds(60), request.userPrompt) }
        defer { helper.close() }
        let client = helper.client
        let texts = try await withThrowingTaskGroup(of: String.self) { group in
            for n in 1...3 {
                group.addTask { try await client.generate(request("meeting \(n)")).text }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(texts) == ["meeting 1", "meeting 2", "meeting 3"])
        #expect(helper.backend.mostAtOnce == 1)
    }

    /// Each call goes out under its own id, so the same request sent twice
    /// at once is simply two calls, each answered.
    @Test func theSameRequestTwiceIsTwoCalls() async throws {
        let helper = Helper { _ in .replyAfter(.milliseconds(100), "ok") }
        defer { helper.close() }
        let sent = request("same")
        let client = helper.client
        async let first = client.generate(sent)
        async let second = client.generate(sent)
        let answers = try await [first, second]
        #expect(answers.map(\.id) == [sent.id, sent.id])
        #expect(helper.backend.started == ["same", "same"])
    }

    @Test func itLeavesOnlyAfterTheLastRequestGoesQuiet() async throws {
        let helper = Helper(idleTimeout: .milliseconds(300), startIdleClock: false) { _ in
            .replyAfter(.milliseconds(600), "ok")
        }
        defer { helper.close() }
        _ = try await helper.client.generate(request())
        #expect(await eventually { helper.idleExits.values.count == 1 })
        // Not while it ran (600 ms, twice the timeout): a full timeout after.
        let finished = try #require(helper.backend.finishedAt.last)
        let left = try #require(helper.idleExits.values.first)
        #expect(left - finished >= .milliseconds(290), "\(left - finished)")
        #expect(helper.service.isExiting)
    }

    @Test func aHelperNeverAskedAnythingLeavesToo() async {
        let helper = Helper(idleTimeout: .milliseconds(100)) { _ in .reply("ok") }
        defer { helper.close() }
        #expect(await eventually { helper.idleExits.values.count == 1 })
    }

    @Test func aRequestMeetingTheExitIsSentOnceMore() async {
        let helper = Helper(idleTimeout: .milliseconds(50)) { _ in .reply("ok") }
        defer { helper.close() }
        #expect(await eventually { helper.service.isExiting })
        // This in-process helper never actually exits, so the resend meets
        // the same answer — and there is exactly one resend.
        await #expect(throws: DaisyLLMFailure.serviceRestarting) {
            try await helper.client.generate(request())
        }
        #expect(helper.service.requestsReceived == 2)
        #expect(helper.backend.started.isEmpty)
    }

    @Test func aHelperThatDiedBeforeAnsweringIsAskedAgain() async throws {
        let helper = Helper(refuseFirstConnection: true) { _ in .reply("second time") }
        defer { helper.close() }
        #expect(try await helper.client.generate(request()).text == "second time")
        #expect(helper.tap.connectionsOffered == 2)
        #expect(helper.backend.started.count == 1)
    }

    @Test func aHelperKilledMidRequestIsUnavailableNotRetried() async throws {
        let helper = Helper { _ in .hang }
        defer { helper.close() }
        let stages = Recorder<DaisyLLMProgress.Stage>()
        let task = Task { try await helper.client.generate(request("killed")) { stages.add($0) } }
        #expect(await eventually { helper.backend.started == ["killed"] && !stages.values.isEmpty })

        helper.tap.cutEveryConnection()

        do {
            _ = try await task.value
            Issue.record("the request outlived its helper")
        } catch DaisyLLMFailure.serviceUnavailable {
        }
        #expect(helper.backend.started == ["killed"])
        #expect(await eventually { helper.backend.cancelled == ["killed"] })
    }

    @Test func daisyGoingAwayCancelsItsRequest() async throws {
        let helper = Helper { _ in .hang }
        defer { helper.close() }
        let stages = Recorder<DaisyLLMProgress.Stage>()
        let task = Task { try await helper.client.generate(request("gone")) { stages.add($0) } }
        #expect(await eventually { helper.backend.started == ["gone"] && !stages.values.isEmpty })

        helper.client.invalidate()

        do {
            _ = try await task.value
            Issue.record("the request went on without its connection")
        } catch DaisyLLMFailure.serviceUnavailable {
        }
        #expect(await eventually { helper.backend.cancelled == ["gone"] })
    }

    @Test func aQueuedRequestWhoseConnectionClosesNeverRuns() async throws {
        let helper = Helper { request in request.userPrompt == "first" ? .hang : .reply("orphan") }
        defer { helper.close() }
        let firstTask = Task { try await helper.client.generate(request("first")) }
        #expect(await eventually { helper.backend.started == ["first"] })
        let (connection, proxy) = helper.rawProxy {}
        proxy?.generate(try DaisyLLMWire.encode(request("orphan"))) { _, _ in }
        #expect(await eventually { helper.service.requestsReceived == 2 })

        #expect(await eventually { helper.service.requestsQueued == 1 })

        connection.invalidate()
        #expect(await eventually { helper.service.requestsQueued == 0 })
        firstTask.cancel()
        await #expect(throws: CancellationError.self) { try await firstTask.value }

        try await Task.sleep(for: .milliseconds(200))
        #expect(helper.backend.started == ["first"])
    }

    @Test func aCancelThatArrivesBeforeItsRequestStillCancelsIt() async throws {
        let helper = Helper { _ in .hang }
        defer { helper.close() }
        let sent = request("early cancel")
        let (connection, proxy) = helper.rawProxy {}
        defer { connection.invalidate() }
        proxy?.cancel(sent.id.uuidString)
        try await Task.sleep(for: .milliseconds(100))

        let failure = try await rawFailure(helper, sending: try DaisyLLMWire.encode(sent))

        #expect(failure == .cancelled)
        #expect(helper.backend.started.isEmpty)
    }

    @Test func garbageIsAnsweredInWordsNotIgnored() async throws {
        let helper = Helper { _ in .reply("ok") }
        defer { helper.close() }
        let failure = try await rawFailure(helper, sending: Data("not json".utf8))
        guard case .engine(let detail) = failure else {
            Issue.record("\(String(describing: failure))")
            return
        }
        #expect(detail.hasPrefix("unreadable request"))
    }

    @Test func aRequestFromAnotherDaisyBuildIsNamedAsSuch() async throws {
        let helper = Helper { _ in .reply("ok") }
        defer { helper.close() }
        var sent = request()
        sent.protocolVersion = 99
        let failure = try await rawFailure(helper, sending: try DaisyLLMWire.encode(sent))
        #expect(failure == .protocolMismatch(service: DaisyLLMWire.protocolVersion, client: 99))
        #expect(helper.backend.started.isEmpty)
    }

    @Test func aRequestPastItsTimeLimitIsStopped() async throws {
        let helper = Helper { _ in .hang }
        defer { helper.close() }
        await #expect(throws: DaisyLLMFailure.timedOut(seconds: 0)) {
            try await helper.client.generate(request("slow"), timeout: .milliseconds(300))
        }
        #expect(await eventually { helper.backend.cancelled == ["slow"] })
    }

    @Test func aGenerationThatIgnoresItsCancelEndsTheHelper() async throws {
        // Far longer than any stall, so the cancel always meets it running.
        let helper = Helper(cancelGrace: .milliseconds(200)) { _ in .stubborn(.seconds(15)) }
        defer { helper.close() }
        let task = Task { try await helper.client.generate(request("stuck")) }
        #expect(await eventually { helper.backend.started == ["stuck"] })

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await eventually { helper.stuckExits.values.count == 1 })
        #expect(helper.service.isExiting)
    }

    /// The check that matters: the helper runs nothing for a caller that
    /// isn't Daisy signed by this team.
    @Test func theHelperRefusesACallerFailingTheSigningCheck() async throws {
        let helper = Helper(serviceRequirement: #"identifier "app.example.impostor""#) { _ in .reply("ok") }
        defer { helper.close() }
        do {
            _ = try await helper.client.generate(request())
            Issue.record("the helper answered a caller that failed the signing check")
        } catch DaisyLLMFailure.serviceUnavailable {
        }
        #expect(helper.backend.started.isEmpty)
    }

    /// XPC checks what comes back, so Daisy refuses the answer of a peer
    /// that isn't its helper (the request itself does reach it — for the
    /// real service that peer can only be the helper inside Daisy's own
    /// signed bundle).
    @Test func daisyRefusesTheAnswerOfAPeerFailingTheSigningCheck() async throws {
        let helper = Helper(clientRequirement: #"identifier "app.example.impostor""#) { _ in .reply("ok") }
        defer { helper.close() }
        do {
            _ = try await helper.client.generate(request())
            Issue.record("took an answer from a peer that failed the signing check")
        } catch DaisyLLMFailure.serviceUnavailable {
        }
        // XPC reports it as a plain invalidation, so it is sent once more
        // (a refused connection looks the same) — and no more than that.
        try await Task.sleep(for: .milliseconds(300))
        #expect(helper.backend.started.count <= 2)
    }

    @Test func underMemoryPressureTheHelperStopsAndLeaves() async throws {
        let helper = Helper { _ in .hang }
        defer { helper.close() }
        let task = Task { try await helper.client.generate(request("big")) }
        #expect(await eventually { helper.backend.started == ["big"] })

        helper.client.releaseUnderMemoryPressure()

        await #expect(throws: DaisyLLMFailure.memoryPressure) { try await task.value }
        #expect(await eventually { helper.backend.cancelled == ["big"] })
        #expect(await eventually { helper.idleExits.values.count == 1 })
        #expect(helper.service.isExiting)
    }

    /// A request arriving while the helper stops for memory is told to go
    /// to a fresh helper, not left waiting in a queue nobody will run.
    @Test func aRequestDuringAShutdownIsSentElsewhere() async throws {
        let helper = Helper(cancelGrace: .seconds(30)) { request in request.userPrompt == "big" ? .stubborn(.seconds(2)) : .reply("ok") }
        defer { helper.close() }
        let big = Task { try await helper.client.generate(request("big")) }
        #expect(await eventually { helper.backend.started == ["big"] })
        let (connection, proxy) = helper.rawProxy {}
        defer { connection.invalidate() }
        proxy?.shutdown()
        try await Task.sleep(for: .milliseconds(200))

        let failure = try await rawFailure(helper, sending: try DaisyLLMWire.encode(request("late")))

        #expect(failure == .serviceRestarting)
        #expect(!helper.backend.started.contains("late"))
        _ = try? await big.value
    }

    /// Just after an answer the model is still loaded: memory pressure
    /// sends that helper away too.
    @Test func memoryPressureJustAfterAnAnswerStillSendsTheHelperAway() async throws {
        let helper = Helper { _ in .reply("ok") }
        defer { helper.close() }
        _ = try await helper.client.generate(request())
        helper.client.releaseUnderMemoryPressure()
        #expect(await eventually { helper.idleExits.values.count == 1 })
    }

    /// Never asked anything: no message that would only launch a helper.
    @Test func memoryPressureWithoutAHelperSendsNothing() async throws {
        let helper = Helper { _ in .reply("ok") }
        defer { helper.close() }
        helper.client.releaseUnderMemoryPressure()
        try await Task.sleep(for: .milliseconds(200))
        #expect(helper.service.requestsReceived == 0)
        #expect(helper.idleExits.values.isEmpty)
    }

    @Test func aShutdownWithNothingRunningLeavesAtOnce() async throws {
        let helper = Helper { _ in .reply("ok") }
        defer { helper.close() }
        let (connection, proxy) = helper.rawProxy {}
        defer { connection.invalidate() }
        proxy?.shutdown()
        #expect(await eventually { helper.idleExits.values.count == 1 })
        #expect(helper.stuckExits.values.isEmpty)
    }

    @Test func theLocalModelSchemaIsTheSameShapeTwoLevelsDeep() throws {
        let schema = try #require(JSONSerialization.jsonObject(with: Data(MeetingSummaryJSONSchema.localModelJSON.utf8)) as? [String: Any])
        let defs = try #require(schema["$defs"] as? [String: Any])
        let bullet = try #require(defs["bullet"] as? [String: Any])
        let children = try #require((bullet["properties"] as? [String: Any])?["children"] as? [String: Any])
        #expect((children["items"] as? [String: Any])?["$ref"] as? String == "#/$defs/leaf")
        let leaf = try #require(defs["leaf"] as? [String: Any])
        #expect((leaf["properties"] as? [String: Any])?.keys.sorted() == ["text"])
        #expect(schema["required"] as? [String] == ["title", "summary", "sections", "actionItems", "clientFollowUp"])
        // What the local model writes under it still reads as a summary.
        let answer = #"{"title":"T","summary":"S","sections":[{"title":"A","bullets":[{"text":"x","children":[{"text":"y"}]}]}],"actionItems":[],"clientFollowUp":""}"#
        #expect(try CloudSummaryDTO.decode(from: answer).sections?.count == 1)
    }

    @Test func theFailuresReadAsWords() {
        for failure in allFailures {
            #expect(!(failure.errorDescription ?? "").isEmpty, "\(failure)")
        }
        #expect(DaisyLLMFailure.promptTooLong(tokens: 2, limit: 1).localizedDescription
            == "This meeting is too long for the local model on this Mac. Choose another provider for it.")
        #expect(DaisyLLMFailure.timedOut(seconds: 1800).localizedDescription
            == "The local model didn’t finish in 30 min — on this Mac it’s too slow for a meeting this long. Choose another provider for it.")
        // MLX's English detail stays in the log.
        #expect(DaisyLLMFailure.engine(detail: "Metal").localizedDescription
            == "The local model failed. Try again, or choose another provider for this meeting.")
    }

    @Test func withoutTheSmokeFlagLaunchGoesOn() {
        // Returns at once (with the flag it would never return).
        DaisyLLMSmoke.runIfRequested(["/Applications/Daisy.app/Contents/MacOS/Daisy", "-NSDocumentRevisionsDebugMode", "YES"])
    }
}
