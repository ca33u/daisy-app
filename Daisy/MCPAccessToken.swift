// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  MCPAccessToken.swift
//  Daisy
//
//  Access control for the local MCP server, closing the two local
//  vectors the loopback bind + Host/Origin guards can't:
//
//   1. AUTH — without it, ANY process running as the user can read
//      every transcript over plain HTTP on 127.0.0.1. A bearer token
//      (Keychain-stored, auto-injected into the Claude Desktop config
//      Daisy writes) limits access to clients the user actually set up.
//   2. ACTIONS — `resummarize_session` can send a transcript to a
//      CLOUD provider on the user's API key; `route_session_to_
//      destination` pushes a transcript to an outbound destination
//      (webhook / Notion / …). A prompt-injected client calling these
//      turns "read my notes" into exfiltration — so they are OFF by
//      default behind an explicit opt-in in Connections → MCP server.
//
//  Migration-aware default for the token: installs that already had
//  the MCP server enabled keep it OFF (flipping it on at update time
//  would silently break every manually-configured client — Cursor,
//  Cline, …) and see a recommendation in Connections instead; fresh
//  setups start secure.
//
//  Everything here is `nonisolated`: UserDefaults, Keychain, and
//  SecRandomCopyBytes are thread-safe, and callers live on both the
//  MainActor (UI, server routing) and detached contexts.
//

import Foundation
import Security

enum MCPAccessToken {
    nonisolated private static let keychainAccount = "daisy.mcp.accessToken"
    nonisolated static let k_required = "daisy.mcpRequireToken"
    nonisolated static let k_allowExternalActions = "daisy.mcpAllowExternalActions"

    /// Whether requests must carry `Authorization: Bearer <token>`.
    /// First read resolves the migration-aware default and persists it.
    nonisolated static var isRequired: Bool {
        get {
            let d = UserDefaults.standard
            if let v = d.object(forKey: k_required) as? Bool { return v }
            let hadServer = d.bool(forKey: "daisy.mcpServerEnabled")
            d.set(!hadServer, forKey: k_required)
            return !hadServer
        }
        set { UserDefaults.standard.set(newValue, forKey: k_required) }
    }

    /// External-effect tools (`resummarize_session`,
    /// `route_session_to_destination`) — read-only by default.
    nonisolated static var allowExternalActions: Bool {
        get { UserDefaults.standard.bool(forKey: k_allowExternalActions) }
        set { UserDefaults.standard.set(newValue, forKey: k_allowExternalActions) }
    }

    /// Current token, generating + persisting one on first use.
    /// 32 random bytes, base64url (no padding) — header/JSON safe.
    nonisolated static func ensure() -> String {
        if let existing = KeychainStore.get(account: keychainAccount), !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try? KeychainStore.set(token, account: keychainAccount)
        return token
    }

    /// Validate a presented `Authorization` header. Always true when
    /// the token requirement is off. Constant-time comparison — not
    /// strictly needed on loopback, but it costs nothing.
    nonisolated static func authorize(header: String?) -> Bool {
        guard isRequired else { return true }
        guard let header else { return false }
        let expected = "Bearer " + ensure()
        guard header.utf8.count == expected.utf8.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(header.utf8, expected.utf8) { diff |= a ^ b }
        return diff == 0
    }
}
