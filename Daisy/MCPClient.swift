//
//  MCPClient.swift
//  Daisy
//
//  Tiny MCP client over the HTTP+SSE transport. Mirror of our own
//  MCPServer.swift but in the opposite direction: this connects to
//  someone else's MCP server and calls tools on it. Used by
//  MCPSummarizer to talk to a local LLM exposed via an MCP wrapper
//  (Ollama, llama.cpp, LM Studio, etc.).
//
//  Flow (per the 2024-11-05 MCP HTTP+SSE transport):
//   1. Open a long-lived GET on `<base>/sse` — server replies with
//      an `event: endpoint` carrying the URL we should POST to.
//   2. POST JSON-RPC requests to that endpoint. The server replies
//      202 Accepted; the actual JSON-RPC response is delivered as
//      `event: message` on our open SSE stream.
//   3. Correlate request ↔ response by JSON-RPC `id`. Pending
//      requests are continuations resolved when the SSE event for
//      that id arrives.
//
//  Scope: single-server-at-a-time. The summarizer keeps one client
//  alive per session — no connection pooling, no reconnect logic.
//

import Foundation
import os

// MARK: - Errors

nonisolated enum MCPClientError: LocalizedError {
    case invalidURL(String)
    case streamFailed(String)
    case noEndpointReceived
    case requestFailed(status: Int, body: String)
    case responseError(code: Int, message: String)
    case timeout
    case cancelled

    nonisolated var errorDescription: String? {
        switch self {
        case .invalidURL(let s):       return "Invalid MCP server URL: \(s)"
        case .streamFailed(let msg):   return "MCP SSE stream failed: \(msg)"
        case .noEndpointReceived:      return "MCP server didn't send an `endpoint` event within the handshake window."
        case .requestFailed(let s, let b):
            let trimmed = b.count > 200 ? String(b.prefix(200)) + "…" : b
            return "MCP POST failed (HTTP \(s)): \(trimmed)"
        case .responseError(let c, let m):
            return "MCP server returned error \(c): \(m)"
        case .timeout:                 return "MCP request timed out."
        case .cancelled:               return "MCP request was cancelled."
        }
    }
}

// MARK: - Client

@MainActor
final class MCPClient {
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "MCPClient")
    private let baseURL: URL
    private let session: URLSession

    /// URL the server told us to POST messages to, learned from the
    /// `endpoint` event on the SSE stream. Resolved relative to
    /// `baseURL` if the server sends a path.
    private var endpoint: URL?

    /// Pending requests keyed by JSON-RPC id, awaiting their SSE
    /// response. `String` keys handle both string and int ids
    /// uniformly — we always send strings.
    private var pending: [String: CheckedContinuation<JSONRPCResponse, Error>] = [:]

    /// Continuation that fires once the `endpoint` event arrives.
    /// Replaced on each `connect()`.
    private var endpointWaiter: CheckedContinuation<URL, Error>?

    /// SSE-reader task; owns the connection to `<base>/sse`. Cancel
    /// it to tear down the client.
    private var streamTask: Task<Void, Never>?

    private var nextID: Int = 0

    // MARK: - Lifecycle

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    deinit {
        streamTask?.cancel()
    }

    /// Open the SSE stream and wait for the server's `endpoint`
    /// event. After this returns we're ready to `callTool(...)`.
    /// Errors out if the handshake doesn't complete inside the
    /// timeout — common cause is wrong URL or server not running.
    func connect(handshakeTimeout: Duration = .seconds(5)) async throws {
        let sseURL = baseURL.appendingPathComponent("sse")
        var request = URLRequest(url: sseURL)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 0  // SSE is long-lived

        // Spawn the SSE reader. It outlives the `connect` call —
        // it stays alive until the client is torn down.
        streamTask = Task { [weak self] in
            await self?.readSSE(request: request)
        }

        // Wait for the endpoint event with a bounded timeout —
        // otherwise a silent / misconfigured server hangs us.
        let endpoint = try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { [weak self] in
                try await self?.waitForEndpoint() ?? { throw MCPClientError.cancelled }()
            }
            group.addTask {
                try await Task.sleep(for: handshakeTimeout)
                throw MCPClientError.noEndpointReceived
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        self.endpoint = endpoint
    }

    /// Tear down the SSE stream and fail any in-flight requests.
    func disconnect() {
        streamTask?.cancel()
        streamTask = nil
        let inflight = pending
        pending.removeAll()
        for (_, cont) in inflight {
            cont.resume(throwing: MCPClientError.cancelled)
        }
        endpointWaiter?.resume(throwing: MCPClientError.cancelled)
        endpointWaiter = nil
    }

    // MARK: - Public API

    /// MCP `initialize` handshake. Call once right after `connect()`.
    @discardableResult
    func initialize() async throws -> MCPInitializeResult {
        let result = try await send(
            method: "initialize",
            params: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("Daisy"),
                    "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0")
                ])
            ])
        )
        // Fire-and-forget the required `initialized` notification.
        try await sendNotification(method: "notifications/initialized")
        return try result.decoded(as: MCPInitializeResult.self)
    }

    /// MCP `tools/list` — useful for the Test connection button to
    /// confirm the server is reachable and what tools it advertises.
    func listTools() async throws -> [MCPTool] {
        let result = try await send(method: "tools/list", params: .object([:]))
        let wrapper = try result.decoded(as: MCPToolsListResult.self)
        return wrapper.tools
    }

    /// MCP `tools/call`. Returns the text content of the response;
    /// most LLM-wrapper servers return a single text block. If the
    /// server returns an error tool result (`isError == true`), this
    /// throws so the caller can surface it.
    func callTool(name: String, arguments: AnyJSON) async throws -> String {
        let result = try await send(
            method: "tools/call",
            params: .object([
                "name": .string(name),
                "arguments": arguments
            ])
        )
        let call = try result.decoded(as: MCPToolCallResult.self)
        let combined = call.content
            .filter { $0.type == "text" }
            .map(\.text)
            .joined(separator: "\n\n")
        if call.isError == true {
            throw MCPClientError.responseError(
                code: JSONRPCError.toolExecutionError,
                message: combined.isEmpty ? "Tool execution failed (server reported isError=true)" : combined
            )
        }
        return combined
    }

    // MARK: - Internals

    /// Block until the SSE reader hands us the `endpoint` URL.
    private func waitForEndpoint() async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            endpointWaiter = cont
        }
    }

    /// Send a JSON-RPC request and await its response. Registers a
    /// pending continuation on @MainActor synchronously, THEN fires
    /// the POST. Order matters: SSE responses are dispatched via
    /// `pending[id]`, so the entry has to exist before the request
    /// is even on the wire — otherwise a fast server could deliver
    /// the response before we've parked our continuation and we'd
    /// drop the answer on the floor.
    private func send(method: String, params: AnyJSON) async throws -> AnyJSON {
        guard let endpoint else {
            throw MCPClientError.noEndpointReceived
        }

        nextID += 1
        let idString = "\(nextID)"
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .string(idString),
            method: method,
            params: params
        )

        let response: JSONRPCResponse = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONRPCResponse, Error>) in
            // Synchronous on @MainActor — race window between
            // registration and POST is closed.
            pending[idString] = cont
            // Fire-and-forget the POST. If it fails, unpark our
            // continuation with the network error so the caller
            // doesn't hang forever.
            Task { @MainActor [weak self] in
                guard let self else {
                    cont.resume(throwing: MCPClientError.cancelled)
                    return
                }
                do {
                    try await self.post(request: request, to: endpoint)
                } catch {
                    if let parked = self.pending.removeValue(forKey: idString) {
                        parked.resume(throwing: error)
                    }
                }
            }
        }
        if let err = response.error {
            throw MCPClientError.responseError(code: err.code, message: err.message)
        }
        return response.result ?? .null
    }

    /// Send a JSON-RPC notification (no response expected).
    private func sendNotification(method: String, params: AnyJSON = .object([:])) async throws {
        guard let endpoint else { throw MCPClientError.noEndpointReceived }
        let req = JSONRPCRequest(jsonrpc: "2.0", id: nil, method: method, params: params)
        try await post(request: req, to: endpoint)
    }

    private func post(request: JSONRPCRequest, to url: URL) async throws {
        var http = URLRequest(url: url)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.httpBody = try JSONEncoder().encode(request)
        http.timeoutInterval = 60

        let (data, response) = try await session.data(for: http)
        guard let httpResp = response as? HTTPURLResponse else {
            throw MCPClientError.streamFailed("Non-HTTP response from POST")
        }
        // Servers respond 200/202 with empty or short bodies — we
        // don't read the response body here; the real JSON-RPC reply
        // arrives on the SSE stream.
        guard (200...299).contains(httpResp.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw MCPClientError.requestFailed(status: httpResp.statusCode, body: body)
        }
    }

    /// Long-lived SSE reader. Parses `event:` / `data:` lines, hands
    /// `endpoint` events to the handshake continuation, and routes
    /// `message` events back to the parked request continuations
    /// keyed by JSON-RPC id.
    private nonisolated func readSSE(request: URLRequest) async {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let httpResp = response as? HTTPURLResponse,
               !(200...299).contains(httpResp.statusCode) {
                await failAll(MCPClientError.streamFailed("SSE handshake HTTP \(httpResp.statusCode)"))
                return
            }

            var event: String?
            var data: [String] = []

            for try await line in bytes.lines {
                if line.isEmpty {
                    if !data.isEmpty {
                        let joined = data.joined(separator: "\n")
                        await dispatch(event: event ?? "message", payload: joined)
                    }
                    event = nil
                    data = []
                    continue
                }
                if line.hasPrefix("event:") {
                    event = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    data.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
                } else {
                    // Comment lines (`: keep-alive`) and anything we
                    // don't recognise — ignore per SSE spec.
                }
            }
            // Stream ended naturally — surface as failure so any
            // pending callers don't hang forever.
            await failAll(MCPClientError.streamFailed("SSE stream closed by server"))
        } catch is CancellationError {
            await failAll(MCPClientError.cancelled)
        } catch {
            // Name the host. "Не удалось подключиться к серверу" on its
            // own sent a field report (2026-09-04) into guessing which
            // server — the summarizer's MCP provider can point at
            // anything, and the person's next question is always
            // "which one, and is it running?".
            let host = baseURL.host.map { h in
                baseURL.port.map { "\(h):\($0)" } ?? h
            } ?? baseURL.absoluteString
            await failAll(MCPClientError.streamFailed("\(error.localizedDescription) (\(host) — is the server running?)"))
        }
    }

    /// Route a parsed SSE event. `endpoint` events resolve the
    /// handshake continuation; `message` events parse as JSON-RPC
    /// responses and resolve the matching pending request.
    private func dispatch(event: String, payload: String) async {
        switch event {
        case "endpoint":
            let resolved = resolveEndpoint(payload)
            endpointWaiter?.resume(returning: resolved)
            endpointWaiter = nil
        case "message":
            guard let data = payload.data(using: .utf8),
                  let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: data) else {
                // Payload stays .private — a misbehaving local LLM
                // could echo transcript content into an unparseable
                // SSE frame, which we don't want sitting in the
                // unified system log.
                log.warning("MCP SSE: unparseable message payload: \(payload, privacy: .private)")
                return
            }
            guard let id = response.id, let key = idKey(id) else {
                // Server-initiated notification — we don't handle
                // any of those yet, just log.
                log.info("MCP SSE: server notification (no id), ignoring")
                return
            }
            if let cont = pending.removeValue(forKey: key) {
                cont.resume(returning: response)
            }
        default:
            log.info("MCP SSE: unhandled event '\(event, privacy: .public)'")
        }
    }

    private func failAll(_ error: MCPClientError) async {
        endpointWaiter?.resume(throwing: error)
        endpointWaiter = nil
        let inflight = pending
        pending.removeAll()
        for (_, cont) in inflight {
            cont.resume(throwing: error)
        }
    }

    private func idKey(_ id: JSONRPCID) -> String? {
        switch id {
        case .string(let s): return s
        case .int(let i):    return "\(i)"
        case .null:          return nil
        }
    }

    /// Normalize whatever the server told us into a full URL. Most
    /// servers send a relative path like `/messages`; tolerate
    /// absolute URLs too for the few that ship them.
    private func resolveEndpoint(_ raw: String) -> URL {
        if let abs = URL(string: raw), abs.scheme != nil {
            return abs
        }
        return URL(string: raw, relativeTo: baseURL) ?? baseURL.appendingPathComponent(raw)
    }
}
