//
//  CodexMCPConfig.swift
//  Daisy
//
//  One-click setup for the local Codex app / CLI. Codex can register a
//  Streamable HTTP server (`--url`), but takes its bearer token only from
//  an environment variable — which the Codex app, started from the Dock,
//  doesn't have. So Codex gets the same stdio entry as Claude — Daisy's
//  sh + curl bridge (`MCPStdioBridge`), token as an argument, nothing to
//  install.
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
        // Two layouts: the helper in `codex-cli/CodexCLI.app` (ChatGPT app, seen
        // 03.10.2026) and, before that, straight in Resources.
        let inside = ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"]
        var apps: [URL] = []
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") { apps.append(app) }
        apps += [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            URL(fileURLWithPath: "/Applications/Codex.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ChatGPT.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Codex.app"),
        ]
        candidates = apps.flatMap { app in inside.map { app.appendingPathComponent($0) } }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    static func entryState(port: Int) -> EntryState {
        guard executableURL != nil else { return .codexNotInstalled }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8),
              let section = daisySection(in: text) else {
            return .notInstalled
        }
        // Current = the bridge at this version, port and token. The
        // `npx mcp-remote` entry from before October 2026 fails the name
        // check and gets rewritten by the repair.
        let token = MCPAccessToken.isRequired ? MCPAccessToken.ensure() : nil
        guard section.contains("\"\(MCPStdioBridge.command)\""),
              section.contains("\"\(MCPStdioBridge.name)\""),
              section.contains("\"\(MCPStdioBridge.url(port: port))\""),
              // A leftover token with the setting off is harmless: the
              // server ignores a header it doesn't require.
              token.map({ section.contains("\"\($0)\"") }) ?? true else {
            return .installedDifferentPort
        }
        return .installed
    }

    /// Serializes CLI work. `install` is remove-then-add, and with the
    /// calls now async the main actor is free between the two — so a
    /// port change and a token change arriving together could run two
    /// `codex` processes writing one TOML (review find, 2026-09-02).
    private static var cliWork: Task<Void, Never>?

    /// Run `body` after any CLI work already queued. Keeps the file
    /// single-writer without making callers think about it.
    private static func serialized<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        // The body runs INSIDE the chained task: chaining only the wait
        // let a second body start while the first was suspended in its
        // CLI call (review find, 2026-10-07).
        let previous = cliWork
        let work = Task { @MainActor () -> T in
            _ = await previous?.value
            return await body()
        }
        cliWork = Task { _ = await work.value }
        return await work.value
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

        let token = MCPAccessToken.isRequired ? MCPAccessToken.ensure() : nil
        let bridgeArguments = ["mcp", "add", "daisy", "--", MCPStdioBridge.command]
            + MCPStdioBridge.arguments(port: port, token: token)
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

    /// Keeps an already-approved Codex connection current after the
    /// server moves to a new port or the token setting changes. Runs the
    /// CLI only for an entry that isn't current; never creates one
    /// without an explicit button press.
    static func refreshIfInstalled(port: Int) async {
        // The check runs inside the queue: checked outside, a refresh
        // queued behind a Disconnect would add Daisy straight back.
        await serialized {
            guard entryState(port: port) == .installedDifferentPort else { return }
            _ = await installUnserialized(port: port)
        }
    }

    private static func daisySection(in text: String) -> String? {
        let marker = "[mcp_servers.daisy]"
        guard let start = text.range(of: marker) else { return nil }
        let afterMarker = text[start.upperBound...]
        let end = afterMarker.range(of: "\n[")?.lowerBound ?? afterMarker.endIndex
        return String(afterMarker[..<end])
    }

    nonisolated private static func run(_ executable: URL, arguments: [String]) -> (status: Int32, message: String) {
        MCPClientCLI.run(executable, arguments: arguments, fallbackMessage: "Codex couldn't update its MCP settings.")
    }
}
