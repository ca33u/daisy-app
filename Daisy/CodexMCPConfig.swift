//
//  CodexMCPConfig.swift
//  Daisy
//
//  One-click setup for the local Codex app / CLI. Daisy speaks MCP over
//  HTTP+SSE; Codex currently registers URL servers as Streamable HTTP, so
//  we use the same pinned stdio bridge that powers the Claude Desktop setup.
//  The Codex CLI owns TOML parsing and merging — Daisy never writes
//  ~/.codex/config.toml itself.
//

import Foundation
import AppKit

@MainActor
enum CodexMCPConfig {
    enum EntryState: Equatable {
        case notInstalled
        case installed
        case installedDifferentPort
        case codexNotInstalled
    }

    enum InstallResult {
        case installed
        case failed(String)
    }

    enum RemoveResult {
        case removed
        case notPresent
        case failed(String)
    }

    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    /// Codex ships inside the ChatGPT/Codex macOS app. Keep conventional
    /// paths as fallbacks for CLI-only installs and older app bundles.
    private static var executableURL: URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            candidates.append(app.appendingPathComponent("Contents/Resources/codex"))
        }
        candidates += [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex")
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    static func entryState(port: Int) -> EntryState {
        guard executableURL != nil else { return .codexNotInstalled }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8),
              let section = daisySection(in: text) else {
            return .notInstalled
        }
        return section.contains(daisySSEURL(port: port)) ? .installed : .installedDifferentPort
    }

    /// Serializes CLI work. `install` is remove-then-add, and with the
    /// calls now async the main actor is free between the two — so a
    /// port change and a token change arriving together could run two
    /// `codex` processes writing one TOML (review find, 2026-09-02).
    private static var cliWork: Task<Void, Never>?

    /// Run `body` after any CLI work already queued. Keeps the file
    /// single-writer without making callers think about it.
    private static func serialized<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = cliWork
        let work = Task { @MainActor in
            _ = await previous?.value
        }
        cliWork = work
        await work.value
        return await body()
    }

    @discardableResult
    static func install(port: Int) async -> InstallResult {
        await serialized { await installUnserialized(port: port) }
    }

    private static func installUnserialized(port: Int) async -> InstallResult {
        guard let executable = executableURL else {
            return .failed("Codex isn't installed.")
        }

        // `codex mcp add` intentionally refuses to overwrite a named
        // server. Replace only Daisy's own entry, preserving every other
        // user-configured server through Codex's TOML writer.
        switch entryState(port: port) {
        case .installed, .installedDifferentPort:
            let removal = await Task.detached { run(executable, arguments: ["mcp", "remove", "daisy"]) }.value
            guard removal.status == 0 else { return .failed(removal.message) }
        case .notInstalled:
            break
        case .codexNotInstalled:
            return .failed("Codex isn't installed.")
        }

        var bridgeArguments = [
            "mcp", "add", "daisy", "--", "npx", "-y", "mcp-remote@0.1.38",
            daisySSEURL(port: port), "--transport", "sse-only", "--allow-http"
        ]
        if MCPAccessToken.isRequired {
            bridgeArguments += ["--header", "Authorization: Bearer \(MCPAccessToken.ensure())"]
        }
        let result = await Task.detached { [bridgeArguments] in run(executable, arguments: bridgeArguments) }.value
        return result.status == 0 ? .installed : .failed(result.message)
    }

    @discardableResult
    static func remove() async -> RemoveResult {
        await serialized { await removeUnserialized() }
    }

    private static func removeUnserialized() async -> RemoveResult {
        guard executableURL != nil else { return .notPresent }
        guard daisySection(in: (try? String(contentsOf: configURL, encoding: .utf8)) ?? "") != nil else {
            return .notPresent
        }
        guard let executable = executableURL else { return .notPresent }
        let result = await Task.detached { run(executable, arguments: ["mcp", "remove", "daisy"]) }.value
        return result.status == 0 ? .removed : .failed(result.message)
    }

    /// Keeps an already-approved Codex connection alive after the user
    /// changes Daisy's port or enables token protection. Never creates a
    /// new Codex configuration without an explicit button press.
    static func refreshIfInstalled(port: Int) async {
        switch entryState(port: port) {
        case .installed, .installedDifferentPort:
            _ = await install(port: port)
        case .notInstalled, .codexNotInstalled:
            break
        }
    }

    private static func daisySection(in text: String) -> String? {
        let marker = "[mcp_servers.daisy]"
        guard let start = text.range(of: marker) else { return nil }
        let afterMarker = text[start.upperBound...]
        let end = afterMarker.range(of: "\n[")?.lowerBound ?? afterMarker.endIndex
        return String(afterMarker[..<end])
    }

    private static func daisySSEURL(port: Int) -> String {
        "http://127.0.0.1:\(port)/sse"
    }

    /// Run the codex CLI and collect what it said.
    ///
    /// `nonisolated` and read-before-wait, both deliberately:
    ///
    ///   • the previous version blocked the MAIN thread in
    ///     `waitUntilExit()`, and `install(port:)` runs the CLI twice,
    ///     so every edit of the MCP port froze the UI for a second or
    ///     two of process startup;
    ///   • it also read the pipes AFTER waiting, which is the classic
    ///     deadlock — a child that writes more than the 64 KB pipe
    ///     buffer blocks on the write while we block on the child, and
    ///     the app hangs until Force Quit. `LogReporter` documents the
    ///     same trap and avoids it; this one didn't (audit 2026-09-01).
    ///
    /// Callers must reach it through `Task.detached` — a nonisolated
    /// async function would inherit the caller's executor under this
    /// project's concurrency settings, which is exactly the main actor
    /// we're trying to leave.
    nonisolated private static func run(
        _ executable: URL,
        arguments: [String]
    ) -> (status: Int32, message: String) {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
            // Drain BEFORE waiting.
            let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            let message = (stderr.isEmpty ? stdout : stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (process.terminationStatus, message.isEmpty ? "Codex couldn't update its MCP settings." : message)
        } catch {
            return (1, error.localizedDescription)
        }
    }
}
