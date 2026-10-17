import CloudKit
import Foundation
import Testing
@testable import DaisyCore

@MainActor
@Suite("CloudKit refuses incomplete pages and concurrent overwrites")
struct CloudKitSyncReliabilityTests {
    @Test func oneFailedItemRejectsTheWholePage() throws {
        let results: [String: Result<Int, any Error>] = [
            "received": .success(1), "missing": .failure(CKError(.networkFailure))
        ]
        #expect(throws: CKError.self) { try CloudKitSyncTransport.requireSuccesses(results) }
        let complete: [String: Result<Int, any Error>] = ["received": .success(1)]
        #expect(try CloudKitSyncTransport.requireSuccesses(complete) == ["received": 1])
    }

    @Test func aConflictInsideAnAtomicBatchStillTriggersRefetch() throws {
        let id = CKRecord.ID(recordName: "meeting")
        let conflict = CKError(.serverRecordChanged)
        let batch = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: conflict]])
        #expect(CloudKitSyncTransport.needsRefetch(batch))
        #expect(!CloudKitSyncTransport.needsRefetch(CKError(.networkFailure)))
        let results: [String: Result<Int, any Error>] = [
            "dependent": .failure(CKError(.batchRequestFailed)),
            "conflicting": .failure(conflict)
        ]
        do {
            _ = try CloudKitSyncTransport.requireSuccesses(results)
            Issue.record("A conflicting batch must fail")
        } catch {
            #expect(CloudKitSyncTransport.needsRefetch(error))
        }
    }

    @Test func aSaveUsesACopyOfTheVersionThatWasMerged() {
        let id = CKRecord.ID(recordName: "meeting")
        let known = CKRecord(recordType: "Session", recordID: id)
        known["frontmatter"] = "old" as CKRecordValue
        let saving = CloudKitSyncTransport.recordForSave(type: "Session", id: id, known: known)
        saving["frontmatter"] = "edited" as CKRecordValue
        #expect(saving !== known)
        #expect(saving.recordID == known.recordID)
        #expect(known["frontmatter"] as? String == "old")
        #expect(saving["frontmatter"] as? String == "edited")
    }

    @Test func missingTranscriptAndMissingDeclaredFilesAreNotEmptyContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CKRecord(recordType: "Session", recordID: .init(recordName: "meeting"))
        #expect(throws: (any Error).self) { try CloudKitSyncTransport.decode(session: session, files: []) }
        let body = root.appendingPathComponent("body.md")
        try Data("## Transcript\n\nHello".utf8).write(to: body)
        session["body"] = CKAsset(fileURL: body)
        session["filePaths"] = "[\"summary.json\"]" as CKRecordValue
        #expect(throws: (any Error).self) { try CloudKitSyncTransport.decode(session: session, files: []) }
        session["filePaths"] = "[]" as CKRecordValue
        #expect(try CloudKitSyncTransport.decode(session: session, files: []).body.contains("Hello"))
        try FileManager.default.removeItem(at: body)
        #expect(throws: (any Error).self) { try CloudKitSyncTransport.decode(session: session, files: []) }
    }

    @Test func anObsoleteFileFromAnEarlierPageIsNotResurrected() throws {
        let body = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Transcript".utf8).write(to: body)
        defer { try? FileManager.default.removeItem(at: body) }
        let session = CKRecord(recordType: "Session", recordID: .init(recordName: "meeting"))
        session["body"] = CKAsset(fileURL: body)
        session["filePaths"] = "[]" as CKRecordValue
        let obsolete = CKRecord(recordType: "SessionFile", recordID: .init(recordName: "meeting|summary.json"))
        obsolete["path"] = "summary.json" as CKRecordValue
        let decoded = try CloudKitSyncTransport.decode(session: session, files: [obsolete])
        #expect(decoded.files.isEmpty)
    }

    final class FaultingCloud: SyncTransport, @unchecked Sendable {
        let cloud = InMemorySyncTransport()
        var failFetch = false
        var raceNextPush = false
        func fetchChanges(since token: Data?) async throws -> SyncChanges {
            if failFetch { throw CKError(.networkFailure) }
            return try await cloud.fetchChanges(since: token)
        }
        func push(_ records: [SessionSyncRecord]) async throws {
            if raceNextPush, let outgoing = records.first,
               var remote = await cloud.record(outgoing.id) {
                raceNextPush = false
                remote.body = "## Transcript\n\nremote edit\n"
                remote.bodyStamp = outgoing.bodyStamp + 10
                remote.editor = "other-device"
                try await cloud.push([remote])
                throw CKError(.serverRecordChanged)
            }
            try await cloud.push(records)
        }
        func delete(_ ids: [String]) async throws { try await cloud.delete(ids) }
        func eraseEverything() async throws { try await cloud.eraseEverything() }
    }

    @Test func aFailedFetchKeepsThePersistedCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = SessionsBase(base: root)
        try FileManager.default.createDirectory(at: base.sessionsDirectory, withIntermediateDirectories: true)
        let cloud = FaultingCloud()
        let stateURL = root.appendingPathComponent("sync-state.json")
        let engine = SessionSyncEngine(base: base, stateURL: stateURL, transport: cloud)
        _ = try await engine.syncOnce()
        let checkpoint = try #require(engine.state.changeToken)
        cloud.failFetch = true
        do { _ = try await engine.syncOnce(); Issue.record("Expected a failed fetch") }
        catch { #expect(error is CKError) }
        #expect(engine.state.changeToken == checkpoint)
        #expect(SyncState.load(from: stateURL).changeToken == checkpoint)
    }

    @Test func anInterveningEditIsRefetchedAndBothBodiesSurvive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = SessionsBase(base: root)
        let id = "2026-10-13T10-00-00Z"
        let dir = base.sessionsDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("transcript.md")
        try "---\ntitle: \"Original\"\ndaisy_kind: recording\ndaisy_origin: iphone\n---\n\n## Transcript\n\nOriginal body\n".write(to: url, atomically: true, encoding: .utf8)
        let cloud = FaultingCloud()
        let stateURL = root.appendingPathComponent("sync-state.json")
        let engine = SessionSyncEngine(base: base, stateURL: stateURL, transport: cloud)
        _ = try await engine.syncOnce()
        try SessionEditing.saveTitle("Phone title", to: url)
        try SessionEditing.save(transcript: "phone edit", to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)
        cloud.raceNextPush = true
        do { _ = try await engine.syncOnce(); Issue.record("Expected the competing write to refuse this push") }
        catch { #expect(CloudKitSyncTransport.needsRefetch(error)) }
        #expect(engine.state.changeToken == nil)
        #expect(SyncState.load(from: stateURL).changeToken == nil)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("phone edit"))
        let retried = try await engine.syncOnce()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(SessionDocument.parseFrontmatter(in: text).title == "Phone title")
        #expect(text.contains("remote edit"))
        #expect(retried.conflicts == 1)
        let conflicts = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("transcript.conflict-") }
        #expect(conflicts.count == 1)
        let conflict = try #require(conflicts.first)
        #expect(try String(contentsOf: conflict, encoding: .utf8).contains("phone edit"))
    }
}
