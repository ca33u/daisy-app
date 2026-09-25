//
//  CloudKitSyncTransport.swift
//  DaisyCore
//
//  backlog 9 Ф3-A: the transport for text — CloudKit private database,
//  one custom zone, change tokens. iCloud Drive was rejected on purpose
//  (1.0.7.59: an evicted file read as empty and a tombstone destroyed
//  the only copy; and it dictates where the Mac's sessions folder is).
//  Audio never goes through here (Ф3-B: local network, on demand).
//
//  Schema (development environment creates fields on first save):
//    Session      recordName = <session id>
//                 frontmatter (String, JSON {key: raw value})
//                 stamps      (String, JSON {key: seconds})
//                 body        (CKAsset — the Markdown body, a file)
//                 bodyStamp   (Double)
//                 editor      (String — device id)
//                 filePaths   (String, JSON [relative path])
//    SessionFile  recordName = <session id>|<relative path>
//                 session     (Reference → Session, cascade)
//                 path        (String), stamp (Double), data (CKAsset)
//
//  A push is whole-record (`savePolicy: .allKeys`): the engine already
//  merged, the server just takes what it is given. A pull turns zone
//  changes into complete `SessionSyncRecord`s — a session whose Session
//  record didn't change but a file did is fetched by id so the engine
//  always sees the whole thing.
//

import CloudKit
import Foundation
import os

public nonisolated enum SyncError: LocalizedError {
    case noAccount
    case cloud(String)
    public var errorDescription: String? {
        switch self {
        case .noAccount: "Not signed in to iCloud on this device."
        case .cloud(let message): message
        }
    }
}

public final class CloudKitSyncTransport: SyncTransport, @unchecked Sendable {
    public static let defaultContainerID = "iCloud.app.essazanov.Daisy"
    static let zoneName = "DaisySessions"
    static let sessionType = "Session"
    static let fileType = "SessionFile"

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let log = Logger(subsystem: DaisyCore.logSubsystem, category: "CloudKit")
    private let scratch: URL
    private var zoneReady = false

    public init(containerID: String = CloudKitSyncTransport.defaultContainerID) {
        container = CKContainer(identifier: containerID)
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    // MARK: - Account & zone

    public func accountAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        guard await accountAvailable() else { throw SyncError.noAccount }
        do {
            _ = try await database.recordZone(for: zoneID)
        } catch {
            // Cancelled is not "no zone": creating one now would only be
            // cancelled too, and the text would hide what happened.
            if Self.isCancellation(error) { throw error }
            log.notice("Zone lookup: \(Self.describe(error), privacy: .public)")
            do {
                _ = try await database.save(CKRecordZone(zoneID: zoneID))
                log.notice("Created zone \(Self.zoneName, privacy: .public)")
            } catch {
                if Self.isCancellation(error) { throw error }
                throw SyncError.cloud("zone: " + Self.describe(error))
            }
        }
        zoneReady = true
    }

    /// The operation was cancelled — by the task that ran it or by the
    /// system (the app leaving the screen) — rather than refused. Not a
    /// failure of the sync; the next pass does the same work.
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let ck = error as? CKError, ck.code == .operationCancelled { return true }
        return false
    }

    /// The CloudKit error with everything the server said — the code
    /// name, the server's own description, the underlying error — so a
    /// breadcrumb reads "serverRejectedRequest: Invalid bundle ID for
    /// container" instead of "error 15".
    public static func describe(_ error: any Error) -> String {
        guard let ck = error as? CKError else { return error.localizedDescription }
        var parts = ["\(ck.code)"]
        if let server = ck.userInfo["ServerErrorDescription"] as? String { parts.append(server) }
        if let underlying = ck.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("← \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)")
        }
        if let partial = ck.partialErrorsByItemID, let first = partial.values.first {
            parts.append("first item: " + describe(first))
        }
        if parts.count == 1 { parts.append(ck.localizedDescription) }
        return parts.joined(separator: " — ")
    }

    // MARK: - Fetch

    public func fetchChanges(since token: Data?) async throws -> SyncChanges {
        try await ensureZone()
        let startToken = token.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        var sessionRecords: [String: CKRecord] = [:]
        var fileRecords: [String: [CKRecord]] = [:]   // session id → files
        var touchedSessions = Set<String>()
        var deleted: [String] = []
        var newToken: CKServerChangeToken? = startToken
        var more = true
        var pageToken = startToken
        while more {
            let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: pageToken)
            for (_, modification) in result.modificationResultsByID {
                guard let record = try? modification.get().record else { continue }
                if record.recordType == Self.sessionType {
                    sessionRecords[record.recordID.recordName] = record
                    touchedSessions.insert(record.recordID.recordName)
                } else if record.recordType == Self.fileType, let sessionID = record["sessionID"] as? String {
                    fileRecords[sessionID, default: []].append(record)
                    touchedSessions.insert(sessionID)
                }
            }
            for deletion in result.deletions where deletion.recordType == Self.sessionType {
                deleted.append(deletion.recordID.recordName)
            }
            newToken = result.changeToken
            more = result.moreComing
            pageToken = result.changeToken
        }
        // Sessions whose files changed but whose Session record didn't:
        // fetch the record so the engine gets the whole thing.
        let missing = touchedSessions.subtracting(sessionRecords.keys).subtracting(deleted)
        if !missing.isEmpty {
            let ids = missing.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
            let fetched = try await database.records(for: ids)
            for (id, result) in fetched { if let record = try? result.get() { sessionRecords[id.recordName] = record } }
        }
        // Every file of every touched session: the Session record lists
        // its paths; fetch the ones this batch didn't carry.
        var records: [SessionSyncRecord] = []
        for (id, record) in sessionRecords {
            var files = fileRecords[id] ?? []
            let paths = Self.decodeStrings(record["filePaths"] as? String)
            let have = Set(files.compactMap { $0["path"] as? String })
            let need = paths.filter { !have.contains($0) }.map { CKRecord.ID(recordName: Self.fileRecordName(id, $0), zoneID: zoneID) }
            if !need.isEmpty {
                let fetched = try await database.records(for: need)
                files += fetched.values.compactMap { try? $0.get() }
            }
            records.append(try Self.decode(session: record, files: files))
        }
        let tokenData = newToken.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        return SyncChanges(records: records, deletedIDs: deleted, token: tokenData)
    }

    // MARK: - Push

    public func push(_ records: [SessionSyncRecord]) async throws {
        try await ensureZone()
        for record in records {
            var toSave: [CKRecord] = []
            let sessionID = CKRecord.ID(recordName: record.id, zoneID: zoneID)
            let session = CKRecord(recordType: Self.sessionType, recordID: sessionID)
            session["frontmatter"] = Self.encode(record.frontmatter) as CKRecordValue
            session["stamps"] = Self.encode(record.frontmatterStamps) as CKRecordValue
            session["bodyStamp"] = record.bodyStamp as CKRecordValue
            session["editor"] = record.editor as CKRecordValue
            session["filePaths"] = Self.encode(Array(record.files.keys).sorted()) as CKRecordValue
            session["body"] = CKAsset(fileURL: try tempFile(Data(record.body.utf8)))
            toSave.append(session)
            for (path, file) in record.files {
                let fileRecord = CKRecord(recordType: Self.fileType, recordID: CKRecord.ID(recordName: Self.fileRecordName(record.id, path), zoneID: zoneID))
                fileRecord["session"] = CKRecord.Reference(recordID: sessionID, action: .deleteSelf)
                fileRecord["sessionID"] = record.id as CKRecordValue
                fileRecord["path"] = path as CKRecordValue
                fileRecord["stamp"] = file.stamp as CKRecordValue
                fileRecord["data"] = CKAsset(fileURL: try tempFile(file.data))
                toSave.append(fileRecord)
            }
            // Files the session no longer has: the old record's list says
            // which SessionFile records to drop.
            var toDelete: [CKRecord.ID] = []
            if let existing = try? await database.record(for: sessionID) {
                let old = Self.decodeStrings(existing["filePaths"] as? String)
                for path in old where record.files[path] == nil {
                    toDelete.append(CKRecord.ID(recordName: Self.fileRecordName(record.id, path), zoneID: zoneID))
                }
            }
            let (saved, _) = try await database.modifyRecords(saving: toSave, deleting: toDelete, savePolicy: .allKeys, atomically: true)
            for (_, result) in saved { _ = try result.get() }
            log.info("Pushed \(record.id, privacy: .public) with \(record.files.count, privacy: .public) file(s)")
        }
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    public func delete(_ ids: [String]) async throws {
        try await ensureZone()
        let recordIDs = ids.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        // Files cascade (`deleteSelf` reference).
        let (_, deleted) = try await database.modifyRecords(saving: [], deleting: recordIDs, savePolicy: .allKeys, atomically: false)
        for (_, result) in deleted { _ = try? result.get() }
    }

    /// J-0: the whole zone goes — every Session and SessionFile record
    /// this container holds for the person. Change tokens die with it;
    /// the engine resets its memory afterwards.
    public func eraseEverything() async throws {
        guard await accountAvailable() else { throw SyncError.noAccount }
        do {
            _ = try await database.deleteRecordZone(withID: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound {
            // Nothing there — that is the goal.
        } catch {
            throw SyncError.cloud("erase: " + Self.describe(error))
        }
        zoneReady = false
        log.notice("Erased zone \(Self.zoneName, privacy: .public) on request")
    }

    // MARK: - Coding

    static func fileRecordName(_ sessionID: String, _ path: String) -> String { sessionID + "|" + path }

    static func encode<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func decodeStrings(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func decodeMap<T: Decodable>(_ json: String?, as: T.Type) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func decode(session: CKRecord, files: [CKRecord]) throws -> SessionSyncRecord {
        var out = SessionSyncRecord(id: session.recordID.recordName)
        out.frontmatter = decodeMap(session["frontmatter"] as? String, as: [String: String].self) ?? [:]
        out.frontmatterStamps = decodeMap(session["stamps"] as? String, as: [String: Double].self) ?? [:]
        out.bodyStamp = session["bodyStamp"] as? Double ?? 0
        out.editor = session["editor"] as? String ?? ""
        if let asset = session["body"] as? CKAsset, let url = asset.fileURL, let data = try? Data(contentsOf: url) {
            out.body = String(decoding: data, as: UTF8.self)
        }
        for file in files {
            guard let path = file["path"] as? String, let asset = file["data"] as? CKAsset,
                  let url = asset.fileURL, let data = try? Data(contentsOf: url) else { continue }
            out.files[path] = SyncFile(data: data, stamp: file["stamp"] as? Double ?? 0)
        }
        return out
    }

    private func tempFile(_ data: Data) throws -> URL {
        let url = scratch.appendingPathComponent(UUID().uuidString)
        try data.write(to: url, options: .atomic)
        return url
    }
}
