//
//  MCPProtocol.swift
//  Daisy
//
//  Minimal types for JSON-RPC 2.0 + the slice of the Model Context
//  Protocol (MCP) that Daisy's local server speaks:
//
//   • initialize        — handshake
//   • notifications/initialized — client confirms handshake
//   • tools/list        — advertise the tools we expose
//   • tools/call        — invoke a tool with arguments
//   • notifications/cancelled — best-effort cancel (we no-op)
//
//  Spec reference: https://spec.modelcontextprotocol.io/
//
//  We deliberately don't depend on a third-party MCP SDK — the
//  protocol slice we need is small enough to hand-roll, and rolling
//  our own keeps the build hermetic.
//

import Foundation

// MARK: - JSON-RPC 2.0

/// JSON-RPC 2.0 only allows scalar IDs (string/number/null). We model
/// the union as an enum so we can echo whatever the client sent back
/// in our response — clients use the ID to correlate.
nonisolated enum JSONRPCID: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        throw DecodingError.typeMismatch(
            JSONRPCID.self,
            .init(codingPath: decoder.codingPath, debugDescription: "JSON-RPC id must be string, number, or null")
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i):    try c.encode(i)
        case .null:          try c.encodeNil()
        }
    }
}

/// Incoming request from the MCP client. `params` is a generic JSON
/// blob that the handler decodes into a typed shape per `method`.
nonisolated struct JSONRPCRequest: Codable, Sendable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String
    let params: AnyJSON?
}

nonisolated struct JSONRPCResponse: Codable, Sendable {
    let jsonrpc: String
    let id: JSONRPCID?
    let result: AnyJSON?
    let error: JSONRPCError?

    init(id: JSONRPCID?, result: AnyJSON) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    init(id: JSONRPCID?, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}

nonisolated struct JSONRPCError: Codable, Sendable {
    let code: Int
    let message: String
    let data: AnyJSON?

    // Canonical JSON-RPC error codes.
    static let parseError       = -32700
    static let invalidRequest   = -32600
    static let methodNotFound   = -32601
    static let invalidParams    = -32602
    static let internalError    = -32603

    // MCP convention: tool errors use a custom range.
    static let toolExecutionError = -32000
}

// MARK: - AnyJSON

/// Erased JSON value, just enough to round-trip arbitrary `params`
/// and `result` payloads without forcing a typed schema at the
/// transport layer. Tool handlers decode/encode the typed shapes
/// they care about; the rest just passes through.
nonisolated enum AnyJSON: Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([AnyJSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: AnyJSON].self) { self = .object(o); return }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unknown JSON value")
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let b):    try c.encode(b)
        case .int(let i):     try c.encode(i)
        case .double(let d):  try c.encode(d)
        case .string(let s):  try c.encode(s)
        case .array(let a):   try c.encode(a)
        case .object(let o):  try c.encode(o)
        }
    }

    /// Decode this value into a concrete `Decodable` type. Convenient
    /// for tool handlers that want typed arguments.
    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Build an AnyJSON from any `Encodable`. Used to wrap typed
    /// tool results into the generic transport envelope.
    static func wrap<T: Encodable>(_ value: T) throws -> AnyJSON {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(AnyJSON.self, from: data)
    }
}

// MARK: - MCP-specific shapes

/// Identifiers we send back for the `initialize` handshake.
nonisolated struct MCPServerInfo: Codable, Sendable {
    let name: String
    let version: String
}

/// Capabilities object — for now we only advertise `tools`.
nonisolated struct MCPServerCapabilities: Codable, Sendable {
    let tools: MCPToolsCapability?

    nonisolated struct MCPToolsCapability: Codable, Sendable {
        // We don't currently emit list-changed notifications.
        let listChanged: Bool
    }
}

/// Result returned by `initialize`.
nonisolated struct MCPInitializeResult: Codable, Sendable {
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
    let serverInfo: MCPServerInfo
}

/// Behaviour hints attached to a tool (`Tool.annotations` in the MCP
/// schema, present since the 2025-03-26 revision). Every field is a
/// HINT: the spec is explicit that clients must not treat these as
/// guarantees from an untrusted server. For us they're how a client
/// can tell the five read tools from the four write ones without
/// parsing English descriptions — which is what ChatGPT's developer
/// mode and Anthropic's connector directory key off.
///
/// Spec defaults, which is why we spell every field out rather than
/// relying on omission: `readOnlyHint` false, `destructiveHint` TRUE,
/// `idempotentHint` false, `openWorldHint` TRUE. Staying silent means
/// "destructive, open-world" — the opposite of what Daisy's catalog is.
nonisolated struct MCPToolAnnotations: Codable, Sendable {
    /// Human-readable display name. Client display precedence is
    /// `title` → `annotations.title` → `name`; we set it here (rather
    /// than the top-level `Tool.title`) because `annotations.title`
    /// is understood by 2025-03-26 clients as well as newer ones.
    let title: String?
    /// True = the tool does not modify anything.
    let readOnlyHint: Bool?
    /// True = the tool may perform destructive (non-additive) updates.
    /// Only meaningful when `readOnlyHint` is false.
    let destructiveHint: Bool?
    /// True = calling again with the same arguments changes nothing
    /// further. Only meaningful when `readOnlyHint` is false.
    let idempotentHint: Bool?
    /// True = the tool may reach an open world of external entities.
    let openWorldHint: Bool?

    init(
        title: String? = nil,
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }
}

/// Tool descriptor advertised via `tools/list`.
nonisolated struct MCPTool: Codable, Sendable {
    let name: String
    let description: String
    /// JSON Schema describing the tool's arguments. We hand-roll
    /// schemas as `AnyJSON` objects so we don't pull in a schema lib.
    let inputSchema: AnyJSON
    /// Optional behaviour hints. Omitted entirely when nil (a nil
    /// Optional encodes to nothing), so pre-2025-03-26 clients see the
    /// exact same tool shape they saw before.
    let annotations: MCPToolAnnotations?

    init(
        name: String,
        description: String,
        inputSchema: AnyJSON,
        annotations: MCPToolAnnotations? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }

    enum CodingKeys: String, CodingKey {
        case name, description, inputSchema, annotations
    }

    /// Decoding matters because this type runs in BOTH directions:
    /// Daisy advertises tools with it, and `MCPClient` decodes some
    /// other server's `tools/list` with it when the user points a
    /// destination at a third-party MCP server.
    ///
    /// `annotations` is therefore read with `try?`. The field is a bag
    /// of hints we don't act on, servers in the wild put arbitrary
    /// shapes there, and a strict decode would fail the WHOLE catalog
    /// over one malformed hint on one tool.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        inputSchema = try c.decode(AnyJSON.self, forKey: .inputSchema)
        annotations = try? c.decode(MCPToolAnnotations.self, forKey: .annotations)
    }
}

nonisolated struct MCPToolsListResult: Codable, Sendable {
    let tools: [MCPTool]
}

/// `tools/call` parameters.
nonisolated struct MCPToolCallParams: Codable, Sendable {
    let name: String
    let arguments: AnyJSON?
}

/// `tools/call` result. MCP returns content as an array of blocks
/// (text / image / resource). We only emit text blocks.
///
/// Conforms to `Error` so it can double as the failure type of the
/// internal `Result<StoredSession, MCPToolCallResult>` helpers in
/// MCPTools (e.g. `resolveSession`), where a tool returns the
/// `.error(_:)` block directly to the agent instead of throwing.
/// `Error` is a marker protocol with no requirements, so this adds
/// no behaviour — it only unlocks that usage.
nonisolated struct MCPToolCallResult: Codable, Sendable, Error {
    let content: [MCPContentBlock]
    let isError: Bool?

    static func text(_ string: String) -> MCPToolCallResult {
        MCPToolCallResult(
            content: [.init(type: "text", text: string)],
            isError: nil
        )
    }

    static func error(_ string: String) -> MCPToolCallResult {
        MCPToolCallResult(
            content: [.init(type: "text", text: string)],
            isError: true
        )
    }
}

nonisolated struct MCPContentBlock: Codable, Sendable {
    let type: String
    let text: String
}
