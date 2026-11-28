// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  SessionsFolderChangeTests.swift
//  DaisyTests
//

import Testing
import Foundation
@testable import Daisy

@Suite("Recordings folder migration")
struct SessionsFolderChangeTests {
    private func makeBase(_ name: String, under root: URL) throws -> URL {
        let base = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: SessionsFolder.sessionsDirectory(in: base),
            withIntermediateDirectories: true
        )
        return base
    }

    @Test("Changing destination asks even when the current folder count is zero")
    func emptySourceStillRequiresDecision() {
        let request = SessionsFolderChangeRequest(
            sourceBaseURL: URL(fileURLWithPath: "/tmp/daisy-source"),
            destinationBaseURL: URL(fileURLWithPath: "/tmp/daisy-destination"),
            destinationIsDefault: false,
            sourceWasCustom: true,
            existingFolderCount: 0
        )

        #expect(SessionsFolderChange.requiresUserDecision(request))
    }

    @Test("Choosing the active destination only refreshes access")
    func sameDestinationDoesNotRequireDecision() {
        let folder = URL(fileURLWithPath: "/tmp/daisy-same-folder")
        let request = SessionsFolderChangeRequest(
            sourceBaseURL: folder,
            destinationBaseURL: folder,
            destinationIsDefault: false,
            sourceWasCustom: true,
            existingFolderCount: 0
        )

        #expect(!SessionsFolderChange.requiresUserDecision(request))
    }

    @Test("Move preserves empty and populated recording folders")
    func movePreservesEveryFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-storage-change-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeBase("source", under: root)
        let destination = try makeBase("destination", under: root)
        let sourceSessions = SessionsFolder.sessionsDirectory(in: source)
        let destinationSessions = SessionsFolder.sessionsDirectory(in: destination)

        try FileManager.default.createDirectory(
            at: sourceSessions.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: true
        )
        let populated = sourceSessions.appendingPathComponent("populated", isDirectory: true)
        try FileManager.default.createDirectory(at: populated, withIntermediateDirectories: true)
        try Data("transcript".utf8).write(to: populated.appendingPathComponent("transcript.md"))

        let report = SessionsFolderChange.moveSessionDirectories(
            from: sourceSessions,
            to: destinationSessions
        )

        #expect(report.isComplete)
        #expect(report.completedCount == 2)
        #expect(FileManager.default.fileExists(atPath: destinationSessions.appendingPathComponent("empty").path))
        #expect(FileManager.default.fileExists(atPath: destinationSessions.appendingPathComponent("populated/transcript.md").path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: sourceSessions.path).isEmpty) == true)
    }

    @Test("Move never overwrites a same-named destination folder")
    func moveRenamesConflicts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-storage-conflict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeBase("source", under: root)
        let destination = try makeBase("destination", under: root)
        let sourceSessions = SessionsFolder.sessionsDirectory(in: source)
        let destinationSessions = SessionsFolder.sessionsDirectory(in: destination)

        let sourceFolder = sourceSessions.appendingPathComponent("same", isDirectory: true)
        let existingFolder = destinationSessions.appendingPathComponent("same", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: existingFolder, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceFolder.appendingPathComponent("value.txt"))
        try Data("destination".utf8).write(to: existingFolder.appendingPathComponent("value.txt"))

        let report = SessionsFolderChange.moveSessionDirectories(
            from: sourceSessions,
            to: destinationSessions
        )

        #expect(report.isComplete)
        let original = try String(contentsOf: existingFolder.appendingPathComponent("value.txt"), encoding: .utf8)
        let migrated = try String(
            contentsOf: destinationSessions.appendingPathComponent("same-migrated-2/value.txt"),
            encoding: .utf8
        )
        #expect(original == "destination")
        #expect(migrated == "source")
    }
}
