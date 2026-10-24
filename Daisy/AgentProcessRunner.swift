//
//  AgentProcessRunner.swift
//  Daisy
//
//  Constrained subprocess runner for account-backed local clients. It never
//  invokes a shell, always uses an empty throwaway working directory, bounds
//  captured output, and terminates the child on timeout or cancellation.
//

import Darwin
import Foundation

nonisolated struct AgentProcessRunner: Sendable {
    enum Executable: Sendable {
        case codex(URL)
        case cursorAgent(URL)

#if DEBUG
        /// Fixed system binaries used by unit tests. There is deliberately no
        /// arbitrary-path test case: debug builds should preserve the same
        /// allow-list property as release builds.
        case testCat
        case testSleep
        case testYes
        case testSeq
        case testEnv
        case testGrep
#endif

        fileprivate var url: URL {
            switch self {
            case .codex(let url):
                return url
            case .cursorAgent(let url):
                return url
#if DEBUG
            case .testCat:
                return URL(fileURLWithPath: "/bin/cat")
            case .testSleep:
                return URL(fileURLWithPath: "/bin/sleep")
            case .testYes:
                return URL(fileURLWithPath: "/usr/bin/yes")
            case .testSeq:
                return URL(fileURLWithPath: "/usr/bin/seq")
            case .testEnv:
                return URL(fileURLWithPath: "/usr/bin/env")
            case .testGrep:
                return URL(fileURLWithPath: "/usr/bin/grep")
#endif
            }
        }

        fileprivate var expectedBasename: String {
            switch self {
            case .codex:
                return "codex"
            case .cursorAgent:
                return "cursor-agent"
#if DEBUG
            case .testCat:
                return "cat"
            case .testSleep:
                return "sleep"
            case .testYes:
                return "yes"
            case .testSeq:
                return "seq"
            case .testEnv:
                return "env"
            case .testGrep:
                return "grep"
#endif
            }
        }
    }

    enum Argument: Equatable, Sendable {
        case literal(String)
        /// A plain filename inside the per-request temporary directory.
        /// Directory traversal and nested paths are rejected.
        case temporaryFile(String)
    }

    struct Request: Sendable {
        var arguments: [Argument]
        var stdin: Data
        var environment: [String: String]
        var removingEnvironmentVariables: Set<String>
        var timeout: TimeInterval
        var stdoutLimit: Int
        var stderrLimit: Int
        /// Trusted configuration written before launch inside the private
        /// working directory. Relative paths are validated component by
        /// component; callers cannot escape the scratch directory.
        var inputFiles: [String: Data]
        var outputFiles: [String]

        init(
            arguments: [Argument],
            stdin: Data,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            removingEnvironmentVariables: Set<String> = [],
            timeout: TimeInterval = 180,
            stdoutLimit: Int = 256 * 1_024,
            stderrLimit: Int = 256 * 1_024,
            inputFiles: [String: Data] = [:],
            outputFiles: [String] = []
        ) {
            self.arguments = arguments
            self.stdin = stdin
            self.environment = environment
            self.removingEnvironmentVariables = removingEnvironmentVariables
            self.timeout = timeout
            self.stdoutLimit = stdoutLimit
            self.stderrLimit = stderrLimit
            self.inputFiles = inputFiles
            self.outputFiles = outputFiles
        }
    }

    struct Result: Sendable {
        let stdout: Data
        let stderr: Data
        let stdoutWasTruncated: Bool
        let stderrWasTruncated: Bool
        let outputFiles: [String: Data]
        /// Useful for asserting cleanup; this URL no longer exists when a
        /// successful result is returned.
        let temporaryDirectory: URL

        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    private let executable: Executable

    init(executable: Executable) throws {
        let url = executable.url.standardizedFileURL
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              url.lastPathComponent == executable.expectedBasename,
              FileManager.default.isExecutableFile(atPath: url.path)
        else {
            throw AgentProcessRunnerError.invalidExecutable
        }
        self.executable = executable
    }

    func run(_ request: Request) async throws -> Result {
        guard request.timeout > 0, request.stdoutLimit > 0, request.stderrLimit > 0 else {
            throw AgentProcessRunnerError.invalidLimits
        }

        let names = request.outputFiles + request.arguments.compactMap { argument -> String? in
            if case .temporaryFile(let name) = argument { return name }
            return nil
        }
        for name in names where !Self.isSafeTemporaryFilename(name) {
            throw AgentProcessRunnerError.invalidTemporaryFilename
        }
        for path in request.inputFiles.keys where !Self.isSafeRelativeTemporaryPath(path) {
            throw AgentProcessRunnerError.invalidTemporaryFilename
        }

        _ = Self.ignoreSIGPIPEOnce

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-agent-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: scratch,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw AgentProcessRunnerError.temporaryDirectoryFailed
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        do {
            for (path, data) in request.inputFiles {
                let destination = scratch.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try data.write(to: destination, options: [.atomic])
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destination.path
                )
            }
        } catch {
            throw AgentProcessRunnerError.temporaryDirectoryFailed
        }

        let process = Process()
        process.executableURL = executable.url.standardizedFileURL
        process.arguments = request.arguments.map { argument in
            switch argument {
            case .literal(let value):
                return value
            case .temporaryFile(let name):
                return scratch.appendingPathComponent(name).path
            }
        }
        process.currentDirectoryURL = scratch

        var environment = request.environment
        for key in request.removingEnvironmentVariables {
            environment.removeValue(forKey: key)
        }
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let sink = LimitedOutputSink(
            stdoutLimit: request.stdoutLimit,
            stderrLimit: request.stderrLimit
        )
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                sink.markStdoutEOF()
            } else {
                sink.appendStdout(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                sink.markStderrEOF()
            } else {
                sink.appendStderr(data)
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw AgentProcessRunnerError.launchFailed
        }

        let stdinData = request.stdin
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
            try? stdinPipe.fileHandleForWriting.close()
        }

        let outcome = await Self.wait(for: process, timeout: request.timeout)

        let drainDeadline = Date().addingTimeInterval(1.5)
        while !sink.sawBothEOF, Date() < drainDeadline {
            do {
                try await Task.sleep(for: .milliseconds(40))
            } catch {
                break
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        switch outcome {
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            throw AgentProcessRunnerError.timedOut(seconds: request.timeout)
        case .exited(let status) where status != 0:
            throw AgentProcessRunnerError.exited(
                status: status,
                detail: Self.safeFailureDetail(stdout: sink.stdout, stderr: sink.stderr)
            )
        case .exited:
            break
        }

        var files: [String: Data] = [:]
        for name in request.outputFiles {
            let url = scratch.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: request.stdoutLimit + 1) ?? Data()
            files[name] = data.count > request.stdoutLimit
                ? data.suffix(request.stdoutLimit)
                : data
        }

        return Result(
            stdout: sink.stdout,
            stderr: sink.stderr,
            stdoutWasTruncated: sink.stdoutWasTruncated,
            stderrWasTruncated: sink.stderrWasTruncated,
            outputFiles: files,
            temporaryDirectory: scratch
        )
    }

    private static func isSafeTemporaryFilename(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
    }

    private static func isSafeRelativeTemporaryPath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\")
        else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    private static func safeFailureDetail(stdout: Data, stderr: Data) -> String? {
        let source = stderr.isEmpty ? stdout : stderr
        let text = String(decoding: source.suffix(4_096), as: UTF8.self).lowercased()
        // Never return raw child output. The shared Summarizer logs localized
        // errors, and a client is allowed to echo stdin in diagnostics. Only
        // map known failure signatures to fixed, transcript-free messages.
        if text.contains("not logged in")
            || text.contains("sign in")
            || text.contains("authentication")
            || text.contains("unauthorized") {
            return String(localized: "The account isn’t signed in. Connect it in \(SettingsRow.summaryProvider.path) and try again.")
        }
        if text.contains("rate limit")
            || text.contains("usage limit")
            || text.contains("quota") {
            return String(localized: "The provider’s usage limit has been reached. Try again after it resets.")
        }
        if text.contains("offline")
            || text.contains("network")
            || text.contains("could not connect")
            || text.contains("connection failed") {
            return String(localized: "The agent couldn’t reach its provider. Check the network connection and try again.")
        }
        return nil
    }

    private enum RunOutcome {
        case exited(Int32)
        case timedOut
        case cancelled
    }

    private static func wait(for process: Process, timeout: TimeInterval) async -> RunOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Task.isCancelled {
                await kill(process)
                return .cancelled
            }
            if Date() >= deadline {
                await kill(process)
                return .timedOut
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                await kill(process)
                return .cancelled
            }
        }
        return .exited(process.terminationStatus)
    }

    private static func kill(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.75)
        while process.isRunning, Date() < deadline {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                break
            }
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private static let ignoreSIGPIPEOnce: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()
}

nonisolated enum AgentProcessRunnerError: LocalizedError, Equatable {
    case invalidExecutable
    case invalidLimits
    case invalidTemporaryFilename
    case temporaryDirectoryFailed
    case launchFailed
    case timedOut(seconds: TimeInterval)
    case exited(status: Int32, detail: String?)

    var errorDescription: String? {
        switch self {
        case .invalidExecutable:
            return String(localized: "Daisy refused to run an unknown or non-executable agent client.")
        case .invalidLimits:
            return String(localized: "The agent process limits are invalid.")
        case .invalidTemporaryFilename:
            return String(localized: "Daisy refused an unsafe temporary output path.")
        case .temporaryDirectoryFailed:
            return String(localized: "Daisy couldn’t create a private temporary folder for the agent.")
        case .launchFailed:
            return String(localized: "Daisy couldn’t start the installed agent client.")
        case .timedOut(let seconds):
            return String(localized: "The agent didn’t finish within \(Int(seconds)) seconds and was stopped.")
        case .exited(let status, let detail):
            if let detail {
                return String(localized: "The agent stopped with status \(status): \(detail)")
            }
            return String(localized: "The agent stopped with status \(status). Check that the account is signed in.")
        }
    }
}

private nonisolated final class LimitedOutputSink: @unchecked Sendable {
    private let stdoutLimit: Int
    private let stderrLimit: Int
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stdoutEOF = false
    private var stderrEOF = false
    private var didTruncateStdout = false
    private var didTruncateStderr = false

    init(stdoutLimit: Int, stderrLimit: Int) {
        self.stdoutLimit = stdoutLimit
        self.stderrLimit = stderrLimit
    }

    func appendStdout(_ data: Data) {
        lock.lock()
        stdoutBuffer.append(data)
        if stdoutBuffer.count > stdoutLimit {
            stdoutBuffer.removeFirst(stdoutBuffer.count - stdoutLimit)
            didTruncateStdout = true
        }
        lock.unlock()
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        stderrBuffer.append(data)
        if stderrBuffer.count > stderrLimit {
            stderrBuffer.removeFirst(stderrBuffer.count - stderrLimit)
            didTruncateStderr = true
        }
        lock.unlock()
    }

    func markStdoutEOF() {
        lock.lock(); stdoutEOF = true; lock.unlock()
    }

    func markStderrEOF() {
        lock.lock(); stderrEOF = true; lock.unlock()
    }

    var sawBothEOF: Bool {
        lock.lock(); defer { lock.unlock() }
        return stdoutEOF && stderrEOF
    }

    var stdout: Data {
        lock.lock(); defer { lock.unlock() }
        return stdoutBuffer
    }

    var stderr: Data {
        lock.lock(); defer { lock.unlock() }
        return stderrBuffer
    }

    var stdoutWasTruncated: Bool {
        lock.lock(); defer { lock.unlock() }
        return didTruncateStdout
    }

    var stderrWasTruncated: Bool {
        lock.lock(); defer { lock.unlock() }
        return didTruncateStderr
    }
}
