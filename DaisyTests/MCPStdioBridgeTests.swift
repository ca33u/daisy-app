//
//  MCPStdioBridgeTests.swift
//  DaisyTests
//
//  The sh + curl bridge that Claude's and Codex's entries run. A broken
//  script fails silently inside the client — Daisy just never shows up —
//  so the cheap checks live here.
//

import Foundation
import Testing
@testable import Daisy

@Suite("MCP stdio bridge")
struct MCPStdioBridgeTests {
    /// Run `/bin/sh` with the bridge's arguments, feeding `input`.
    private func runShell(_ arguments: [String], input: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: MCPStdioBridge.command)
        process.arguments = arguments
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test("parses as POSIX sh")
    func parses() throws {
        #expect(try runShell(["-n", "-c", MCPStdioBridge.script], input: "") == 0)
    }

    @Test("exits cleanly when the client closes stdin, without calling Daisy")
    func exitsOnEOF() throws {
        // Port 1 refuses connections: a POST would retry for ~10 s and
        // exit 1, so a quick 0 proves no request was made.
        let arguments = MCPStdioBridge.arguments(port: 1, token: nil)
        #expect(try runShell(arguments, input: "\n\n") == 0)
    }

    @Test("no line starts with [ — Codex's TOML section parser would stop there")
    func noBracketLines() {
        let lines = MCPStdioBridge.script.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(!lines.contains { $0.hasPrefix("[") })
    }

    @Test("arguments: -c, script, versioned name, URL, then the token if any")
    func argumentShape() {
        #expect(MCPStdioBridge.arguments(port: 54321, token: nil)
            == ["-c", MCPStdioBridge.script, MCPStdioBridge.name, "http://127.0.0.1:54321/mcp"])
        #expect(MCPStdioBridge.arguments(port: 54321, token: "t0k").last == "t0k")
    }
}
