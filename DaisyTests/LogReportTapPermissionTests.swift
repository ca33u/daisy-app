import Foundation
import Testing
@testable import Daisy

/// Field report 27.10: a meeting recorded only the person's voice — the
/// process tap handed over zeros — and the log report couldn't say whether
/// System Audio Recording was allowed. `sysAudioRec=` in its Permissions
/// line now carries what Daisy's own probe last heard.
@Suite("Log report: System Audio Recording")
struct LogReportTapPermissionTests {
    typealias P = ProcessTapPermission

    @Test("No tap, no permission to report")
    func unavailable() {
        #expect(P.diagnosticsLabel(available: false, asked: true, denied: true) == "n/a")
        #expect(P.diagnosticsLabel(available: false, asked: false, denied: false) == "n/a")
    }

    @Test("Never probed reads notAsked, whatever a stale flag says")
    func notAsked() {
        #expect(P.diagnosticsLabel(available: true, asked: false, denied: false) == "notAsked")
        #expect(P.diagnosticsLabel(available: true, asked: false, denied: true) == "notAsked")
    }

    @Test("A probe's answer is labelled as one")
    func probed() {
        #expect(P.diagnosticsLabel(available: true, asked: true, denied: false) == "granted(probe)")
        #expect(P.diagnosticsLabel(available: true, asked: true, denied: true) == "denied(probe)")
    }

    @Test("The field sits in the Permissions line of the report header")
    func inHeader() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Daisy/LogReporter.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let line = try #require(source.split(separator: "\n").first { $0.contains("Permissions: mic=") })
        #expect(line.contains("sysAudioRec=\\(ProcessTapPermission.currentDiagnosticsLabel)"))
    }
}
