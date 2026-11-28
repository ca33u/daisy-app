// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  SessionStorageMonitoringTests.swift
//  DaisyTests
//

import Foundation
import Testing
@testable import Daisy

@Suite("Library storage monitoring")
struct SessionStorageMonitoringTests {
    @Test("Creating an empty folder changes the Library fingerprint")
    func detectsFinderCreatedEmptyFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-storage-monitor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let before = SessionStore.storageFingerprint(for: [root])
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Тестовая", isDirectory: true),
            withIntermediateDirectories: true
        )
        let after = SessionStore.storageFingerprint(for: [root])

        #expect(before != after)
    }
}
