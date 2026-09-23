//
//  SharedInboxTests.swift
//  DaisyCoreTests
//
//  Бэклог 15 П-1. The share extension's only job is to not lose the
//  file. These are the ways it could.
//

import Foundation
import Testing
@testable import DaisyLink

@Suite("A shared file is not lost between the share sheet and the app")
struct SharedInboxTests {
    private func container() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The name has to be exactly what the user's file is called — the
    /// original name is the only title a call recording usually has —
    /// so uniqueness goes in the directory, not the filename.
    private func source(_ name: String, bytes: Int = 64) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    @Test func aDroppedFileIsCopiedAndListed() throws {
        let box = try container()
        let dropped = try SharedInbox.drop(try source("Запись 1.m4a"), in: box)
        #expect(dropped.originalName == "Запись 1.m4a")
        let pending = SharedInbox.pending(in: box)
        #expect(pending.count == 1)
        #expect(FileManager.default.fileExists(atPath: SharedInbox.url(of: pending[0], in: box).path))
    }

    /// Two recordings with the same name is the ordinary case — the
    /// Voice Memos default, and every "Новая запись 3.m4a" from Notes.
    /// One overwriting the other would lose audio with no trace.
    @Test func twoFilesWithTheSameNameBothSurvive() throws {
        let box = try container()
        try SharedInbox.drop(try source("Новая запись 3.m4a", bytes: 10), in: box)
        try SharedInbox.drop(try source("Новая запись 3.m4a", bytes: 20), in: box)
        let pending = SharedInbox.pending(in: box)
        #expect(pending.count == 2)
        let sizes = pending.map { (try? Data(contentsOf: SharedInbox.url(of: $0, in: box)).count) ?? 0 }
        #expect(Set(sizes) == [10, 20])
    }

    /// The whole rule: taken out only once it exists elsewhere.
    @Test func aFileStaysUntilItIsExplicitlyRemoved() throws {
        let box = try container()
        let dropped = try SharedInbox.drop(try source("call.m4a"), in: box)
        #expect(SharedInbox.pending(in: box).count == 1)
        SharedInbox.remove(dropped, in: box)
        #expect(SharedInbox.pending(in: box).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: SharedInbox.url(of: dropped, in: box).path))
    }

    /// The app took the bytes and was killed before tidying the
    /// manifest. Reporting that entry again would import it twice.
    @Test func aManifestEntryWithoutItsFileIsNotReported() throws {
        let box = try container()
        let dropped = try SharedInbox.drop(try source("half.m4a"), in: box)
        try FileManager.default.removeItem(at: SharedInbox.url(of: dropped, in: box))
        #expect(SharedInbox.pending(in: box).isEmpty)
    }

    @Test func theOldestWaitsFirst() throws {
        let box = try container()
        let now = Date()
        try SharedInbox.drop(try source("second.m4a"), in: box, now: now)
        try SharedInbox.drop(try source("first.m4a"), in: box, now: now.addingTimeInterval(-60))
        #expect(SharedInbox.pending(in: box).map(\.originalName) == ["first.m4a", "second.m4a"])
    }
}
