//
//  ClaudeCodeMCPConfig.swift
//  Daisy
//
//  One-click setup for Claude Code in the Terminal and IDEs. The Code
//  tab of the Claude app doesn't need this — it loads the servers from
//  `claude_desktop_config.json`, which the Claude row already writes
//  (checked 2026-10-07: a Code-tab session had Daisy's tools with no
//  `daisy` entry in `~/.claude.json`).
//
//  Claude Code speaks Streamable HTTP natively, so the entry is the
//  loopback /mcp URL — no Node bridge. The `claude` CLI owns
//  `~/.claude.json` (a large file Claude Code rewrites all the time),
//  so Daisy only ever READS it, to show the state, and changes it
//  through `claude mcp add` / `claude mcp remove`.
//
//  Scope is `user`. The copy-paste command Daisy showed until October
//  2026 had no `--scope`, and the CLI's default is `local`: Daisy then existed
//  only for sessions started in the folder where the command was
//  pasted — the home folder, nearly always. Such an entry reads as
//  "needs an update", and the repair moves it to the user scope.
//

import Foundation

@MainActor
enum ClaudeCodeMCPConfig {
    enum EntryState: Equatable {
        case notInstalled
        case installed
        case installedDifferentPort
        case claudeCodeNotInstalled
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

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json", isDirectory: false)
    }

    /// The native installer's symlink first, then the older npm-local
    /// install and the package managers. Path-only, like Codex: no
    /// login shell just to find a binary.
    static var executableURL: URL? {
        var paths = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        // `npm install -g` under nvm / Volta puts it beside `npx`.
        if let dir = NodeRuntime.binDirectory { paths.append("\(dir)/claude") }
        return MCPClientCLI.firstExecutable(paths)
    }

    /// The command for someone who'd rather paste it, or whose `claude`
    /// lives somewhere Daisy doesn't look.
    static func command(port: Int) -> String {
        let auth = MCPAccessToken.isRequired
            ? " --header \"Authorization: Bearer \(MCPAccessToken.ensure())\""
            : ""
        return "claude mcp add --scope user --transport http daisy \(daisyURL(port: port))\(auth)"
    }

    static func entryState(port: Int) -> EntryState {
        guard executableURL != nil else { return .claudeCodeNotInstalled }
        let entries = readEntries()
        guard entries.user != nil || entries.homeLocal != nil else { return .notInstalled }
        // The header counts too: an entry without the token while the
        // token is required would connect and be refused.
        let wantedAuth = MCPAccessToken.isRequired ? "Bearer \(MCPAccessToken.ensure())" : nil
        guard entries.homeLocal == nil,
              let user = entries.user,
              user["url"] as? String == daisyURL(port: port),
              (user["headers"] as? [String: String])?["Authorization"] == wantedAuth else {
            return .installedDifferentPort
        }
        return .installed
    }

    /// Serializes CLI work, same reason as `CodexMCPConfig`: install is
    /// remove-then-add, and a port change plus a token change arriving
    /// together must not run two `claude` processes on one file.
    private static var cliWork: Task<Void, Never>?

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
            return .failed("Claude Code isn't installed.")
        }
        // `claude mcp add` refuses to overwrite a name, so clear Daisy's
        // own entries first — every other server stays as it is.
        if case .failed(let message) = await removeEntries(executable) {
            return .failed(message)
        }

        // Name and URL before `--header`: the option is variadic and
        // would swallow anything after it.
        var arguments = ["mcp", "add", "--scope", "user", "--transport", "http", "daisy", daisyURL(port: port)]
        if MCPAccessToken.isRequired {
            arguments += ["--header", "Authorization: Bearer \(MCPAccessToken.ensure())"]
        }
        let result = await Task.detached { [arguments] in run(executable, arguments: arguments) }.value
        return result.status == 0 ? .installed : .failed(result.message)
    }

    @discardableResult
    static func remove() async -> RemoveResult {
        await serialized {
            guard let executable = executableURL else { return .notPresent }
            return await removeEntries(executable)
        }
    }

    /// Removes the user-scope entry and the home-folder local one left
    /// by the old command, whichever exist.
    private static func removeEntries(_ executable: URL) async -> RemoveResult {
        let entries = readEntries()
        var scopes: [String] = []
        if entries.user != nil { scopes.append("user") }
        // `local` is keyed by the working directory, and the runner
        // starts the CLI in the home folder — exactly this entry.
        if entries.homeLocal != nil { scopes.append("local") }
        guard !scopes.isEmpty else { return .notPresent }
        for scope in scopes {
            let result = await Task.detached { run(executable, arguments: ["mcp", "remove", "daisy", "--scope", scope]) }.value
            guard result.status == 0 else { return .failed(result.message) }
        }
        return .removed
    }

    /// Keeps an approved connection pointing at the live port and token.
    /// Runs the CLI only for an entry that isn't current; never creates
    /// one without a button press.
    static func refreshIfInstalled(port: Int) async {
        // The check runs inside the queue: checked outside, a refresh
        // queued behind a Disconnect would add Daisy straight back.
        await serialized {
            guard entryState(port: port) == .installedDifferentPort else { return }
            _ = await installUnserialized(port: port)
        }
    }

    /// Daisy's entries in `~/.claude.json`, read-only.
    private static func readEntries() -> (user: [String: Any]?, homeLocal: [String: Any]?) {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let user = (root["mcpServers"] as? [String: Any])?["daisy"] as? [String: Any]
        let projects = root["projects"] as? [String: Any]
        let homeProject = projects?[home] as? [String: Any]
        let homeLocal = (homeProject?["mcpServers"] as? [String: Any])?["daisy"] as? [String: Any]
        return (user, homeLocal)
    }

    private static func daisyURL(port: Int) -> String {
        "http://127.0.0.1:\(port)/mcp"
    }

    nonisolated private static func run(_ executable: URL, arguments: [String]) -> (status: Int32, message: String) {
        MCPClientCLI.run(executable, arguments: arguments, fallbackMessage: "Claude Code couldn't update its MCP settings.")
    }
}
