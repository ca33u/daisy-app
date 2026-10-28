import Foundation
import Testing
@testable import Daisy

/// Egor, 28.10: Ollama installed but not running after a restart left Daisy
/// waiting («Ждём Ollama…») and summaries failing. `OllamaLauncher` starts
/// it and waits for its server; these pin when it does and doesn't.
@Suite("Ollama launcher")
struct OllamaLauncherTests {
    private actor World {
        var opens = 0
        var serverUp = false
        var comesUpOnOpen = true
        func open() { opens += 1; if comesUpOnOpen { serverUp = true } }
        func up() -> Bool { serverUp }
        func setUp(_ v: Bool) { serverUp = v }
        func setComesUp(_ v: Bool) { comesUpOnOpen = v }
    }

    private let local = URL(string: "http://127.0.0.1:11434")!
    private let app = URL(fileURLWithPath: "/Applications/Ollama.app")

    private func launcher(_ world: World, installed: Bool = true, minInterval: TimeInterval = 60) -> OllamaLauncher {
        let app = self.app
        return OllamaLauncher(appURL: { installed ? app : nil },
                              open: { _ in await world.open() },
                              minInterval: minInterval,
                              pollEvery: .milliseconds(10))
    }

    @Test("A server already answering is left alone")
    func alreadyUp() async {
        let world = World(); await world.setUp(true)
        let ok = await launcher(world).ensureRunning(baseURL: local, wait: 1) { _ in await world.up() }
        #expect(ok)
        #expect(await world.opens == 0)
    }

    @Test("Installed and silent: started once, and the wait ends when it answers")
    func startsIt() async {
        let world = World()
        let ok = await launcher(world).ensureRunning(baseURL: local, wait: 2) { _ in await world.up() }
        #expect(ok)
        #expect(await world.opens == 1)
    }

    @Test("Not installed, or a remote server: nothing is started")
    func notOurs() async {
        let world = World()
        #expect(!(await launcher(world, installed: false).ensureRunning(baseURL: local, wait: 1) { _ in await world.up() }))
        let remote = URL(string: "http://192.168.1.20:11434")!
        #expect(!(await launcher(world).ensureRunning(baseURL: remote, wait: 1) { _ in await world.up() }))
        #expect(await world.opens == 0)
    }

    @Test("A launch that doesn't come up isn't repeated within the interval")
    func noRelaunchStorm() async {
        let world = World(); await world.setComesUp(false)
        let l = launcher(world)
        #expect(!(await l.ensureRunning(baseURL: local, wait: 0.1) { _ in await world.up() }))
        #expect(!(await l.ensureRunning(baseURL: local, wait: 0.1) { _ in await world.up() }))
        #expect(await world.opens == 1)
    }

    @Test("Callers at the same moment share one launch")
    func oneLaunchForMany() async {
        let world = World()
        let l = launcher(world)
        let local = self.local
        async let a = l.ensureRunning(baseURL: local, wait: 2) { _ in await world.up() }
        async let b = l.ensureRunning(baseURL: local, wait: 2) { _ in await world.up() }
        async let c = l.ensureRunning(baseURL: local, wait: 2) { _ in await world.up() }
        let results = await [a, b, c]
        #expect(results.allSatisfy { $0 })
        #expect(await world.opens == 1)
    }

    @Test("A cancelled caller stops waiting at once")
    func cancellable() async {
        let world = World(); await world.setComesUp(false)
        let l = launcher(world)
        let local = self.local
        let task = Task { await l.ensureRunning(baseURL: local, wait: 10) { _ in await world.up() } }
        try? await Task.sleep(for: .milliseconds(50))
        let began = ContinuousClock.now
        task.cancel()
        #expect(await task.value == false)
        #expect(ContinuousClock.now - began < .seconds(5))
    }

    @Test("An open that never returns can't hold a caller past the wait")
    func openHangs() async {
        let world = World()
        let app = self.app
        let l = OllamaLauncher(appURL: { app },
                               open: { _ in try? await Task.sleep(for: .seconds(30)) },
                               pollEvery: .milliseconds(10))
        let began = ContinuousClock.now
        #expect(!(await l.ensureRunning(baseURL: local, wait: 0.2) { _ in await world.up() }))
        #expect(ContinuousClock.now - began < .seconds(5))
    }

    @Test("A summary whose connection is refused starts Ollama and asks once more")
    func summaryRetries() async throws {
        let world = World()
        let app = self.app
        let launcher = OllamaLauncher(appURL: { app }, open: { _ in await world.open() }, pollEvery: .milliseconds(10))
        RefusedThenOK.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefusedThenOK.self]
        let session = URLSession(configuration: config)
        // The stub answers /api/tags only once the launch has happened.
        RefusedThenOK.serverUp = { await world.up() }
        let summarizer = OllamaAPISummarizer(baseURL: local, model: "qwen3.5:4b", urlSession: session, launcher: launcher)
        // The stub reports no token counts, so nothing reaches the ledger
        // (empty spend is dropped) and the shared test recorder other
        // suites use in parallel is left alone.
        let summary = try await summarizer.summarize(transcript: String(repeating: "Обсудили сроки. ", count: 40),
                                                     title: "t", localeHint: "ru", task: .meeting(forceFollowUp: false))
        #expect(summary.summary == "Обсудили сроки.")
        #expect(await world.opens == 1)
        #expect(RefusedThenOK.chatAttempts == 2)
    }

    @Test("Loopback spellings")
    func loopback() {
        #expect(OllamaLauncher.isLoopback(URL(string: "http://localhost:11434")!))
        #expect(OllamaLauncher.isLoopback(URL(string: "http://[::1]:11434")!))
        #expect(!OllamaLauncher.isLoopback(URL(string: "http://ollama.lan:11434")!))
    }

    @Test("The test host never finds the real Ollama")
    @MainActor func neverRealInTests() {
        #expect(OllamaLauncher.installedAppURL() == nil)
    }
}

/// `/api/chat`: refused until the launch, then a valid summary; `/api/tags`:
/// answers once `serverUp` says the launch happened.
final class RefusedThenOK: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var chatAttempts = 0
    nonisolated(unsafe) static var serverUp: @Sendable () async -> Bool = { false }
    static func reset() { chatAttempts = 0; serverUp = { false } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let request = self.request
        Task {
            let up = await Self.serverUp()
            let path = request.url?.path ?? ""
            if path.hasSuffix("/api/chat") { Self.chatAttempts += 1 }
            guard up else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            let body: Data
            if path.hasSuffix("/api/tags") {
                body = Data(#"{"models":[]}"#.utf8)
            } else {
                let content = #"{"summary":"Обсудили сроки."}"#
                let json: [String: Any] = ["message": ["role": "assistant", "content": content]]
                body = try! JSONSerialization.data(withJSONObject: json)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

