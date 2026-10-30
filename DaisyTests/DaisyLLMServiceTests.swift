//
//  DaisyLLMServiceTests.swift
//  DaisyTests
//
//  «Локальная модель Daisy», Л-1: the client and the helper's service core
//  over a real NSXPC connection (an anonymous listener in this process),
//  with a scripted model in place of MLX — the wire protocol, progress,
//  one-at-a-time, cancellation, exit on idle and the errors in words. The
//  real model is checked by hand (`Daisy --daisy-llm-smoke`).
//

import Foundation
import Testing
import DaisyLLMKit
@testable import Daisy

/// Stands in for the MLX backend: says what it is told to, reports the
/// progress a real run would, and records what happened to it.
private final class ScriptedLLM: DaisyLLMBackend, @unchecked Sendable {
    enum Step: Sendable {
        case reply(String)
        case replyAfter(Duration, String)
        case fail(any Error)
        /// Runs until cancelled.
        case hang
    }

    private let lock = NSLock()
    private let script: @Sendable (DaisyLLMRequest) -> Step
    private var _started: [UUID] = []
    private var _running = 0
    private var _mostAtOnce = 0
    private var _cancelled: [UUID] = []
    private var _finishedAt: [ContinuousClock.Instant] = []

    init(_ script: @escaping @Sendable (DaisyLLMRequest) -> Step) {
        self.script = script
    }

    var started: [UUID] { lock.withLock { _started } }
    var mostAtOnce: Int { lock.withLock { _mostAtOnce } }
    var cancelled: [UUID] { lock.withLock { _cancelled } }
    var finishedAt: [ContinuousClock.Instant] { lock.withLock { _finishedAt } }

    func run(
        _ request: DaisyLLMRequest,
        progress: @escaping @Sendable (DaisyLLMProgress.Stage) -> Void
    ) async throws -> DaisyLLMResponse {
        lock.withLock {
            _started.append(request.id)
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
            }
        } catch is CancellationError {
            lock.withLock { _cancelled.append(request.id) }
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

/// The helper's service behind an anonymous listener, and a client on it.
@MainActor
private final class Helper {
    let backend: ScriptedLLM
    let service: DaisyLLMService
    let listener = NSXPCListener.anonymous()
    let client: DaisyLLMClient
    let idleExits = Recorder<ContinuousClock.Instant>()

    /// `startIdleClock: false` leaves the clock to the first request's end,
    /// so a slow machine can't run it out before the request arrives.
    init(
        idleTimeout: Duration = .seconds(30), startIdleClock: Bool = true,
        _ script: @escaping @Sendable (DaisyLLMRequest) -> ScriptedLLM.Step
    ) {
        backend = ScriptedLLM(script)
        let idleExits = idleExits
        service = DaisyLLMService(backend: backend, idleTimeout: idleTimeout) { idleExits.add(.now) }
        listener.delegate = service
        listener.resume()
        if startIdleClock { service.start() }
        nonisolated(unsafe) let endpoint = listener.endpoint
        client = DaisyLLMClient(makeConnection: { NSXPCConnection(listenerEndpoint: endpoint) })
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

/// Polls until `condition` holds or `timeout` passes. Generous: in the
/// full suite on a busy Mac the main actor these hops wait for fell more
/// than 5 s behind (30.10); a passing run returns at once.
@MainActor
private func eventually(_ timeout: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

// The client never launches the helper on an Intel Mac or under Rosetta.
@MainActor
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

        let failures: [DaisyLLMFailure] = [
            .modelNotFound(path: "/m"), .modelUnreadable(detail: "d"), .promptTooLong(tokens: 2, limit: 1),
            .invalidSchema(detail: "d"), .outputIncomplete(tokens: 4096), .cancelled, .unsupportedHardware,
            .protocolMismatch(service: 1, client: 2), .serviceRestarting, .serviceUnavailable(detail: "d"),
            .engine(detail: "d"),
        ]
        for failure in failures {
            #expect(try DaisyLLMWire.decode(DaisyLLMFailure.self, from: DaisyLLMWire.encode(failure)) == failure)
        }
    }

    @Test func theAnswerComesBackWithItsNumbers() async throws {
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
        let long = request("long")
        let task = Task { try await helper.client.generate(long) }
        #expect(await eventually { helper.backend.started == [long.id] })

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await eventually { helper.backend.cancelled == [long.id] })
        // The helper is free again.
        #expect(try await helper.client.generate(request("short")).text == "ok")
    }

    @Test func aQueuedRequestThatIsCancelledNeverStarts() async throws {
        let helper = Helper { request in request.userPrompt == "first" ? .hang : .reply("second") }
        defer { helper.close() }
        let first = request("first")
        let second = request("second")
        let firstTask = Task { try await helper.client.generate(first) }
        #expect(await eventually { helper.backend.started == [first.id] })
        let secondTask = Task { try await helper.client.generate(second) }
        try await Task.sleep(for: .milliseconds(100))

        secondTask.cancel()
        await #expect(throws: CancellationError.self) { try await secondTask.value }
        firstTask.cancel()
        await #expect(throws: CancellationError.self) { try await firstTask.value }

        #expect(await eventually { helper.backend.cancelled == [first.id] })
        #expect(helper.backend.started == [first.id])
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

    @Test func theSameRequestTwiceAtOnceIsRefusedNotOrphaned() async throws {
        let helper = Helper { _ in .replyAfter(.milliseconds(300), "ok") }
        defer { helper.close() }
        let sent = request()
        let first = Task { try await helper.client.generate(sent) }
        #expect(await eventually { helper.backend.started == [sent.id] })
        do {
            _ = try await helper.client.generate(sent)
            Issue.record("a second call with the same id went through")
        } catch DaisyLLMFailure.engine {
        }
        #expect(try await first.value.text == "ok")
    }

    @Test func aHelperNeverAskedAnythingLeavesToo() async {
        let helper = Helper(idleTimeout: .milliseconds(100)) { _ in .reply("ok") }
        defer { helper.close() }
        #expect(await eventually { helper.idleExits.values.count == 1 })
    }

    @Test func aRequestMeetingTheExitIsToldToStartAFreshHelper() async {
        let helper = Helper(idleTimeout: .milliseconds(50)) { _ in .reply("ok") }
        defer { helper.close() }
        #expect(await eventually { helper.service.isExiting })
        // The client sends it once more; this in-process helper never
        // actually exits, so the second answer is the same.
        await #expect(throws: DaisyLLMFailure.serviceRestarting) {
            try await helper.client.generate(request())
        }
        #expect(helper.backend.started.isEmpty)
    }

    @Test func daisyGoingAwayCancelsItsRequest() async throws {
        let helper = Helper { _ in .hang }
        defer { helper.close() }
        let sent = request()
        let stages = Recorder<DaisyLLMProgress.Stage>()
        let task = Task { try await helper.client.generate(sent) { stages.add($0) } }
        #expect(await eventually { helper.backend.started == [sent.id] && !stages.values.isEmpty })

        helper.client.invalidate()

        // It had started (progress came), so not retried: the helper is gone.
        do {
            _ = try await task.value
            Issue.record("the request went on without its connection")
        } catch DaisyLLMFailure.serviceUnavailable {
        } catch {
            Issue.record("\(error)")
        }
        #expect(await eventually { helper.backend.cancelled == [sent.id] })
    }

    @Test func aRequestFromAnotherDaisyBuildIsNamedAsSuch() async throws {
        let helper = Helper { _ in .reply("ok") }
        defer { helper.close() }
        var sent = request()
        sent.protocolVersion = 99
        let data = try DaisyLLMWire.encode(sent)
        let connection = NSXPCConnection(listenerEndpoint: helper.listener.endpoint)
        connection.remoteObjectInterface = DaisyLLMInterfaces.service()
        connection.resume()
        defer { connection.invalidate() }
        let failure: Data? = await withCheckedContinuation { continuation in
            // Exactly one of the two runs for a message with a reply.
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                continuation.resume(returning: nil)
            } as? DaisyLLMServiceProtocol
            guard let proxy else { return continuation.resume(returning: nil) }
            proxy.generate(data) { _, failure in continuation.resume(returning: failure) }
        }

        let decoded = try DaisyLLMWire.decode(DaisyLLMFailure.self, from: try #require(failure))
        #expect(decoded == .protocolMismatch(service: DaisyLLMWire.protocolVersion, client: 99))
        #expect(helper.backend.started.isEmpty)
    }

    @Test func theFailuresReadAsWords() {
        let all: [DaisyLLMFailure] = [
            .modelNotFound(path: "/m"), .modelUnreadable(detail: "d"), .promptTooLong(tokens: 2, limit: 1),
            .invalidSchema(detail: "d"), .outputIncomplete(tokens: 4096), .cancelled, .unsupportedHardware,
            .protocolMismatch(service: 1, client: 2), .serviceRestarting, .serviceUnavailable(detail: "d"),
            .engine(detail: "Metal"),
        ]
        for failure in all {
            #expect(!(failure.errorDescription ?? "").isEmpty, "\(failure)")
        }
        #expect(DaisyLLMFailure.promptTooLong(tokens: 2, limit: 1).localizedDescription
            == "This meeting is too long for the local model on this Mac. Choose a cloud provider for it.")
        #expect(DaisyLLMFailure.engine(detail: "Metal").localizedDescription == "The local model failed: Metal")
    }

    @Test func withoutTheSmokeFlagLaunchGoesOn() {
        // Returns at once (with the flag it would never return).
        DaisyLLMSmoke.runIfRequested(["/Applications/Daisy.app/Contents/MacOS/Daisy", "-NSDocumentRevisionsDebugMode", "YES"])
    }
}
