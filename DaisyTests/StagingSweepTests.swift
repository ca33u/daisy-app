//
//  StagingSweepTests.swift
//  DaisyTests
//
//  Abandoned import / re-transcription staging folders are cleared on
//  the first scan after launch; anything still being written, anything
//  recent, and anything that isn't a staging folder stays.
//

import Foundation
import Testing
@testable import Daisy

struct StagingSweepTests {
    private let fm = FileManager.default

    private func folder(_ name: String, in root: URL, hoursAgo: Double, fileHoursAgo: Double? = nil) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("system_audio.m4a")
        try Data([1, 2, 3]).write(to: file)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-(fileHoursAgo ?? hoursAgo) * 3600)],
                             ofItemAtPath: file.path)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-hoursAgo * 3600)],
                             ofItemAtPath: dir.path)
    }

    @Test func removesOnlyQuietStagingFolders() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("StagingSweepTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        try folder(".daisy-import-old", in: root, hoursAgo: 30)
        try folder(".daisy-retranscribe-old", in: root, hoursAgo: 10)
        // An old folder with a fresh file inside: the date inside counts.
        try folder(".daisy-import-live", in: root, hoursAgo: 30, fileHoursAgo: 0.1)
        // What a fresh import of an old recording looks like: the copy
        // keeps the original's date, the folder is new.
        try folder(".daisy-import-copying", in: root, hoursAgo: 0.1, fileHoursAgo: 300)
        try folder(".daisy-retranscribe-recent", in: root, hoursAgo: 1)
        try folder("2026-10-01T10-00-00Z", in: root, hoursAgo: 100)
        try folder(".daisy-trash", in: root, hoursAgo: 100)
        let stray = root.appendingPathComponent(".daisy-import-file")
        try Data([9]).write(to: stray)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-100 * 3600)], ofItemAtPath: stray.path)

        let removed = StagingSweep.sweep(roots: [root]).sorted()
        #expect(removed == [".daisy-import-old", ".daisy-retranscribe-old"])
        let left = Set(try fm.contentsOfDirectory(atPath: root.path))
        #expect(left == [".daisy-import-live", ".daisy-import-copying", ".daisy-retranscribe-recent", "2026-10-01T10-00-00Z",
                         ".daisy-trash", ".daisy-import-file"])
        // A root that doesn't exist is skipped, not an error.
        #expect(StagingSweep.sweep(roots: [root.appendingPathComponent("missing")]).isEmpty)
    }
}
