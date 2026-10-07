//
//  ClaudeDesktopConfig.swift
//  Daisy
//
//  One-click installer that drops Daisy's MCP server entry into
//  Claude Desktop's `claude_desktop_config.json`, so users don't have
//  to copy-paste JSON and hunt down the file path.
//
//  ─── Why a DIRECT write (no NSOpenPanel) ──────────────────────────
//  Daisy is NOT sandboxed (ENABLE_APP_SANDBOX = NO in build settings —
//  dictation needs system-wide CGEvent.post(⌘V) into arbitrary
//  frontmost processes, which is incompatible with App Sandbox; see
//  Daisy.entitlements). A non-sandboxed app has full filesystem access
//  under the user's permissions, so we can write straight to
//  `~/Library/Application Support/Claude/claude_desktop_config.json`,
//  creating the `Claude` directory and the file if they don't exist.
//
//  This is what makes the button a genuine ONE click. Earlier builds
//  routed through an NSOpenPanel + security-scoped bookmark (the
//  sandboxed pattern) — that added two clicks and a file dialog for no
//  benefit on a non-sandboxed app, so it was removed. (If Daisy ever
//  re-enables the sandbox, this file is where the bookmark dance would
//  come back.)
//
//  ─── Safety guarantees ────────────────────────────────────────────
//   • Merge, never clobber. We read the existing JSON, preserve every
//     other top-level key AND every other `mcpServers` entry (Cursor,
//     custom local servers, …), and only insert/refresh/remove our own
//     `daisy` key.
//   • Refuse to touch malformed JSON. If the file exists but isn't a
//     JSON object (hand-written garbage, half-saved edit), we throw
//     instead of overwriting — the user keeps their file and gets an
//     actionable error.
//   • Atomic write. `Data.write(options: .atomic)` writes to a temp
//     file and renames, so a crash mid-write can't leave a truncated
//     config.
//

import Foundation
import AppKit
import os

@MainActor
enum ClaudeDesktopConfig {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "ClaudeDesktopConfig")

    // MARK: - Result / state types

    enum InstallResult {
        case installed(URL)
        case failed(String)
    }

    enum RemoveResult {
        case removed
        case notPresent
        case failed(String)
    }

    /// Where the `daisy` entry stands relative to the live server port.
    /// Drives the button copy + secondary actions in ConnectionsView.
    enum EntryState: Equatable {
        /// Claude Desktop's config dir doesn't exist and the app isn't
        /// found — almost certainly Claude Desktop isn't installed.
        case claudeNotInstalled
        /// Claude looks installed but there's no `daisy` entry yet.
        case notInstalled
        /// A `daisy` entry exists and already points at this exact port.
        case installed
        /// A `daisy` entry exists but points at a different port (user
        /// changed the port after installing) — offer to refresh.
        case installedDifferentPort(existingURL: String)
        /// The config file is present but not parseable as a JSON
        /// object — we must not write to it. UI surfaces a "fix it
        /// yourself" hint and disables the one-click button.
        case malformed
    }

    // MARK: - Paths

    /// `~/Library/Application Support/Claude/`
    static var claudeSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
    }

    /// `~/Library/Application Support/Claude/claude_desktop_config.json`
    static var configFileURL: URL {
        claudeSupportDirectory.appendingPathComponent("claude_desktop_config.json", isDirectory: false)
    }

    // MARK: - Detection

    /// Best-effort "is Claude Desktop on this Mac" check. The signal
    /// that actually matters for writing the config is the support
    /// directory existing (Claude creates it on first launch); we also
    /// probe for the app bundle so a freshly-installed-but-never-opened
    /// Claude still reads as installed. We deliberately don't hard-fail
    /// on this — `install()` will create the directory regardless, so a
    /// false "not installed" never blocks the write, it only changes
    /// the hint copy.
    static var claudeDesktopLooksInstalled: Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: claudeSupportDirectory.path, isDirectory: &isDir), isDir.boolValue {
            return true
        }
        // Secondary: the app bundle. Bundle id has been
        // `com.anthropic.claudefordesktop`; fall back to a Spotlight-
        // free check of the conventional install path so we don't
        // depend on one exact identifier.
        let ws = NSWorkspace.shared
        if ws.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") != nil {
            return true
        }
        if fm.fileExists(atPath: "/Applications/Claude.app") {
            return true
        }
        return false
    }

    /// Inspect the on-disk config and report where the `daisy` entry
    /// stands relative to `port`. Pass `nil` to skip the port match
    /// (treats any existing `daisy` entry as `.installed`). Never
    /// mutates anything.
    static func entryState(port: Int?) -> EntryState {
        let fm = FileManager.default

        guard fm.fileExists(atPath: configFileURL.path) else {
            return claudeDesktopLooksInstalled ? .notInstalled : .claudeNotInstalled
        }
        guard let data = try? Data(contentsOf: configFileURL), !data.isEmpty else {
            // Empty / unreadable file — treat as "no entry yet". A
            // zero-byte file is safe to overwrite with a fresh object.
            return .notInstalled
        }
        guard
            let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
            let root = parsed as? [String: Any]
        else {
            return .malformed
        }
        guard
            let mcpServers = root["mcpServers"] as? [String: Any],
            let daisy = mcpServers["daisy"] as? [String: Any]
        else {
            return .notInstalled
        }

        guard let port else { return .installed }

        // Current means exactly the entry `install` would write now:
        // the sh bridge, this port, this token, this script version.
        // Anything else that still says "daisy" — an older script, the
        // `npx mcp-remote` bridge before October 2026, a hand-written
        // command — is present but wants rewriting.
        let args = (daisy["args"] as? [String]) ?? []
        if daisy["command"] as? String == MCPStdioBridge.command, args == bridgeArguments(port: port) {
            return .installed
        }
        let existingURL = args.first { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
        return .installedDifferentPort(existingURL: existingURL ?? "(unknown)")
    }

    // MARK: - Install / refresh

    /// Insert or refresh the `daisy` entry, pointing it at `port`.
    /// Creates the Claude support directory and config file if missing.
    /// Direct write — no panel, no bookmark (see header).
    @discardableResult
    static func install(port: Int) -> InstallResult {
        let fm = FileManager.default
        let dir = claudeSupportDirectory

        do {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                log.info("Created Claude support dir at \(dir.path, privacy: .private)")
            }
            try mergeAndWrite(port: port, at: configFileURL)
            log.info("Wrote Daisy entry into \(self.configFileURL.path, privacy: .private)")
            return .installed(configFileURL)
        } catch {
            log.warning("Install failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    /// Silent refresh — used when the server comes up on a new port or
    /// the token setting changes, without the user pressing the button.
    /// Rewrites only an existing entry that isn't current, so we never
    /// create a config the user didn't ask for, and don't touch the
    /// file when nothing changed. Swallows errors (e.g. the user made
    /// the file malformed since install) — the next manual press
    /// surfaces them properly.
    static func refreshIfInstalled(port: Int) {
        guard case .installedDifferentPort = entryState(port: port) else { return }
        _ = install(port: port)
    }

    /// Remove the `daisy` entry, preserving every other server + key.
    /// No-op (returns `.notPresent`) if there's nothing to remove.
    @discardableResult
    static func remove() -> RemoveResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configFileURL.path),
              let data = try? Data(contentsOf: configFileURL),
              !data.isEmpty else {
            return .notPresent
        }
        do {
            let parsed = try JSONSerialization.jsonObject(with: data, options: [])
            guard var root = parsed as? [String: Any] else {
                throw configError("Existing config isn't a JSON object — refusing to edit it.")
            }
            guard var mcpServers = root["mcpServers"] as? [String: Any],
                  mcpServers["daisy"] != nil else {
                return .notPresent
            }
            mcpServers.removeValue(forKey: "daisy")
            // Drop the mcpServers object entirely if it's now empty, so
            // we don't leave a stray `"mcpServers": {}` behind.
            if mcpServers.isEmpty {
                root.removeValue(forKey: "mcpServers")
            } else {
                root["mcpServers"] = mcpServers
            }
            let out = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            try out.write(to: configFileURL, options: [.atomic])
            log.info("Removed Daisy entry from \(self.configFileURL.path, privacy: .private)")
            return .removed
        } catch let nsError as NSError where nsError.domain == "ClaudeDesktopConfig" {
            return .failed(nsError.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - JSON merge

    /// Read existing JSON (if any), merge `mcpServers.daisy = {…}`,
    /// write back atomically. Refuses to overwrite a file whose
    /// contents aren't a JSON object — that almost certainly means the
    /// user has hand-written something we'd silently destroy.
    private static func mergeAndWrite(port: Int, at url: URL) throws {
        let fm = FileManager.default

        var root: [String: Any] = [:]
        if fm.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           !data.isEmpty {
            do {
                let parsed = try JSONSerialization.jsonObject(with: data, options: [])
                guard let dict = parsed as? [String: Any] else {
                    throw configError(
                        "Existing config isn't a JSON object — refusing to overwrite. Open the file and check it manually."
                    )
                }
                root = dict
            } catch let nsError as NSError where nsError.domain == "ClaudeDesktopConfig" {
                throw nsError
            } catch {
                throw configError(
                    "Existing config has invalid JSON — refusing to overwrite. Open the file, fix the syntax, and try again."
                )
            }
        }

        // Preserve every other mcpServers entry — only mutate ours.
        //
        // Claude's config takes only stdio servers (`command` + `args`),
        // no URL — so the entry is Daisy's sh + curl bridge, which needs
        // nothing installed. See `MCPStdioBridge`.
        var mcpServers = root["mcpServers"] as? [String: Any] ?? [:]
        mcpServers["daisy"] = [
            "command": MCPStdioBridge.command,
            "args": bridgeArguments(port: port)
        ]
        root["mcpServers"] = mcpServers

        // .sortedKeys keeps diffs stable when the user has the file
        // under git / Time Machine. .prettyPrinted because the user is
        // going to open this file at some point.
        let out = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try out.write(to: url, options: [.atomic])
    }

    /// The bridge's arguments with the token when one is required, so
    /// Claude keeps working without the user copying anything.
    private static func bridgeArguments(port: Int) -> [String] {
        MCPStdioBridge.arguments(port: port, token: MCPAccessToken.isRequired ? MCPAccessToken.ensure() : nil)
    }

    private static func configError(_ message: String) -> NSError {
        NSError(
            domain: "ClaudeDesktopConfig",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

}
