//
//  SyncTransport.swift
//  DaisyCore
//
//  The seam between the engine and the cloud. CloudKit implements it in
//  the apps; the tests drive two engines through one in-memory instance
//  and watch a phone and a Mac converge.
//

import Foundation

public nonisolated struct SyncChanges: Sendable {
    public var records: [SessionSyncRecord]
    /// Ids whose record is gone on the server. The engine never deletes
    /// local folders for these (backlog 9: a tombstone must not be able
    /// to destroy the only copy) — it only forgets its sync memory.
    public var deletedIDs: [String]
    public var token: Data?
    public init(records: [SessionSyncRecord], deletedIDs: [String], token: Data?) {
        self.records = records
        self.deletedIDs = deletedIDs
        self.token = token
    }
}

public protocol SyncTransport: Sendable {
    /// Everything changed since `token` (all of it when nil).
    func fetchChanges(since token: Data?) async throws -> SyncChanges
    /// Save whole records (the engine sends complete records).
    func push(_ records: [SessionSyncRecord]) async throws
    func delete(_ ids: [String]) async throws
    /// Remove everything this app ever put on the server — the person's
    /// "delete my data from iCloud". Local folders are not touched.
    func eraseEverything() async throws
}

/// One shared store two engines can talk through in a test.
public actor InMemorySyncTransport: SyncTransport {
    private var records: [String: SessionSyncRecord] = [:]
    private var log: [(seq: Int, id: String, deleted: Bool)] = []
    private var seq = 0

    public init() {}

    public func fetchChanges(since token: Data?) async throws -> SyncChanges {
        let from = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        var seen: [String: Bool] = [:]
        for entry in log where entry.seq > from { seen[entry.id] = entry.deleted }
        let changed = seen.filter { !$0.value }.compactMap { records[$0.key] }
        let deleted = seen.filter { $0.value }.map(\.key)
        return SyncChanges(records: changed, deletedIDs: deleted, token: Data(String(seq).utf8))
    }

    public func push(_ new: [SessionSyncRecord]) async throws {
        for record in new {
            records[record.id] = record
            seq += 1
            log.append((seq, record.id, false))
        }
    }

    public func eraseEverything() async throws {
        for id in records.keys { records[id] = nil; seq += 1 }
    }

    public func delete(_ ids: [String]) async throws {
        for id in ids {
            records[id] = nil
            seq += 1
            log.append((seq, id, true))
        }
    }

    public func record(_ id: String) -> SessionSyncRecord? { records[id] }
}
