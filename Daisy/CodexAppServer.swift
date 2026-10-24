//
//  CodexAppServer.swift
//  Daisy
//
//  Minimal, private JSON-RPC client for the Codex App Server bundled with
//  ChatGPT/Codex. The protocol is line-delimited JSON over stdio. Raw child
//  output is never logged: it may contain account details or model output.
//

import Foundation

// MARK: - JSON wire value

nonisolated enum CodexJSON: Codable, Equatable, Sendable {
    case object([String: CodexJSON])
    case array([CodexJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([CodexJSON].self) { self = .array(value) }
        else if let value = try? container.decode([String: CodexJSON].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: CodexJSON]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [CodexJSON]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .number(let value) = self, value.isFinite else { return nil }
        return Int(value)
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    subscript(key: String) -> CodexJSON? { objectValue?[key] }

    init(jsonObject: Any) throws {
        switch jsonObject {
        case let dictionary as [String: Any]:
            self = .object(try dictionary.mapValues(CodexJSON.init(jsonObject:)))
        case let array as [Any]:
            self = .array(try array.map(CodexJSON.init(jsonObject:)))
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID()
                ? .bool(number.boolValue)
                : .number(number.doubleValue)
        case _ as NSNull:
            self = .null
        default:
            throw CodexAppServerError.invalidResponse
        }
    }
}

nonisolated struct CodexAppServerNotification: Equatable, Sendable {
    let method: String
    let params: CodexJSON
}

// MARK: - Process transport

/// A reconnecting App Server connection. The actor owns the Process and all
/// request continuations; callbacks only feed bytes back into the actor.
actor CodexAppServerConnection {
    /// Daisy intentionally uses the App Server's experimental empty
    /// environment/tool/root fields to keep account-backed summaries
    /// non-interactive. The server rejects those fields unless the client
    /// opts in during initialization.
    nonisolated static let protocolCapabilities: CodexJSON = .object([
        "experimentalApi": .bool(true)
    ])

    private struct PendingRequest {
        let continuation: CheckedContinuation<CodexJSON, Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct NotificationWaiter {
        let method: String
        let matching: [String: String]
        let continuation: CheckedContinuation<CodexAppServerNotification, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let executableURL: URL
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var generation = UUID()
    private var initialized = false
    private var readBuffer = Data()
    private var pendingRequests: [String: PendingRequest] = [:]
    private var notificationWaiters: [UUID: NotificationWaiter] = [:]
    private var recentNotifications: [CodexAppServerNotification] = []

    // A completion notification may echo a long meeting transcript in its
    // turn items. Keep the line bounded, but leave room for hour-long calls.
    private static let maximumWireLineBytes = 16 * 1_048_576
    private static let notificationHistoryLimit = 128

    init(executableURL: URL) throws {
        let url = executableURL.standardizedFileURL
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              url.lastPathComponent == "codex",
              FileManager.default.isExecutableFile(atPath: url.path)
        else { throw CodexAppServerError.notInstalled }
        self.executableURL = url
    }

    func request(
        method: String,
        params: CodexJSON? = nil,
        timeout: TimeInterval = 15
    ) async throws -> CodexJSON {
        try await ensureStarted()
        return try await sendRequest(method: method, params: params, timeout: timeout)
    }

    func notify(method: String, params: CodexJSON? = nil) async throws {
        try await ensureStarted()
        var message: [String: CodexJSON] = ["method": .string(method)]
        if let params { message["params"] = params }
        try write(.object(message))
    }

    func waitForNotification(
        method: String,
        matching: [String: String] = [:],
        timeout: TimeInterval
    ) async throws -> CodexAppServerNotification {
        if let existing = recentNotifications.reversed().first(where: {
            doesNotification($0, match: method, fields: matching)
        }) {
            return existing
        }

        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: Self.nanoseconds(timeout))
                    guard !Task.isCancelled else { return }
                    await self?.expireNotification(token)
                }
                notificationWaiters[token] = NotificationWaiter(
                    method: method,
                    matching: matching,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: {
            Task { await self.cancelNotification(token) }
        }
    }

    func recentNotification(
        method: String,
        matching: [String: String] = [:]
    ) -> CodexAppServerNotification? {
        recentNotifications.reversed().first {
            doesNotification($0, match: method, fields: matching)
        }
    }

    func clearNotifications(matching fields: [String: String]) {
        recentNotifications.removeAll { note in
            fields.allSatisfy { key, value in note.params[key]?.stringValue == value }
        }
    }

    func stop() {
        stopProcess(error: CodexAppServerError.disconnected)
    }

    // MARK: Start / reconnect

    private func ensureStarted() async throws {
        if process?.isRunning == true, initialized { return }
        if process != nil { stopProcess(error: CodexAppServerError.disconnected) }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let diagnostics = Pipe()
        let currentGeneration = UUID()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostics
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_API_KEY")
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.ingest(data, generation: currentGeneration) }
        }
        // Drain diagnostics so the child cannot block. Never retain or log
        // them: auth and model failures can carry private account details.
        diagnostics.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.processExited(generation: currentGeneration) }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            diagnostics.fileHandleForReading.readabilityHandler = nil
            throw CodexAppServerError.launchFailed
        }

        self.process = process
        self.inputHandle = input.fileHandleForWriting
        self.outputPipe = output
        self.errorPipe = diagnostics
        self.generation = currentGeneration
        self.initialized = false
        self.readBuffer.removeAll(keepingCapacity: true)

        do {
            _ = try await sendRequest(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("daisy"),
                        "title": .string("Daisy"),
                        "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development")
                    ]),
                    "capabilities": Self.protocolCapabilities
                ]),
                timeout: 10
            )
            try write(.object(["method": .string("initialized")]))
            initialized = true
        } catch {
            stopProcess(error: error)
            throw error
        }
    }

    // MARK: Requests

    private func sendRequest(
        method: String,
        params: CodexJSON?,
        timeout: TimeInterval
    ) async throws -> CodexJSON {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: Self.nanoseconds(timeout))
                    guard !Task.isCancelled else { return }
                    await self?.expireRequest(id)
                }
                pendingRequests[id] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                var message: [String: CodexJSON] = [
                    "id": .string(id),
                    "method": .string(method)
                ]
                if let params { message["params"] = params }
                do {
                    try write(.object(message))
                } catch {
                    if let pending = pendingRequests.removeValue(forKey: id) {
                        pending.timeoutTask.cancel()
                        pending.continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    private func expireRequest(_ id: String) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: CodexAppServerError.timedOut)
    }

    private func cancelRequest(_ id: String) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: CancellationError())
    }

    private func expireNotification(_ token: UUID) {
        guard let waiter = notificationWaiters.removeValue(forKey: token) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(throwing: CodexAppServerError.timedOut)
    }

    private func cancelNotification(_ token: UUID) {
        guard let waiter = notificationWaiters.removeValue(forKey: token) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func write(_ message: CodexJSON) throws {
        guard process?.isRunning == true, let inputHandle else {
            throw CodexAppServerError.disconnected
        }
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        do { try inputHandle.write(contentsOf: data) }
        catch { throw CodexAppServerError.disconnected }
    }

    // MARK: Incoming messages

    private func ingest(_ data: Data, generation incomingGeneration: UUID) {
        guard incomingGeneration == generation else { return }
        if data.isEmpty { return }
        readBuffer.append(data)

        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = Data(readBuffer[..<newline])
            readBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard line.count <= Self.maximumWireLineBytes else {
                stopProcess(error: CodexAppServerError.responseTooLarge)
                return
            }
            handleLine(line)
        }
        if readBuffer.count > Self.maximumWireLineBytes {
            stopProcess(error: CodexAppServerError.responseTooLarge)
        }
    }

    private func handleLine(_ data: Data) {
        guard let message = try? JSONDecoder().decode(CodexJSON.self, from: data),
              let object = message.objectValue
        else {
            stopProcess(error: CodexAppServerError.invalidResponse)
            return
        }

        if let id = object["id"]?.stringValue,
           let pending = pendingRequests.removeValue(forKey: id) {
            pending.timeoutTask.cancel()
            if let result = object["result"] {
                pending.continuation.resume(returning: result)
            } else {
                let rawMessage = object["error"]?["message"]?.stringValue ?? ""
                pending.continuation.resume(throwing: CodexAppServerError.remote(Self.friendlyMessage(for: rawMessage)))
            }
            return
        }

        if let method = object["method"]?.stringValue {
            if let id = object["id"] {
                denyServerRequest(id: id)
                return
            }
            let notification = CodexAppServerNotification(
                method: method,
                params: object["params"] ?? .object([:])
            )
            recentNotifications.append(notification)
            if recentNotifications.count > Self.notificationHistoryLimit {
                recentNotifications.removeFirst(recentNotifications.count - Self.notificationHistoryLimit)
            }
            let matches = notificationWaiters.filter {
                doesNotification(notification, match: $0.value.method, fields: $0.value.matching)
            }
            for (token, waiter) in matches {
                notificationWaiters.removeValue(forKey: token)
                waiter.timeoutTask.cancel()
                waiter.continuation.resume(returning: notification)
            }
        }
    }

    /// Summary threads are deliberately non-interactive. If a prompt ever
    /// induces a tool request despite `approvalPolicy: never`, reject it at
    /// the protocol boundary instead of surfacing a confirmation dialog.
    private func denyServerRequest(id: CodexJSON) {
        try? write(.object([
            "id": id,
            "error": .object([
                "code": .number(-32_000),
                "message": .string("Daisy account summaries do not permit interactive tools.")
            ])
        ]))
    }

    private func doesNotification(
        _ notification: CodexAppServerNotification,
        match method: String,
        fields: [String: String]
    ) -> Bool {
        notification.method == method && fields.allSatisfy { key, value in
            notification.params[key]?.stringValue == value
        }
    }

    private func processExited(generation exitedGeneration: UUID) {
        guard exitedGeneration == generation else { return }
        stopProcess(error: CodexAppServerError.disconnected, terminate: false)
    }

    private func stopProcess(error: Error, terminate: Bool = true) {
        let oldProcess = process
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        inputHandle?.closeFile()
        if terminate, oldProcess?.isRunning == true { oldProcess?.terminate() }
        process = nil
        inputHandle = nil
        outputPipe = nil
        errorPipe = nil
        initialized = false
        readBuffer.removeAll(keepingCapacity: false)

        let requests = pendingRequests.values
        pendingRequests.removeAll()
        for pending in requests {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: error)
        }
        let waiters = notificationWaiters.values
        notificationWaiters.removeAll()
        for waiter in waiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(throwing: error)
        }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0.001, min(seconds, 3_600)) * 1_000_000_000)
    }

    private static func friendlyMessage(for raw: String) -> String {
        let text = raw.lowercased()
        if text.contains("auth") || text.contains("login") || text.contains("token") {
            return String(localized: "Your ChatGPT session expired. Connect the account again.")
        }
        if text.contains("rate") || text.contains("limit") || text.contains("quota") {
            return String(localized: "Your ChatGPT plan limit has been reached. Try again after it resets.")
        }
        if text.contains("network") || text.contains("offline") || text.contains("connect") {
            return String(localized: "Codex couldn't reach OpenAI. Check your internet connection and try again.")
        }
        return String(localized: "Codex App Server couldn't complete the request.")
    }
}

// MARK: - Service models

nonisolated struct CodexAccountInfo: Equatable, Sendable {
    let type: String
    let email: String?
    let plan: String?
}

nonisolated struct CodexModelInfo: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let isDefault: Bool
}

nonisolated struct CodexRateLimitWindow: Equatable, Sendable {
    let usedPercent: Int
    let resetsAt: Date?
    let durationMinutes: Int?
}

nonisolated struct CodexRateLimitBucket: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
    let isReached: Bool
}

nonisolated struct CodexRateLimitInfo: Equatable, Sendable {
    let usedPercent: Int?
    let resetsAt: Date?
    let isReached: Bool
    let buckets: [CodexRateLimitBucket]

    init(
        usedPercent: Int?,
        resetsAt: Date?,
        isReached: Bool,
        buckets: [CodexRateLimitBucket] = []
    ) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.isReached = isReached
        self.buckets = buckets
    }
}

nonisolated struct CodexLoginAttempt: Equatable, Sendable {
    let id: String
    let authorizationURL: URL
}

nonisolated protocol CodexAppServerServing: Sendable {
    func account(executableOverride: String) async throws -> CodexAccountInfo?
    func models(executableOverride: String) async throws -> [CodexModelInfo]
    func rateLimits(executableOverride: String) async throws -> CodexRateLimitInfo?
    func beginLogin(executableOverride: String) async throws -> CodexLoginAttempt
    func awaitLogin(_ attempt: CodexLoginAttempt, executableOverride: String) async throws
    func logout(executableOverride: String) async throws
    func summarize(
        prompt: String,
        developerInstructions: String,
        model: String?,
        outputSchema: CodexJSON,
        executableOverride: String
    ) async throws -> String
}

// MARK: - High-level App Server API

actor CodexAppServerService: CodexAppServerServing {
    static let shared = CodexAppServerService()

    private var connection: CodexAppServerConnection?
    private var connectedExecutable: URL?

    func account(executableOverride: String = "") async throws -> CodexAccountInfo? {
        let connection = try await connection(for: executableOverride)
        let result = try await retryingRead {
            try await connection.request(
                method: "account/read",
                params: .object(["refreshToken": .bool(false)])
            )
        }
        guard let account = result["account"], account != .null else { return nil }
        guard let type = account["type"]?.stringValue else { throw CodexAppServerError.invalidResponse }
        return CodexAccountInfo(
            type: type,
            email: account["email"]?.stringValue,
            plan: account["planType"]?.stringValue
        )
    }

    func models(executableOverride: String = "") async throws -> [CodexModelInfo] {
        let connection = try await connection(for: executableOverride)
        let result = try await retryingRead {
            try await connection.request(
                method: "model/list",
                params: .object(["limit": .number(100), "includeHidden": .bool(false)])
            )
        }
        guard let data = result["data"]?.arrayValue else { throw CodexAppServerError.invalidResponse }
        return data.compactMap { item in
            guard let id = item["model"]?.stringValue ?? item["id"]?.stringValue else { return nil }
            return CodexModelInfo(
                id: id,
                displayName: item["displayName"]?.stringValue ?? id,
                isDefault: item["isDefault"]?.boolValue ?? false
            )
        }
    }

    func rateLimits(executableOverride: String = "") async throws -> CodexRateLimitInfo? {
        let connection = try await connection(for: executableOverride)
        let result = try await retryingRead {
            try await connection.request(method: "account/rateLimits/read")
        }
        return Self.parseRateLimits(result)
    }

    /// The App Server keeps the historical single bucket and also exposes a
    /// multi-bucket map keyed by the backend's metered limit id. The latter
    /// is what Home uses for model-group rows; the legacy fields remain for
    /// Settings and for older App Server versions.
    nonisolated static func parseRateLimits(_ result: CodexJSON) -> CodexRateLimitInfo? {
        let legacy = result["rateLimits"]
        let legacyWindow = parseRateLimitWindow(legacy?["primary"])
        let legacyReached = isRateLimitReached(legacy, primary: legacyWindow)

        let bucketValues = result["rateLimitsByLimitId"]?.objectValue ?? [:]
        let buckets = bucketValues.keys.sorted().compactMap { id -> CodexRateLimitBucket? in
            guard let snapshot = bucketValues[id], snapshot != .null else { return nil }
            let primary = parseRateLimitWindow(snapshot["primary"])
            let secondary = parseRateLimitWindow(snapshot["secondary"])
            let rawName = snapshot["limitName"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = rawName.flatMap { $0.isEmpty ? nil : $0 } ?? id
            return CodexRateLimitBucket(
                id: snapshot["limitId"]?.stringValue ?? id,
                name: displayName,
                primary: primary,
                secondary: secondary,
                isReached: isRateLimitReached(snapshot, primary: primary)
            )
        }

        guard legacy != nil || !buckets.isEmpty else { return nil }
        return CodexRateLimitInfo(
            usedPercent: legacyWindow?.usedPercent,
            resetsAt: legacyWindow?.resetsAt,
            isReached: legacyReached,
            buckets: buckets
        )
    }

    private nonisolated static func parseRateLimitWindow(
        _ value: CodexJSON?
    ) -> CodexRateLimitWindow? {
        guard let value, value != .null,
              let used = value["usedPercent"]?.intValue
        else { return nil }
        return CodexRateLimitWindow(
            usedPercent: min(max(used, 0), 100),
            resetsAt: value["resetsAt"]?.intValue.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            durationMinutes: value["windowDurationMins"]?.intValue
        )
    }

    private nonisolated static func isRateLimitReached(
        _ snapshot: CodexJSON?,
        primary: CodexRateLimitWindow?
    ) -> Bool {
        snapshot?["rateLimitReachedType"]?.stringValue != nil
            || snapshot?["spendControlReached"]?.boolValue == true
            || (primary?.usedPercent ?? 0) >= 100
    }

    func beginLogin(executableOverride: String = "") async throws -> CodexLoginAttempt {
        let connection = try await connection(for: executableOverride)
        let result = try await connection.request(
            method: "account/login/start",
            params: .object([
                "type": .string("chatgpt"),
                "appBrand": .string("chatgpt"),
                "useHostedLoginSuccessPage": .bool(true)
            ]),
            timeout: 15
        )
        guard result["type"]?.stringValue == "chatgpt",
              let id = result["loginId"]?.stringValue,
              let rawURL = result["authUrl"]?.stringValue,
              let url = URL(string: rawURL),
              url.scheme == "https"
        else { throw CodexAppServerError.invalidResponse }
        return CodexLoginAttempt(id: id, authorizationURL: url)
    }

    func awaitLogin(_ attempt: CodexLoginAttempt, executableOverride: String = "") async throws {
        let connection = try await connection(for: executableOverride)
        let notification = try await connection.waitForNotification(
            method: "account/login/completed",
            matching: ["loginId": attempt.id],
            timeout: 180
        )
        guard notification.params["success"]?.boolValue == true else {
            throw CodexAppServerError.authorizationFailed
        }
    }

    func logout(executableOverride: String = "") async throws {
        let connection = try await connection(for: executableOverride)
        _ = try await connection.request(method: "account/logout", timeout: 15)
    }

    func summarize(
        prompt: String,
        developerInstructions: String,
        model: String?,
        outputSchema: CodexJSON,
        executableOverride: String = ""
    ) async throws -> String {
        let connection = try await connection(for: executableOverride)
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("daisy-codex-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch { throw CodexAppServerError.temporaryDirectoryFailed }
        defer { try? fm.removeItem(at: directory) }

        var threadParams: [String: CodexJSON] = [
            "cwd": .string(directory.path),
            "approvalPolicy": .string("never"),
            "sandbox": .string("read-only"),
            "ephemeral": .bool(true),
            "environments": .array([]),
            "dynamicTools": .array([]),
            "selectedCapabilityRoots": .array([]),
            "developerInstructions": .string(developerInstructions),
            "config": .object([
                "web_search": .string("disabled"),
                "mcp_servers": .object([:]),
                "apps": .object(["_default": .object(["enabled": .bool(false)])])
            ])
        ]
        if let model, !model.isEmpty { threadParams["model"] = .string(model) }

        let threadResult = try await connection.request(
            method: "thread/start",
            params: .object(threadParams),
            timeout: 20
        )
        guard let threadID = threadResult["thread"]?["id"]?.stringValue else {
            throw CodexAppServerError.invalidResponse
        }

        var turnID: String?
        do {
            let turnResult = try await connection.request(
                method: "turn/start",
                params: .object([
                    "threadId": .string(threadID),
                    "input": .array([
                        .object(["type": .string("text"), "text": .string(prompt)])
                    ]),
                    "outputSchema": outputSchema,
                    "approvalPolicy": .string("never"),
                    "environments": .array([]),
                    "sandboxPolicy": .object([
                        "type": .string("readOnly"),
                        "networkAccess": .bool(false)
                    ])
                ]),
                timeout: 20
            )
            guard let id = turnResult["turn"]?["id"]?.stringValue else {
                throw CodexAppServerError.invalidResponse
            }
            turnID = id

            let completion = try await withTaskCancellationHandler {
                try await connection.waitForNotification(
                    method: "turn/completed",
                    matching: ["threadId": threadID],
                    timeout: 180
                )
            } onCancel: {
                Task {
                    _ = try? await connection.request(
                        method: "turn/interrupt",
                        params: .object(["threadId": .string(threadID), "turnId": .string(id)]),
                        timeout: 5
                    )
                }
            }

            if let errorMessage = completion.params["turn"]?["error"]?["message"]?.stringValue {
                throw CodexAppServerError.remote(CodexAppServerError.friendlySummaryMessage(errorMessage))
            }
            if let text = Self.agentMessage(in: completion.params["turn"]?["items"]) {
                await cleanup(threadID: threadID, connection: connection)
                return text
            }
            if let item = await connection.recentNotification(
                method: "item/completed",
                matching: ["threadId": threadID, "turnId": id]
            ),
               item.params["item"]?["type"]?.stringValue == "agentMessage",
               let text = item.params["item"]?["text"]?.stringValue {
                await cleanup(threadID: threadID, connection: connection)
                return text
            }
            throw CodexAppServerError.invalidResponse
        } catch {
            if let turnID {
                _ = try? await connection.request(
                    method: "turn/interrupt",
                    params: .object(["threadId": .string(threadID), "turnId": .string(turnID)]),
                    timeout: 5
                )
            }
            await cleanup(threadID: threadID, connection: connection)
            throw error
        }
    }

    private func connection(for override: String) async throws -> CodexAppServerConnection {
        guard let executable = Self.resolveExecutable(override: override) else {
            throw CodexAppServerError.notInstalled
        }
        if let connection, connectedExecutable == executable { return connection }
        if let connection { await connection.stop() }
        let newConnection = try CodexAppServerConnection(executableURL: executable)
        connection = newConnection
        connectedExecutable = executable
        return newConnection
    }

    /// Account and catalog reads are idempotent. If the App Server died,
    /// its next request starts a fresh process and retries once.
    private func retryingRead(
        _ operation: () async throws -> CodexJSON
    ) async throws -> CodexJSON {
        do { return try await operation() }
        catch CodexAppServerError.disconnected { return try await operation() }
    }

    private func cleanup(threadID: String, connection: CodexAppServerConnection) async {
        _ = try? await connection.request(
            method: "thread/delete",
            params: .object(["threadId": .string(threadID)]),
            timeout: 5
        )
        await connection.clearNotifications(matching: ["threadId": threadID])
    }

    private static func agentMessage(in items: CodexJSON?) -> String? {
        items?.arrayValue?.reversed().first(where: {
            $0["type"]?.stringValue == "agentMessage"
        })?["text"]?.stringValue
    }

    nonisolated static func resolveExecutable(override: String = "") -> URL? {
        let probe = AgentCLISummarizer(agent: .codex, executableOverride: override)
        return probe.resolvedExecutable().map(URL.init(fileURLWithPath:))
    }
}

// MARK: - Friendly errors

nonisolated enum CodexAppServerError: LocalizedError, Equatable {
    case notInstalled
    case launchFailed
    case disconnected
    case timedOut
    case responseTooLarge
    case invalidResponse
    case temporaryDirectoryFailed
    case authorizationFailed
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return String(localized: "ChatGPT or Codex isn't installed, or Daisy can't find its Codex helper.")
        case .launchFailed:
            return String(localized: "Daisy couldn't start the Codex App Server.")
        case .disconnected:
            return String(localized: "The Codex App Server stopped. Try again; Daisy will reconnect automatically.")
        case .timedOut:
            return String(localized: "Codex took too long to respond.")
        case .responseTooLarge, .invalidResponse:
            return String(localized: "Codex returned an unexpected response.")
        case .temporaryDirectoryFailed:
            return String(localized: "Daisy couldn't create a private temporary folder for the summary.")
        case .authorizationFailed:
            return String(localized: "ChatGPT sign-in was cancelled or failed.")
        case .remote(let message):
            return message
        }
    }

    static func friendlySummaryMessage(_ raw: String) -> String {
        let value = raw.lowercased()
        if value.contains("rate") || value.contains("limit") || value.contains("quota") {
            return String(localized: "Your ChatGPT plan limit has been reached. Try again after it resets.")
        }
        if value.contains("auth") || value.contains("login") || value.contains("token") {
            return String(localized: "Your ChatGPT session expired. Connect the account again in \(SettingsRow.summaryProvider.path).")
        }
        if value.contains("model") && (value.contains("unavailable") || value.contains("not found")) {
            return String(localized: "That model isn't available on this ChatGPT account. Pick another model in \(SettingsRow.summaryProvider.path).")
        }
        return String(localized: "Codex couldn't produce this summary.")
    }
}
