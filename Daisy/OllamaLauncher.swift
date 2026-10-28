import AppKit
import Foundation
import os

/// Starts Ollama when it is installed but not running, and waits for its
/// server (Egor, 28.10): Ollama installed with its script isn't a login
/// item, so after every restart Daisy said «Ollama на этом Mac не
/// запущена… Ждём Ollama…» and summaries failed, while the app sat in
/// /Applications. Now whatever asks for Ollama — the readiness probe, a
/// summary whose connection is refused, the Settings section — gets it
/// started first, hidden, with no window.
///
/// Only for a loopback address (a remote server is the person's own, not
/// ours to start), only when Ollama.app is installed, at most one launch a
/// minute (a person who quits Ollama while Settings polls isn't fought
/// every five seconds).
///
/// The actor only records the launch and fires it; every caller polls the
/// server itself, in its own task, until the launch's deadline. So a
/// cancelled caller stops at once (a withdrawn summary stays a
/// cancellation, review 28.10), a caller arriving during a launch joins
/// its remaining wait instead of launching again, and a launch whose
/// `openApplication` hangs behind a system prompt can't hold anyone past
/// the deadline, which starts before `open` is called.
actor OllamaLauncher {
    nonisolated static let shared = OllamaLauncher()

    nonisolated static let bundleID = "com.electron.ollama"
    nonisolated static let defaultWait: TimeInterval = 20
    nonisolated static let minInterval: TimeInterval = 60

    private let appURL: @Sendable () async -> URL?
    private let open: @Sendable (URL) async -> Void
    private let minInterval: TimeInterval
    private let pollEvery: Duration
    private var launchedAt: Date?
    private var launchWait: TimeInterval = 0
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "OllamaLaunch")

    init(appURL: @escaping @Sendable () async -> URL? = { await OllamaLauncher.installedAppURL() },
         open: @escaping @Sendable (URL) async -> Void = { await OllamaLauncher.openHidden($0) },
         minInterval: TimeInterval = OllamaLauncher.minInterval,
         pollEvery: Duration = .milliseconds(500)) {
        self.appURL = appURL
        self.open = open
        self.minInterval = minInterval
        self.pollEvery = pollEvery
    }

    /// True when the server answers — at once, or after Daisy started Ollama
    /// and it came up within `wait` seconds. False when it can't be started
    /// here (not installed, not a loopback address), when a launch earlier
    /// this minute didn't bring it up, when it didn't answer in time, or
    /// when the caller was cancelled.
    func ensureRunning(baseURL: URL,
                       wait: TimeInterval = OllamaLauncher.defaultWait,
                       probe: @escaping @Sendable (URL) async -> Bool) async -> Bool {
        if await probe(baseURL) { return true }
        guard Self.isLoopback(baseURL), let app = await appURL() else { return false }
        let now = Date()
        let deadline: Date
        if let last = launchedAt, now.timeIntervalSince(last) < minInterval {
            // A launch this minute: wait out what's left of it (nothing, if
            // it has already given up) rather than launch again.
            deadline = last.addingTimeInterval(launchWait)
        } else {
            launchedAt = now
            launchWait = wait
            deadline = now.addingTimeInterval(wait)
            log.info("Ollama isn't answering at \(baseURL.absoluteString, privacy: .public) — starting it")
            let open = self.open
            Task { await open(app) }
        }
        while Date() < deadline {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: pollEvery)
            if Task.isCancelled { return false }
            if await probe(baseURL) {
                log.info("Ollama answering at \(baseURL.absoluteString, privacy: .public)")
                return true
            }
        }
        if Task.isCancelled { return false }
        let answered = await probe(baseURL)
        if !answered {
            log.warning("Ollama didn't answer at \(baseURL.absoluteString, privacy: .public) within the launch's wait")
        }
        return answered
    }

    /// Whether Ollama.app is on this Mac (Settings shows «starting» instead
    /// of «install» then). Never in the test host.
    @MainActor static var isInstalled: Bool { installedAppURL() != nil }

    /// Nil in the test host: no test may start the developer's real Ollama.
    @MainActor static func installedAppURL() -> URL? {
        guard !TestHost.isActive else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    @MainActor static func openHidden(_ app: URL) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    nonisolated static func isLoopback(_ url: URL) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }
}
