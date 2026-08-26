//
//  CursorMCPConfig.swift
//  Daisy
//
//  One-click, non-destructive registration of Daisy in Cursor's global
//  MCP configuration.
//
//  Cursor speaks Streamable HTTP natively — a remote entry is a `url`
//  plus optional `headers`, no `type` field required — so since Daisy
//  started serving POST /mcp there is nothing left for the `mcp-remote`
//  bridge to do here. Dropping it removes Node from the requirements
//  for Cursor users entirely, along with an `npx` process per session
//  that had full sight of every transcript it proxied.
//
//  Entries written before that read as `.installedDifferentPort` — the
//  state the UI already renders as "Repair connection". The old bridge
//  config still works, so this is a nudge rather than a break, and the
//  repair (or the next port / token change) migrates it.
//

import Foundation

@MainActor
enum CursorMCPConfig {
    enum EntryState: Equatable {
        case notInstalled
        case installed
        case installedDifferentPort
        case malformed
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

    private static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
    }

    private static var configURL: URL {
        configDirectory.appendingPathComponent("mcp.json", isDirectory: false)
    }

    static func entryState(port: Int) -> EntryState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              !data.isEmpty else {
            return .notInstalled
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed
        }
        guard let servers = root["mcpServers"] as? [String: Any],
              let daisy = servers["daisy"] as? [String: Any] else {
            return .notInstalled
        }
        // Current shape: a native remote entry pointing at this port's
        // Streamable HTTP endpoint. Anything else that still says
        // "daisy" — a wrong port, or a pre-2026-08 mcp-remote bridge —
        // is present but wants rewriting.
        if let url = daisy["url"] as? String {
            return url == daisyStreamableURL(port: port) ? .installed : .installedDifferentPort
        }
        return .installedDifferentPort
    }

    @discardableResult
    static func install(port: Int) -> InstallResult {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: configDirectory.path) {
                try fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            }

            var root: [String: Any] = [:]
            if fm.fileExists(atPath: configURL.path),
               let data = try? Data(contentsOf: configURL),
               !data.isEmpty {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .failed("Cursor's MCP config isn't a JSON object, so Daisy won't overwrite it.")
                }
                root = parsed
            }

            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            // Assigned wholesale, so a bridge entry written by an older
            // Daisy loses its `command` / `args` instead of keeping
            // them alongside the new `url`.
            var entry: [String: Any] = ["url": daisyStreamableURL(port: port)]
            if MCPAccessToken.isRequired {
                entry["headers"] = ["Authorization": "Bearer \(MCPAccessToken.ensure())"]
            }
            servers["daisy"] = entry
            root["mcpServers"] = servers

            let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: configURL, options: .atomic)
            return .installed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @discardableResult
    static func remove() -> RemoveResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              !data.isEmpty else {
            return .notPresent
        }
        do {
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed("Cursor's MCP config isn't a JSON object, so Daisy won't edit it.")
            }
            guard var servers = root["mcpServers"] as? [String: Any], servers["daisy"] != nil else {
                return .notPresent
            }
            servers.removeValue(forKey: "daisy")
            if servers.isEmpty {
                root.removeValue(forKey: "mcpServers")
            } else {
                root["mcpServers"] = servers
            }
            let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: configURL, options: .atomic)
            return .removed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func refreshIfInstalled(port: Int) {
        switch entryState(port: port) {
        case .installed, .installedDifferentPort:
            _ = install(port: port)
        case .notInstalled, .malformed:
            break
        }
    }

    private static func daisyStreamableURL(port: Int) -> String {
        "http://127.0.0.1:\(port)/mcp"
    }
}
