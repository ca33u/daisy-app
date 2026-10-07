//
//  MCPClientCLI.swift
//  Daisy
//
//  Shared plumbing for the MCP client rows in Connections: running a
//  client's own CLI (`codex mcp …`, `claude mcp …`) and finding Node
//  for an npm-installed `claude`.
//

import Foundation

nonisolated enum MCPClientCLI {
    /// Run a client CLI and collect what it said.
    ///
    /// `nonisolated` and read-before-wait, both deliberately:
    ///
    ///   • an earlier version blocked the MAIN thread in
    ///     `waitUntilExit()`, and an install runs the CLI twice, so
    ///     every edit of the MCP port froze the UI for a second or two
    ///     of process startup;
    ///   • it also read the pipes AFTER waiting, which is the classic
    ///     deadlock — a child that writes more than the 64 KB pipe
    ///     buffer blocks on the write while we block on the child, and
    ///     the app hangs until Force Quit. `LogReporter` documents the
    ///     same trap and avoids it (audit 2026-09-01).
    ///
    /// Callers must reach it through `Task.detached` — a nonisolated
    /// async function would inherit the caller's executor under this
    /// project's concurrency settings, which is exactly the main actor
    /// we're trying to leave.
    static func run(
        _ executable: URL,
        arguments: [String],
        fallbackMessage: String
    ) -> (status: Int32, message: String) {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        // Home, not wherever Daisy was launched from: `claude mcp`'s
        // local scope is keyed by this directory.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        // Node first: an npm-installed `claude` is a `#!/usr/bin/env
        // node` script, and nvm / Volta keep `node` out of these dirs.
        let system = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = NodeRuntime.binDirectory.map { "\($0):\(system)" } ?? system
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
            return (process.terminationStatus, message.isEmpty ? fallbackMessage : message)
        } catch {
            return (1, error.localizedDescription)
        }
    }

    /// The first existing executable among `paths`.
    static func firstExecutable(_ paths: [String]) -> URL? {
        let fm = FileManager.default
        return paths.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

/// Where Node lives on this Mac, for the one thing that still needs
/// it: a `claude` installed with `npm install -g`, which is a
/// `#!/usr/bin/env node` script. nvm / fnm / Volta keep Node outside
/// the system directories, so `MCPClientCLI.run` puts this directory on
/// PATH and `ClaudeCodeMCPConfig` looks for `claude` in it. (The Claude
/// and Codex entries no longer need Node at all — see `MCPStdioBridge`.)
nonisolated enum NodeRuntime {
    /// The directory holding `npx` (and `node`), if found.
    static var binDirectory: String? { npxURL?.deletingLastPathComponent().path }

    private static var npxURL: URL? {
        let home = NSHomeDirectory()
        return MCPClientCLI.firstExecutable(
            ["/opt/homebrew/bin/npx", "/usr/local/bin/npx"]
                + nvmCandidates(home: home)
                + [
                    "\(home)/.volta/bin/npx",
                    "\(home)/Library/Application Support/fnm/aliases/default/bin/npx",
                    "\(home)/.local/share/fnm/aliases/default/bin/npx",
                    "\(home)/.local/bin/npx",
                ]
                // Not asdf / mise shims: they need the manager itself on
                // PATH, which the runner doesn't put there.
        )
    }

    /// nvm's versions, newest first (`v22.20.0` after `v9.11.2`, so
    /// compared numerically, not as strings).
    private static func nvmCandidates(home: String) -> [String] {
        let root = "\(home)/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                .split(separator: ".").map { Int($0) ?? 0 }
        }
        return versions
            .sorted { parts($0).lexicographicallyPrecedes(parts($1)) }
            .reversed()
            .map { "\(root)/\($0)/bin/npx" }
    }
}
