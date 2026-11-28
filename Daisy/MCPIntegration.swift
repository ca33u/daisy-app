// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  MCPIntegration.swift
//  Daisy
//
//  User-configured MCP servers Daisy can push session content into
//  (Notion, Linear, Asana, whatever exposes MCP tools). Each
//  integration is a small Codable record persisted as JSON in
//  UserDefaults under "daisy.mcpIntegrations".
//
//  Distinct from `mcpSummarizer.*` settings — those describe a
//  single MCP server used for LLM summarization. Integrations here
//  are an arbitrary-length list of destinations the user can fan
//  finished sessions out to.
//

import Foundation
import Observation
import os
// `Array.remove(atOffsets:)` (used by MCPIntegrationStore.remove(at:))
// is an extension SwiftUI ships for IndexSet-based deletion from
// ForEach/.onDelete handlers. Linking SwiftUI here keeps the store
// usable from both Form rows and any future drag-reorder UI.
import SwiftUI

// MARK: - Model

/// Underlying transport for a destination — either MCP (JSON-RPC
/// over HTTP/SSE, talks to a real MCP server) or a plain webhook
/// POST. Stored as a string in JSON so future kinds can be added
/// without breaking the decoder on older saves.
nonisolated enum DestinationKind: String, Codable, Sendable, CaseIterable {
    case mcp
    case webhook
}

/// One user-configured destination. Sendable + Codable so it
/// round-trips through UserDefaults cleanly.
///
/// Despite the historical `MCPIntegration` name (kept for binary
/// compatibility with stored data), the type now covers both MCP
/// servers and plain HTTP webhooks — `kind` discriminates. A
/// rename would invalidate every previously-saved JSON record, so
/// the legacy spelling stays.
nonisolated struct MCPIntegration: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var name: String
    /// For `.mcp` — JSON-RPC HTTP endpoint of the MCP server. For
    /// `.webhook` — destination URL the JSON body is POSTed to.
    var baseURL: String
    /// MCP tool name. Ignored for `.webhook` (no tool concept on a
    /// plain HTTP endpoint).
    var toolName: String
    /// For `.mcp` — JSON template for the tool's `arguments`. For
    /// `.webhook` — JSON body POSTed verbatim to `baseURL` after
    /// placeholder substitution. Same placeholder set in both
    /// cases: {{title}}, {{date}}, {{summary}},
    /// {{actionItems}}, {{actionItemsBullets}},
    /// {{clientFollowUp}}, {{transcript}}, {{folder}}, {{locale}}.
    var argumentsTemplate: String
    var enabled: Bool
    /// Transport. Defaults to `.mcp` for back-compat with records
    /// saved before the field existed.
    var kind: DestinationKind = .mcp
    /// When true, this integration fires automatically after every
    /// session finishes (Stop & save → summary done). Independent of
    /// `enabled` — `enabled: false` removes the integration from
    /// every surface (kebab + auto-send), `enabled: true / autoOnSave: false`
    /// keeps it in the kebab as a manual destination only.
    /// Defaults to false for back-compat with already-saved data
    /// and to keep the "first time use is opt-in" property the
    /// Notion auto-send setting also has.
    var autoOnSave: Bool
    /// Folder slugs this integration's auto-send applies to. Empty
    /// set means "every folder" (default — most useful for users
    /// who only ever record one kind of session). When non-empty,
    /// auto-send fires only for sessions whose folder is in the
    /// set. Manual Send-to from the kebab ignores this entirely —
    /// the user explicitly picked the destination, so we trust them.
    var allowedFolders: Set<String> = []
    /// Optional bearer token for `.webhook` transport — sent as
    /// `Authorization: Bearer <token>` on each POST. Required for
    /// REST APIs that don't accept the request without auth (Attio,
    /// Linear REST, most SaaS). Ignored for `.mcp` (MCP handles
    /// auth differently, usually via the server config).
    ///
    /// SECURITY: this value is NOT encoded into the UserDefaults JSON
    /// (see `encode(to:)`) — `MCPIntegrationStore` persists it in the
    /// Keychain keyed by this integration's `id`, and hydrates it back on
    /// load. It lives on the struct in-memory only. (Legacy records that
    /// still carry an inline token decode it once for migration.)
    var bearerToken: String = ""

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        toolName: String,
        argumentsTemplate: String,
        enabled: Bool = true,
        autoOnSave: Bool = false,
        kind: DestinationKind = .mcp,
        allowedFolders: Set<String> = [],
        bearerToken: String = ""
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.toolName = toolName
        self.argumentsTemplate = argumentsTemplate
        self.enabled = enabled
        self.autoOnSave = autoOnSave
        self.kind = kind
        self.allowedFolders = allowedFolders
        self.bearerToken = bearerToken
    }

    // Manual Codable conformance so existing UserDefaults entries
    // (pre-autoOnSave / pre-kind / pre-allowedFolders / pre-bearerToken)
    // decode cleanly with the new fields defaulting — Swift's
    // synthesized `init(from:)` would throw on a missing key
    // otherwise.
    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, toolName, argumentsTemplate, enabled, autoOnSave, kind, allowedFolders, bearerToken
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.baseURL = try c.decode(String.self, forKey: .baseURL)
        self.toolName = try c.decode(String.self, forKey: .toolName)
        self.argumentsTemplate = try c.decode(String.self, forKey: .argumentsTemplate)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.autoOnSave = try c.decodeIfPresent(Bool.self, forKey: .autoOnSave) ?? false
        self.kind = try c.decodeIfPresent(DestinationKind.self, forKey: .kind) ?? .mcp
        self.allowedFolders = try c.decodeIfPresent(Set<String>.self, forKey: .allowedFolders) ?? []
        self.bearerToken = try c.decodeIfPresent(String.self, forKey: .bearerToken) ?? ""
    }

    /// Encodes everything EXCEPT `bearerToken` — the token is a secret and
    /// lives in the Keychain, not the UserDefaults JSON. (Decode still reads
    /// a legacy inline token so `MCPIntegrationStore` can migrate it.)
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(toolName, forKey: .toolName)
        try c.encode(argumentsTemplate, forKey: .argumentsTemplate)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(autoOnSave, forKey: .autoOnSave)
        try c.encode(kind, forKey: .kind)
        try c.encode(allowedFolders, forKey: .allowedFolders)
        // bearerToken intentionally omitted.
    }

    // MARK: - Starter presets

    /// Notion shape: assumes a `create_page` tool that takes a
    /// parent database id, a title, and a content block array.
    /// Most Notion-MCP wrappers follow this shape (see
    /// modelcontextprotocol/server-notion).
    static func notionDefault() -> MCPIntegration {
        MCPIntegration(
            name: "Notion",
            baseURL: "http://127.0.0.1:11436",
            toolName: "create_page",
            argumentsTemplate: """
            {
              "parent": {"database_id": "<your-database-id>"},
              "properties": {
                "Name": {
                  "title": [{"text": {"content": "{{title}}"}}]
                }
              },
              "children": [
                {"type": "heading_2", "heading_2": {"rich_text": [{"text": {"content": "Meeting"}}]}},
                {"type": "paragraph", "paragraph": {"rich_text": [{"text": {"content": "{{summary}}"}}]}},
                {"type": "heading_2", "heading_2": {"rich_text": [{"text": {"content": "Next actions"}}]}},
                {"type": "paragraph", "paragraph": {"rich_text": [{"text": {"content": "{{actionItemsBullets}}"}}]}},
                {"type": "heading_2", "heading_2": {"rich_text": [{"text": {"content": "Follow-up"}}]}},
                {"type": "paragraph", "paragraph": {"rich_text": [{"text": {"content": "{{clientFollowUp}}"}}]}}
              ]
            }
            """,
            enabled: true
        )
    }

    /// Generic webhook starter — POST a Slack-compatible incoming
    /// webhook body. Most chat platforms (Slack, Discord, Mattermost,
    /// Rocket.Chat) accept this shape; for a fully custom endpoint
    /// the user just edits `argumentsTemplate`.
    static func webhookDefault() -> MCPIntegration {
        MCPIntegration(
            name: "Webhook",
            baseURL: "https://hooks.slack.com/services/<your-webhook-path>",
            toolName: "",
            argumentsTemplate: """
            {
              "text": "*{{title}}*\\n\\n{{summary}}\\n\\n*Next actions*\\n{{actionItemsBullets}}"
            }
            """,
            enabled: true,
            kind: .webhook
        )
    }

    /// Attio shape: POST to `/v2/objects/notes/records` to create
    /// a meeting note. Attio requires a `parent_object` +
    /// `parent_record_id` pair so the note attaches to a person or
    /// company in the user's workspace — the placeholders for those
    /// fields are left as `<...>` so the user can paste their own
    /// record id (workspaces vary; Daisy can't know which contact
    /// the meeting was with). Token is a Personal Access Token
    /// created at app.attio.com → Settings → API.
    static func attioDefault() -> MCPIntegration {
        MCPIntegration(
            name: "Attio",
            baseURL: "https://api.attio.com/v2/objects/notes/records",
            toolName: "",
            argumentsTemplate: """
            {
              "data": {
                "parent_object": "<people-or-companies>",
                "parent_record_id": "<your-attio-record-id>",
                "title": "{{title}}",
                "format": "markdown",
                "content": "## Summary\\n\\n{{summary}}\\n\\n## Next actions\\n\\n{{actionItemsBullets}}\\n\\n## Follow-up\\n\\n{{clientFollowUp}}"
              }
            }
            """,
            enabled: true,
            kind: .webhook
        )
    }

    /// Linear shape: `create_issue` tool taking team id, title,
    /// description. One issue per session — action items go into
    /// the description as a checkbox list.
    static func linearDefault() -> MCPIntegration {
        MCPIntegration(
            name: "Linear",
            baseURL: "http://127.0.0.1:11437",
            toolName: "create_issue",
            argumentsTemplate: """
            {
              "teamId": "<your-team-id>",
              "title": "{{title}}",
              "description": "## Meeting\\n\\n{{summary}}\\n\\n## Next actions\\n\\n{{actionItemsBullets}}\\n\\n## Follow-up\\n\\n{{clientFollowUp}}"
            }
            """,
            enabled: true
        )
    }
}

// MARK: - Store

@Observable
@MainActor
final class MCPIntegrationStore {
    static let shared = MCPIntegrationStore()

    private(set) var integrations: [MCPIntegration] = []

    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "MCPIntegrationStore")
    @ObservationIgnored
    private let defaults = UserDefaults.standard
    @ObservationIgnored
    private static let storageKey = "daisy.mcpIntegrations"

    private init() {
        load()
    }

    // MARK: - Public CRUD

    func add(_ integration: MCPIntegration) {
        integrations.append(integration)
        save()
    }

    func update(_ integration: MCPIntegration) {
        guard let idx = integrations.firstIndex(where: { $0.id == integration.id }) else { return }
        integrations[idx] = integration
        save()
    }

    func remove(id: UUID) {
        integrations.removeAll(where: { $0.id == id })
        _ = KeychainStore.remove(account: Self.tokenAccount(id))
        save()
    }

    func remove(at offsets: IndexSet) {
        for i in offsets where integrations.indices.contains(i) {
            _ = KeychainStore.remove(account: Self.tokenAccount(integrations[i].id))
        }
        integrations.remove(atOffsets: offsets)
        save()
    }

    /// Enabled integrations only — what we surface in per-session
    /// menus and in the dispatcher.
    var enabledIntegrations: [MCPIntegration] {
        integrations.filter { $0.enabled }
    }

    /// Subset that should auto-fire after Stop & save. Subset of
    /// `enabledIntegrations` — auto-on-save implies enabled.
    var autoOnSaveIntegrations: [MCPIntegration] {
        integrations.filter { $0.enabled && $0.autoOnSave }
    }

    // MARK: - Persistence

    /// Keychain account for an integration's bearer token.
    private static func tokenAccount(_ id: UUID) -> String {
        "daisy.mcpToken.\(id.uuidString)"
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        do {
            var decoded = try JSONDecoder().decode([MCPIntegration].self, from: data)
            var didMigrate = false
            for i in decoded.indices {
                let account = Self.tokenAccount(decoded[i].id)
                if let stored = KeychainStore.get(account: account), !stored.isEmpty {
                    decoded[i].bearerToken = stored
                } else if !decoded[i].bearerToken.isEmpty {
                    // Legacy inline token → move it into the Keychain, then
                    // the save() below rewrites the JSON without it.
                    try? KeychainStore.set(decoded[i].bearerToken, account: account)
                    didMigrate = true
                }
            }
            integrations = decoded
            if didMigrate { save() }
        } catch {
            log.error("Failed to decode integrations: \(error.localizedDescription, privacy: .public). Resetting to empty.")
            integrations = []
        }
    }

    private func save() {
        // Bearer tokens go to the Keychain (never the JSON). Encode omits
        // them via MCPIntegration.encode(to:).
        for integration in integrations {
            let account = Self.tokenAccount(integration.id)
            if integration.bearerToken.isEmpty {
                _ = KeychainStore.remove(account: account)
            } else {
                try? KeychainStore.set(integration.bearerToken, account: account)
            }
        }
        do {
            let data = try JSONEncoder().encode(integrations)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            log.error("Failed to encode integrations: \(error.localizedDescription, privacy: .public)")
        }
    }
}
