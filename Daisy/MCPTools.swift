//
//  MCPTools.swift
//  Daisy
//
//  Daisy-specific tools the MCP server exposes over the loopback-only,
//  single-client MCP server (see MCPServer.swift for the unchanged
//  transport + security posture). The catalog is split into READ
//  tools and a small set of SAFE ACTION (write) tools.
//
//  Read tools (no mutation):
//
//   • list_sessions    — paginated session metadata, optional filters
//   • get_session      — full session: transcript + summary + attendees
//   • search_sessions  — substring search over title / transcript /
//                        summary; returns hits with snippets
//   • list_folders     — available folder names
//   • list_destinations — configured export destinations (Notion /
//                        Linear / Slack / webhook / MCP) by name
//
//  Action tools (MUTATE on-device state, reversible/benign only):
//
//   • resummarize_session       — regenerate summary.json via the
//                                 user's configured LLM provider
//   • set_session_title         — rewrite the session's title
//   • rename_speaker            — map a transcript speaker id → name
//                                 (and seed a SpeakerProfile)
//   • route_session_to_destination — push a session to a configured
//                                 destination
//
//  Every action tool reuses the EXACT store/service the SwiftUI UI
//  uses (SessionStore / Summarizer / SpeakerProfileStore /
//  MCPIntegrationStore + MCPDispatcher) so a change made by an agent
//  is persisted the same way and shows up in Daisy's UI. There is no
//  parallel mutation path. Deliberately ABSENT: any destructive or
//  irreversible op (no delete of sessions/audio/transcripts, no
//  settings/credential mutation, no change to the MCP server's own
//  config or network binding) — see the note above `actionCatalog()`.
//
//  Each tool returns a single text block of JSON — clients can parse
//  it directly. (MCP allows multiple block types but text + JSON is
//  the most portable.)
//

import Foundation

@MainActor
enum MCPTools {

    // MARK: - Catalog

    /// Annotations every READ tool shares: mutates nothing, has
    /// nothing to destroy, calling it twice is the same as calling it
    /// once, and the only world it touches is this Mac's own session
    /// archive (no network, no external service).
    ///
    /// We spell out all four hints instead of leaning on defaults
    /// because the MCP defaults are the pessimistic ones
    /// (`destructiveHint` and `openWorldHint` both default to TRUE),
    /// so an omitted annotation reads as "destructive, open-world".
    private static func readOnlyAnnotations(_ title: String) -> MCPToolAnnotations {
        MCPToolAnnotations(
            title: title,
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    }

    /// Advertise the full toolset to the MCP client via `tools/list`.
    /// JSON Schemas are hand-rolled as AnyJSON literals.
    static func catalog() -> [MCPTool] {
        [
            MCPTool(
                name: "list_sessions",
                description: "List Daisy meeting sessions. Returns metadata only (no transcripts). Use this to discover what's available, then call get_session for the body.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "folder": .object([
                            "type": .string("string"),
                            "description": .string("Filter by folder slug (e.g. 'inbox', 'work', 'personal'). Omit to include all folders.")
                        ]),
                        "since": .object([
                            "type": .string("string"),
                            "format": .string("date-time"),
                            "description": .string("Only return sessions started at or after this ISO-8601 timestamp.")
                        ]),
                        "until": .object([
                            "type": .string("string"),
                            "format": .string("date-time"),
                            "description": .string("Only return sessions started before this ISO-8601 timestamp.")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of sessions to return. Default 50, max 500."),
                            "minimum": .int(1),
                            "maximum": .int(500)
                        ])
                    ]),
                    "additionalProperties": .bool(false)
                ]),
                annotations: readOnlyAnnotations("List sessions")
            ),
            MCPTool(
                name: "get_session",
                description: "Get the full content of one session: title, timestamps, duration, attendees, transcript, summary (if present), screenshot URLs.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("Session id as returned by list_sessions.")
                        ])
                    ]),
                    "required": .array([.string("id")]),
                    "additionalProperties": .bool(false)
                ]),
                annotations: readOnlyAnnotations("Get session")
            ),
            MCPTool(
                name: "search_sessions",
                description: "Substring search across session titles, transcripts, and summary fields. Returns hits with a short snippet so the model can decide which to fetch in full.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Free-text query. Case-insensitive substring match.")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of hits. Default 20, max 200."),
                            "minimum": .int(1),
                            "maximum": .int(200)
                        ])
                    ]),
                    "required": .array([.string("query")]),
                    "additionalProperties": .bool(false)
                ]),
                annotations: readOnlyAnnotations("Search sessions")
            ),
            MCPTool(
                name: "list_folders",
                description: "List the folder slugs and display names the user has set up. Use these as the `folder` argument to list_sessions.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "additionalProperties": .bool(false)
                ]),
                annotations: readOnlyAnnotations("List folders")
            ),
            MCPTool(
                name: "list_destinations",
                description: "List the export destinations the user has configured (Notion, Linear, Slack, a webhook, or another MCP server). Read-only. Returns each destination's id, name, and kind. Use a returned id or name as the `destination` argument to route_session_to_destination.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "additionalProperties": .bool(false)
                ]),
                annotations: readOnlyAnnotations("List destinations")
            ),
        ] + actionCatalog()
    }

    /// The SAFE action (write) tools. Kept in a separate builder so
    /// the read/write split is obvious at a glance and so the header
    /// comment's "reversible/benign only" contract has one place to
    /// audit. Each schema marks `additionalProperties: false` and
    /// lists `required` args so a client can't silently pass an
    /// argument we ignore.
    ///
    /// NOT exposed here, on purpose:
    ///   • delete / bulk-delete sessions or purge audio/transcripts —
    ///     irreversible, no MCP affordance by design.
    ///   • retranscribe — Daisy's transcription pipeline only runs as
    ///     a live AsyncStream during a recording; there is no
    ///     standalone "re-run Whisper over an archived .caf and
    ///     rewrite transcript.md" code path to reuse, so exposing it
    ///     would mean building a parallel mutation path (forbidden).
    ///   • any settings / API-key / provider / server-config or
    ///     network-binding mutation.
    ///
    /// Annotations here say `destructiveHint: false` for all four:
    /// nothing in this list removes user content. `set_session_title`
    /// and `rename_speaker` overwrite one field and are undone by
    /// calling them again with the old value; `route_session_…` only
    /// ADDS a record on the destination side; `resummarize_session`
    /// replaces a DERIVED artefact (summary.json) that Daisy can
    /// regenerate — the transcript and audio it came from are never
    /// touched. The "the previous summary is not kept" caveat lives in
    /// that tool's description, where a model will actually read it.
    ///
    /// `openWorldHint` is NOT uniformly false, unlike the read tools:
    /// `resummarize_session` can hand the transcript to a cloud LLM on
    /// the user's key, and `route_session_to_destination` posts to
    /// Notion / Linear / Slack / a webhook. Those two genuinely reach
    /// an open world — which is exactly why they're the two gated
    /// behind `allowExternalActions`. Claiming otherwise would hide
    /// the one property a client most needs to warn about.
    private static func actionCatalog() -> [MCPTool] {
        [
            MCPTool(
                name: "resummarize_session",
                description: "MUTATES the session. Regenerate the meeting summary (the 'Re-summarize' / enhance action) for a session that has a transcript, using the user's currently-configured summary provider, and overwrite its stored summary. Use this to refresh a summary after editing speaker names, or to (re)generate one for a session that has none. The whole summary (overview, sections, action items, follow-up) is replaced. Optionally pin the output language with `language`. Cannot pick a provider — it uses whatever the user selected in Daisy's settings.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("Session id as returned by list_sessions / search_sessions.")
                        ]),
                        "language": .object([
                            "type": .string("string"),
                            "description": .string("Optional ISO 639-1 code (e.g. 'en', 'ru', 'ja') to force the summary's output language. Omit to use the session's auto-detected language — the same default Daisy's own Re-summarize button uses.")
                        ])
                    ]),
                    "required": .array([.string("id")]),
                    "additionalProperties": .bool(false)
                ]),
                annotations: MCPToolAnnotations(
                    title: "Re-summarize session",
                    readOnlyHint: false,
                    destructiveHint: false,
                    // Not idempotent: every call re-runs the model, so
                    // the stored summary changes (and tokens are spent)
                    // even with identical arguments.
                    idempotentHint: false,
                    // May leave the Mac — the user's configured summary
                    // provider can be a cloud API.
                    openWorldHint: true
                )
            ),
            MCPTool(
                name: "set_session_title",
                description: "MUTATES the session. Rename a session — rewrites the `title` of the session's transcript and updates Daisy's History list. Reversible (call again with the old title). Title must be non-empty.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("Session id as returned by list_sessions / search_sessions.")
                        ]),
                        "title": .object([
                            "type": .string("string"),
                            "description": .string("New title. Non-empty after trimming whitespace.")
                        ])
                    ]),
                    "required": .array([.string("id"), .string("title")]),
                    "additionalProperties": .bool(false)
                ]),
                annotations: MCPToolAnnotations(
                    title: "Rename session",
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: true,
                    openWorldHint: false
                )
            ),
            MCPTool(
                name: "rename_speaker",
                description: "MUTATES the session. Assign a real name to a diarized speaker in a session (the 'Name the speakers' action) — e.g. label speaker 'A' as 'Alex'. Updates the session's speaker map so the transcript renders the name, and (when the session has a saved voice fingerprint for that speaker) seeds/updates a reusable SpeakerProfile so the same voice is auto-labelled in future recordings. Reversible: pass an empty `name` to clear the mapping for that speaker (this does NOT delete any SpeakerProfile). Speaker ids are the short labels in the transcript (the letter after 'Remote ' — 'A', 'B', …); call get_session to see which ids exist.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("Session id as returned by list_sessions / search_sessions.")
                        ]),
                        "speaker_id": .object([
                            "type": .string("string"),
                            "description": .string("Transcript speaker label to rename, e.g. 'A' or 'B' (the part after 'Remote ' in the transcript).")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Real name to assign, e.g. 'Alex'. Pass an empty string to clear this speaker's mapping.")
                        ])
                    ]),
                    "required": .array([.string("id"), .string("speaker_id"), .string("name")]),
                    "additionalProperties": .bool(false)
                ]),
                annotations: MCPToolAnnotations(
                    title: "Name a speaker",
                    readOnlyHint: false,
                    destructiveHint: false,
                    // Same id + speaker + name twice lands on the same
                    // mapping; the SpeakerProfile seed is upsert-shaped.
                    idempotentHint: true,
                    openWorldHint: false
                )
            ),
            MCPTool(
                name: "route_session_to_destination",
                description: "MUTATES external state (creates a page/issue/message on the destination). Push a finished session to one of the user's configured, enabled destinations (Notion / Linear / Slack / webhook / another MCP server) — the same 'Send to …' action in Daisy's UI. Identify the destination by its id or name from list_destinations. Re-sending creates another record on the destination side (Daisy does not de-duplicate). Does not modify the session itself.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("Session id as returned by list_sessions / search_sessions.")
                        ]),
                        "destination": .object([
                            "type": .string("string"),
                            "description": .string("Destination id (preferred) or exact name from list_destinations. Must be an enabled destination.")
                        ])
                    ]),
                    "required": .array([.string("id"), .string("destination")]),
                    "additionalProperties": .bool(false)
                ]),
                annotations: MCPToolAnnotations(
                    title: "Send session to a destination",
                    readOnlyHint: false,
                    // Purely additive on the destination side — it
                    // creates a record, never edits or removes one.
                    destructiveHint: false,
                    // Explicitly NOT idempotent: Daisy does not
                    // de-duplicate, so a second call creates a second
                    // page / issue / message.
                    idempotentHint: false,
                    // Posts to Notion / Linear / Slack / a webhook.
                    openWorldHint: true
                )
            ),
        ]
    }

    // MARK: - Dispatch

    /// Route a `tools/call` to the right handler. Errors are returned
    /// as `MCPToolCallResult.error(_:)` rather than thrown — that
    /// surface lets the LLM-side see structured error text, which is
    /// usually more useful than a hard protocol failure.
    /// Structured refusal for the gated external-effect tools — the
    /// client-side LLM gets an actionable explanation instead of a
    /// bare protocol error, and the user learns exactly where the
    /// opt-in lives.
    private static func externalActionsDisabled(tool: String) -> MCPToolCallResult {
        .error("\(tool) is disabled. External actions (re-summarize, route to destination) can send transcript content to a cloud provider or an outbound destination, so they're off by default. The user can enable them in Daisy → Connections → MCP server → \"Allow actions from MCP clients\".")
    }

    static func call(name: String, arguments: AnyJSON?) async -> MCPToolCallResult {
        do {
            switch name {
            case "list_sessions":
                let args = try arguments?.decoded(as: ListSessionsArgs.self) ?? .init()
                return try await listSessions(args: args)
            case "get_session":
                let args = try arguments?.decoded(as: GetSessionArgs.self)
                    ?? { throw MCPToolError.missingArgument("id") }()
                return try await getSession(args: args)
            case "search_sessions":
                let args = try arguments?.decoded(as: SearchSessionsArgs.self)
                    ?? { throw MCPToolError.missingArgument("query") }()
                return try await searchSessions(args: args)
            case "list_folders":
                return await listFolders()
            case "list_destinations":
                return await listDestinations()

            // ── Action (write) tools ────────────────────────────────
            // The two EXTERNAL-EFFECT tools are read-only-gated:
            // resummarize can send the transcript to a cloud provider on
            // the user's API key; route_session pushes it to an outbound
            // destination. A prompt-injected client calling these turns
            // "read my notes" into exfiltration — off unless the user
            // opted in (Connections → MCP server). set_session_title /
            // rename_speaker stay available: purely local edits.
            case "resummarize_session":
                guard MCPAccessToken.allowExternalActions else {
                    return Self.externalActionsDisabled(tool: name)
                }
                let args = try arguments?.decoded(as: ResummarizeArgs.self)
                    ?? { throw MCPToolError.missingArgument("id") }()
                return await resummarizeSession(args: args)
            case "set_session_title":
                let args = try arguments?.decoded(as: SetTitleArgs.self)
                    ?? { throw MCPToolError.missingArgument("id") }()
                return await setSessionTitle(args: args)
            case "rename_speaker":
                let args = try arguments?.decoded(as: RenameSpeakerArgs.self)
                    ?? { throw MCPToolError.missingArgument("id") }()
                return await renameSpeaker(args: args)
            case "route_session_to_destination":
                guard MCPAccessToken.allowExternalActions else {
                    return Self.externalActionsDisabled(tool: name)
                }
                let args = try arguments?.decoded(as: RouteSessionArgs.self)
                    ?? { throw MCPToolError.missingArgument("id") }()
                return await routeSessionToDestination(args: args)

            default:
                return .error("Unknown tool: \(name)")
            }
        } catch let MCPToolError.missingArgument(name) {
            return .error("Missing required argument: \(name)")
        } catch {
            return .error("Tool execution failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Argument shapes

    private struct ListSessionsArgs: Decodable {
        var folder: String?
        var since: String?
        var until: String?
        var limit: Int?
    }

    private struct GetSessionArgs: Decodable {
        let id: String
    }

    private struct SearchSessionsArgs: Decodable {
        let query: String
        var limit: Int?
    }

    private struct ResummarizeArgs: Decodable {
        let id: String
        var language: String?
    }

    private struct SetTitleArgs: Decodable {
        let id: String
        let title: String
    }

    private struct RenameSpeakerArgs: Decodable {
        let id: String
        let speaker_id: String
        let name: String
    }

    private struct RouteSessionArgs: Decodable {
        let id: String
        let destination: String
    }

    private enum MCPToolError: Error {
        case missingArgument(String)
    }

    // MARK: - Handlers

    private static func listSessions(args: ListSessionsArgs) async throws -> MCPToolCallResult {
        await SessionStore.shared.refresh()
        var pool = SessionStore.shared.sessions

        if let folder = args.folder, !folder.isEmpty {
            pool = pool.filter { $0.folderSlug == folder }
        }
        if let sinceStr = args.since, let since = parseISO8601(sinceStr) {
            pool = pool.filter { $0.startedAt >= since }
        }
        if let untilStr = args.until, let until = parseISO8601(untilStr) {
            pool = pool.filter { $0.startedAt < until }
        }
        let limit = max(1, min(args.limit ?? 50, 500))
        pool = Array(pool.prefix(limit))

        let payload: [SessionListItem] = pool.map(SessionListItem.init)
        return try .text(encodeJSON(payload))
    }

    private static func getSession(args: GetSessionArgs) async throws -> MCPToolCallResult {
        await SessionStore.shared.refresh()
        guard let session = SessionStore.shared.sessions.first(where: { $0.id == args.id }) else {
            return .error("No session with id: \(args.id)")
        }
        let payload = SessionFull(session)
        return try .text(encodeJSON(payload))
    }

    private static func searchSessions(args: SearchSessionsArgs) async throws -> MCPToolCallResult {
        await SessionStore.shared.refresh()
        let q = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .error("Query is empty.") }
        let limit = max(1, min(args.limit ?? 20, 200))

        // Index-prefiltered substring search via the shared store —
        // identical results to filtering on `matches(query:)` directly.
        let store = SessionStore.shared
        let hits = store.sessionsMatching(q, in: store.sessions)
            .prefix(limit)
            .map { SessionHit($0, query: q) }

        return try .text(encodeJSON(Array(hits)))
    }

    private static func listFolders() async -> MCPToolCallResult {
        let folders = FolderStore.shared.allFolders.map { f in
            FolderItem(slug: f.slug, name: f.name)
        }
        return (try? .text(encodeJSON(folders)))
            ?? .error("Couldn't encode folder list.")
    }

    /// Enabled export destinations only — same set Daisy surfaces in
    /// its per-session "Send to …" menu. We don't leak bearer tokens
    /// or URLs; just enough for the model to pick a target.
    private static func listDestinations() async -> MCPToolCallResult {
        let dests = MCPIntegrationStore.shared.enabledIntegrations.map { i in
            DestinationItem(
                id: i.id.uuidString,
                name: i.name,
                kind: i.kind.rawValue,
                auto_on_save: i.autoOnSave
            )
        }
        return (try? .text(encodeJSON(dests)))
            ?? .error("Couldn't encode destination list.")
    }

    // MARK: - Action handlers (MUTATE state — reuse the UI's stores)
    //
    // Each handler hops nowhere special: MCPTools is `@MainActor`, and
    // every store it touches (SessionStore / Summarizer /
    // SpeakerProfileStore / MCPIntegrationStore) is also `@MainActor`,
    // so these calls are already on the right actor — same as the read
    // handlers above. They resolve the session by id via the shared
    // SessionStore (the single source of truth) and then call the
    // identical methods the SwiftUI views call, so the on-disk write +
    // `@Observable` UI refresh happen exactly once, through one path.

    /// Re-resolve a session by id off a fresh store scan. Returns the
    /// `StoredSession` or an `MCPToolCallResult.error` the caller can
    /// return directly. A refresh first means an agent that just
    /// created a session (or the user just recorded one) sees it.
    private static func resolveSession(id: String) async -> Result<StoredSession, MCPToolCallResult> {
        await SessionStore.shared.refresh()
        guard let session = SessionStore.shared.sessions.first(where: { $0.id == id }) else {
            return .failure(.error("No session with id: \(id)"))
        }
        return .success(session)
    }

    private static func resummarizeSession(args: ResummarizeArgs) async -> MCPToolCallResult {
        let session: StoredSession
        switch await resolveSession(id: args.id) {
        case .success(let s): session = s
        case .failure(let e): return e
        }
        guard !session.transcriptText.isEmpty else {
            return .error("Session \(args.id) has no transcript to summarize.")
        }
        guard Summarizer.shared.availability == .available else {
            // Mirror the UI: a misconfigured/unavailable provider
            // should produce a clear, actionable message rather than a
            // generic failure after a long wait.
            let reason: String
            if case .unavailable(let r) = Summarizer.shared.availability { reason = r }
            else { reason = "The summary provider isn't ready. Check Daisy → Settings → Summary." }
            return .error("Can't summarize: \(reason)")
        }

        // Canonical locale resolver — identical to SessionDetailView's
        // Re-summarize button and the post-Stop auto-summary, so the
        // agent path can't drift to a different language. An explicit
        // `language` arg overrides; otherwise the session's own
        // detection/frontmatter decides.
        let overrideLanguage = args.language?.trimmingCharacters(in: .whitespacesAndNewlines)
        let localeHint = RecordingSession.resolveSummaryLocaleHint(
            transcript: session.transcriptText,
            transcriptLocale: session.locale,
            summaryLanguageOverride: (overrideLanguage?.isEmpty == false)
                ? overrideLanguage!
                : AppSettings.currentSummaryLanguage
        )

        let result = await Summarizer.shared.summarize(
            transcript: session.transcriptText,
            title: session.title,
            localeHint: localeHint
        )
        guard let summary = result else {
            let err = Summarizer.shared.lastError ?? "the provider returned no summary"
            return .error("Re-summarize failed: \(err)")
        }
        // Same persistence the UI uses — writes summary.json + reloads.
        await SessionStore.shared.updateSummary(summary, for: session)
        return ack([
            "ok": .bool(true),
            "id": .string(session.id),
            "action": .string("resummarize_session"),
            "provider": .string(Summarizer.shared.providerKind.shortName),
            "summary_preview": .string(String(summary.summary.prefix(200))),
            "action_item_count": .int(summary.actionItems.count)
        ])
    }

    private static func setSessionTitle(args: SetTitleArgs) async -> MCPToolCallResult {
        let trimmed = args.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .error("Title can't be empty.")
        }
        let session: StoredSession
        switch await resolveSession(id: args.id) {
        case .success(let s): session = s
        case .failure(let e): return e
        }
        let previous = session.title
        // Same on-disk frontmatter write the History rename would use.
        await SessionStore.shared.setTitle(trimmed, for: session)
        if let err = SessionStore.shared.lastError {
            return .error("Couldn't set title: \(err)")
        }
        return ack([
            "ok": .bool(true),
            "id": .string(session.id),
            "action": .string("set_session_title"),
            "previous_title": .string(previous),
            "title": .string(trimmed)
        ])
    }

    private static func renameSpeaker(args: RenameSpeakerArgs) async -> MCPToolCallResult {
        let speakerID = args.speaker_id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speakerID.isEmpty else {
            return .error("speaker_id can't be empty.")
        }
        let session: StoredSession
        switch await resolveSession(id: args.id) {
        case .success(let s): session = s
        case .failure(let e): return e
        }

        let name = args.name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Build the new map the same way SessionDetailView.applyMapping
        // does: set on a non-empty name, remove the key on empty.
        var updated = session.speakerMap
        if name.isEmpty {
            updated.removeValue(forKey: speakerID)
        } else {
            updated[speakerID] = name
        }
        await SessionStore.shared.updateSpeakerMap(updated, for: session)
        if let err = SessionStore.shared.lastError {
            return .error("Couldn't update speaker map: \(err)")
        }

        // Seed/refresh a reusable voice profile when a real name was
        // assigned AND this session has a saved centroid for that
        // speaker — exact same gate + call as the UI. Skipped on clear
        // (we never delete profiles from here). `profileSeeded`
        // reports whether the fingerprint was available so the agent
        // gets honest feedback rather than implying future auto-label
        // when there's no centroid.
        var profileSeeded = false
        if !name.isEmpty,
           let centroids = loadSpeakerCentroids(for: session),
           let embedding = centroids[speakerID], !embedding.isEmpty {
            // nil ⇒ the store declined to enrol (unreadable profiles on
            // disk); report that honestly rather than promising future
            // auto-labelling that won't happen.
            profileSeeded = SpeakerProfileStore.shared.upsert(
                name: name, embedding: embedding
            ) != nil
        }

        return ack([
            "ok": .bool(true),
            "id": .string(session.id),
            "action": .string("rename_speaker"),
            "speaker_id": .string(speakerID),
            "name": .string(name),
            "cleared": .bool(name.isEmpty),
            "voice_profile_seeded": .bool(profileSeeded)
        ])
    }

    /// Read a session's `speakers.json` centroid sidecar. Mirrors
    /// SessionDetailView.loadSpeakerCentroids — returns nil for older
    /// sessions recorded before the voice-fingerprint flow (rename
    /// still works, it just won't seed a profile).
    private static func loadSpeakerCentroids(for session: StoredSession) -> [String: [Float]]? {
        let url = session.directoryURL.appendingPathComponent("speakers.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode(SpeakerCentroidsFile.self, from: data) else {
            return nil
        }
        return parsed.centroids
    }

    private static func routeSessionToDestination(args: RouteSessionArgs) async -> MCPToolCallResult {
        let session: StoredSession
        switch await resolveSession(id: args.id) {
        case .success(let s): session = s
        case .failure(let e): return e
        }

        // Resolve destination by id (preferred) then exact, then
        // case-insensitive name — only among ENABLED destinations,
        // matching what the UI's Send-to menu offers.
        let needle = args.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return .error("destination can't be empty.")
        }
        let enabled = MCPIntegrationStore.shared.enabledIntegrations
        guard !enabled.isEmpty else {
            return .error("No enabled destinations are configured. Add one in Daisy → Connections.")
        }
        let match = enabled.first(where: { $0.id.uuidString == needle })
            ?? enabled.first(where: { $0.name == needle })
            ?? enabled.first(where: { $0.name.lowercased() == needle.lowercased() })
        guard let integration = match else {
            let names = enabled.map(\.name).joined(separator: ", ")
            return .error("No enabled destination matches '\(needle)'. Available: \(names).")
        }

        // Same dispatcher the UI's "Send to …" button uses. It posts
        // its own success/error toast; we additionally surface the
        // boolean outcome to the agent.
        let ok = await MCPDispatcher.send(integration, for: session)
        guard ok else {
            return .error("Sending to \(integration.name) failed — check Daisy for the error detail.")
        }
        return ack([
            "ok": .bool(true),
            "id": .string(session.id),
            "action": .string("route_session_to_destination"),
            "destination_id": .string(integration.id.uuidString),
            "destination_name": .string(integration.name),
            "destination_kind": .string(integration.kind.rawValue)
        ])
    }

    /// Encode a small acknowledgement object as the tool's text/JSON
    /// result. Falls back to a plain "ok" string if encoding somehow
    /// fails (it won't for these scalar maps, but the surface stays
    /// non-throwing).
    private static func ack(_ fields: [String: AnyJSON]) -> MCPToolCallResult {
        let value = AnyJSON.object(fields)
        if let json = try? encodeJSON(value) {
            return .text(json)
        }
        return .text("{\"ok\":true}")
    }

    // MARK: - DTOs (Encodable)
    //
    // We deliberately re-shape StoredSession into MCP-friendly DTOs
    // rather than Encodable-conforming the existing types. Lets us
    // pick stable field names independent of internal refactors and
    // strip out heavy fields (raw audio URLs, etc.) from listings.

    private struct SessionListItem: Encodable {
        let id: String
        let title: String
        let started_at: String
        let duration_seconds: Int
        let folder: String
        let locale: String
        let has_summary: Bool
        let has_system_audio: Bool
        let attendees: [String]
        let preview: String

        init(_ s: StoredSession) {
            self.id = s.id
            self.title = s.title
            self.started_at = ISO8601DateFormatter().string(from: s.startedAt)
            self.duration_seconds = s.durationSec
            self.folder = s.folderSlug
            self.locale = s.locale
            self.has_summary = s.hasSummary
            self.has_system_audio = s.hasSystemAudio
            self.attendees = s.meetingAttendees
            self.preview = s.transcriptPreview
        }
    }

    private struct SessionFull: Encodable {
        let id: String
        let title: String
        let started_at: String
        let duration_seconds: Int
        let folder: String
        let locale: String
        let attendees: [String]
        let speaker_map: [String: String]
        let transcript: String
        let summary: SummaryDTO?
        let screenshot_urls: [String]
        let has_system_audio: Bool

        init(_ s: StoredSession) {
            self.id = s.id
            self.title = s.title
            self.started_at = ISO8601DateFormatter().string(from: s.startedAt)
            self.duration_seconds = s.durationSec
            self.folder = s.folderSlug
            self.locale = s.locale
            self.attendees = s.meetingAttendees
            self.speaker_map = s.speakerMap
            self.transcript = s.transcriptText
            self.summary = s.summary.map(SummaryDTO.init)
            self.screenshot_urls = s.screenshotURLs.map(\.absoluteString)
            self.has_system_audio = s.hasSystemAudio
        }
    }

    private struct SummaryDTO: Encodable {
        let meeting: String
        let next_actions: [String]
        let client_follow_up: String

        init(_ m: MeetingSummary) {
            self.meeting = m.summary
            self.next_actions = m.actionItems
            self.client_follow_up = m.clientFollowUp
        }
    }

    private struct SessionHit: Encodable {
        let id: String
        let title: String
        let started_at: String
        let snippet: String

        init(_ s: StoredSession, query: String) {
            self.id = s.id
            self.title = s.title
            self.started_at = ISO8601DateFormatter().string(from: s.startedAt)
            self.snippet = Self.makeSnippet(from: s.transcriptText, query: query)
        }

        private static func makeSnippet(from text: String, query: String, radius: Int = 80) -> String {
            let lower = text.lowercased()
            let q = query.lowercased()
            guard let range = lower.range(of: q) else {
                return String(text.prefix(160))
            }
            let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
            var snippet = String(text[start..<end])
            if start != text.startIndex { snippet = "…" + snippet }
            if end != text.endIndex { snippet = snippet + "…" }
            return snippet
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
    }

    private struct FolderItem: Encodable {
        let slug: String
        let name: String
    }

    private struct DestinationItem: Encodable {
        let id: String
        let name: String
        /// "mcp" or "webhook".
        let kind: String
        let auto_on_save: Bool
    }

    // MARK: - Helpers

    private static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions.insert(.withFractionalSeconds)
        return f.date(from: s)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
