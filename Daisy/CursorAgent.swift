//
//  CursorAgent.swift
//  Daisy
//
//  Constrained adapter for Cursor's separate `cursor-agent` CLI. Cursor's
//  print mode is still an agent with tools, so every summary runs in an
//  empty directory with a project-level deny policy. This is defense in
//  depth, not a claim of total containment: the CLI has no documented flag
//  that removes every tool.
//

import Foundation

nonisolated protocol CursorAgentServing: Sendable {
    func summarize(
        prompt: String,
        model: String?,
        apiKey: String,
        executableOverride: String
    ) async throws -> String
}

nonisolated struct CursorAgentService: CursorAgentServing, Sendable {
    static let shared = CursorAgentService()

    static let defaultModelID = "auto"
    static let executableName = "cursor-agent"

    static var likelyExecutablePaths: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin/cursor-agent",
            "\(home)/.cursor/bin/cursor-agent",
            "/opt/homebrew/bin/cursor-agent",
            "/usr/local/bin/cursor-agent",
            "/usr/bin/cursor-agent",
        ]
    }

    static func resolveExecutable(override: String = "") -> URL? {
        let fm = FileManager.default
        let explicit = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit).standardizedFileURL
            guard url.lastPathComponent == executableName,
                  fm.isExecutableFile(atPath: url.path) else { return nil }
            return url
        }
        return likelyExecutablePaths.lazy
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .first { fm.isExecutableFile(atPath: $0.path) }
    }

    func summarize(
        prompt: String,
        model: String?,
        apiKey: String,
        executableOverride: String
    ) async throws -> String {
        var arguments: [AgentProcessRunner.Argument] = [
            .literal("--print"),
            .literal("--output-format"),
            .literal("json"),
        ]
        if let model,
           !model.isEmpty,
           model.localizedCaseInsensitiveCompare(Self.defaultModelID) != .orderedSame {
            arguments += [.literal("--model"), .literal(model)]
        }

        var environment = ProcessInfo.processInfo.environment
        // Cursor documents the environment variable as the preferred
        // automation path. The secret never appears in argv.
        environment["CURSOR_API_KEY"] = apiKey

        do {
            let result = try await run(
                arguments: arguments,
                stdin: Data(prompt.utf8),
                executableOverride: executableOverride,
                environment: environment,
                timeout: 180,
                inputFiles: [".cursor/cli.json": Self.denyPolicy]
            )
            guard !result.stdoutWasTruncated else { throw CursorAgentError.responseTooLarge }
            let envelope = try JSONDecoder().decode(CursorResultEnvelope.self, from: result.stdout)
            guard envelope.type == "result",
                  envelope.subtype == "success",
                  envelope.isError != true,
                  let answer = envelope.result,
                  !answer.isEmpty else {
                throw CursorAgentError.invalidResponse
            }
            return answer
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CursorAgentError {
            throw error
        } catch let error as AgentProcessRunnerError {
            throw Self.map(error)
        } catch {
            throw CursorAgentError.invalidResponse
        }
    }

    private func run(
        arguments: [AgentProcessRunner.Argument],
        stdin: Data,
        executableOverride: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        removingEnvironmentVariables: Set<String> = [],
        timeout: TimeInterval,
        inputFiles: [String: Data] = [:]
    ) async throws -> AgentProcessRunner.Result {
        guard let executable = Self.resolveExecutable(override: executableOverride) else {
            throw CursorAgentError.notInstalled
        }
        var childEnvironment = environment
        childEnvironment["PATH"] = Self.childPath(for: executable.path)
        let runner = try AgentProcessRunner(executable: .cursorAgent(executable))
        return try await runner.run(
            AgentProcessRunner.Request(
                arguments: arguments,
                stdin: stdin,
                environment: childEnvironment,
                removingEnvironmentVariables: removingEnvironmentVariables,
                timeout: timeout,
                stdoutLimit: 512 * 1_024,
                stderrLimit: 128 * 1_024,
                inputFiles: inputFiles
            )
        )
    }

    private static func childPath(for executable: String) -> String {
        let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return ([directory, NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.cursor/bin", "/opt/homebrew/bin", "/usr/local/bin", inherited])
            .joined(separator: ":")
    }

    private static let denyPolicy = Data(#"{"permissions":{"allow":[],"deny":["Shell(*)","Read(**)","Read(/**)","Write(**)","Write(/**)","Mcp(*:*)"]}}"#.utf8)

    private static func map(_ error: AgentProcessRunnerError) -> CursorAgentError {
        switch error {
        case .timedOut(let seconds): return .timedOut(seconds: seconds)
        case .exited(_, let detail) where detail?.localizedCaseInsensitiveContains("usage limit") == true:
            return .limitReached
        default: return .process(error.localizedDescription)
        }
    }
}

// MARK: - Models this account may use

/// One row of `cursor-agent models`.
nonisolated struct CursorAgentModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isDefault: Bool
}

extension CursorAgentService {
    /// The models this key's account may use, as `cursor-agent models`
    /// prints them (cursor.com/docs/cli/reference/parameters, 2026-11-03):
    /// an «Available models» header, then `id - Name` rows, the default
    /// marked «(default)». Which ones depends on the plan — Free and Plus
    /// get only Cursor's own (Grok 4.7, 4.6, 4.5, Composer 2.5) — so the
    /// list comes from the CLI, not from Daisy. Sends the key, nothing else.
    func listModels(apiKey: String, executableOverride: String) async throws -> [CursorAgentModel] {
        var environment = ProcessInfo.processInfo.environment
        environment["CURSOR_API_KEY"] = apiKey
        do {
            let result = try await run(
                arguments: [.literal("models")],
                stdin: Data(),
                executableOverride: executableOverride,
                environment: environment,
                timeout: 30,
                inputFiles: [".cursor/cli.json": Self.denyPolicy]
            )
            guard !result.stdoutWasTruncated else { throw CursorAgentError.responseTooLarge }
            return Self.parseModelList(String(decoding: result.stdout, as: UTF8.self))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CursorAgentError {
            throw error
        } catch let error as AgentProcessRunnerError {
            throw Self.map(error)
        } catch {
            throw CursorAgentError.invalidResponse
        }
    }

    /// `id - Name` rows; anything else (the header, blank lines, notices)
    /// is skipped. Terminal colours are taken off first, and trailing
    /// «(default)» / «(current)» markers off the name.
    static func parseModelList(_ output: String) -> [CursorAgentModel] {
        let plain = output.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
        var seen = Set<String>()
        var models: [CursorAgentModel] = []
        for raw in plain.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let dash = line.range(of: " - ") else { continue }
            let id = String(line[..<dash.lowerBound])
            guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]*$"#, options: .regularExpression) != nil,
                  seen.insert(id).inserted else { continue }
            var name = String(line[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            var isDefault = false
            if let marks = name.range(of: #"\s*\((default|current)(,\s*(default|current))*\)$"#, options: .regularExpression) {
                isDefault = name[marks].contains("default")
                name = String(name[..<marks.lowerBound])
            }
            models.append(CursorAgentModel(id: id, name: name.isEmpty ? id : name, isDefault: isDefault))
        }
        return models
    }
}

private nonisolated struct CursorResultEnvelope: Decodable {
    let type: String
    let subtype: String?
    let isError: Bool?
    let result: String?

    private enum CodingKeys: String, CodingKey {
        case type, subtype, result
        case isError = "is_error"
    }
}

nonisolated enum CursorAgentError: LocalizedError, Equatable {
    case notInstalled
    case limitReached
    case invalidResponse
    case responseTooLarge
    case timedOut(seconds: TimeInterval)
    case process(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return String(localized: "Cursor Agent CLI isn't installed.")
        case .limitReached:
            return String(localized: "The Cursor usage limit has been reached. Try again after it resets.")
        case .invalidResponse:
            return String(localized: "Cursor returned an invalid response.")
        case .responseTooLarge:
            return String(localized: "Cursor returned more data than Daisy can safely process.")
        case .timedOut(let seconds):
            return String(localized: "Cursor didn't finish within \(Int(seconds)) seconds and was stopped.")
        case .process(let message):
            return message
        }
    }
}
