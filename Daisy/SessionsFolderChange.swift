//
//  SessionsFolderChange.swift
//  Daisy
//
//  Applies the user's explicit choice when the active recordings folder
//  changes. Previous custom roots remain bookmarked until every directory
//  has either moved or reached the Trash, so a partial failure never turns
//  into another "all my recordings disappeared" incident.
//

import Foundation
import os

enum SessionsFolderExistingFilesAction: Sendable, Equatable {
    case move
    case delete
    case keep
}

struct SessionsFolderChangeRequest: Identifiable, Sendable {
    let id = UUID()
    let sourceBaseURL: URL
    let destinationBaseURL: URL
    let destinationIsDefault: Bool
    let sourceWasCustom: Bool
    let existingFolderCount: Int
}

struct SessionsFolderChangeReport: Sendable {
    let completedCount: Int
    let remainingCount: Int
    let failedNames: [String]

    var isComplete: Bool { remainingCount == 0 && failedNames.isEmpty }
}

enum SessionsFolderChangeError: LocalizedError {
    case sourceUnavailable
    case destinationUnavailable
    case bookmarkFailed

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            String(localized: "Daisy couldn't access the current recordings folder.")
        case .destinationUnavailable:
            String(localized: "Daisy couldn't write to the new recordings folder.")
        case .bookmarkFailed:
            String(localized: "Daisy couldn't remember the new recordings folder.")
        }
    }
}

@MainActor
enum SessionsFolderChange {
    nonisolated static let log = Logger(
        subsystem: "app.essazanov.Daisy", category: "SessionsFolderChange"
    )

    /// A real destination change always needs an explicit user decision,
    /// regardless of the best-effort folder count shown in the dialog.
    nonisolated static func requiresUserDecision(
        _ request: SessionsFolderChangeRequest
    ) -> Bool {
        !SessionsFolder.sameFolder(
            request.sourceBaseURL,
            request.destinationBaseURL
        )
    }

    static func prepare(
        destination: URL,
        destinationIsDefault: Bool = false
    ) -> SessionsFolderChangeRequest? {
        guard let defaultBase = SessionsFolder.defaultBase() else { return nil }
        let currentCustom = SessionsFolder.resolveUserFolder()
        let source = currentCustom ?? defaultBase

        if SessionsFolder.sameFolder(source, destination) {
            return SessionsFolderChangeRequest(
                sourceBaseURL: source,
                destinationBaseURL: destination,
                destinationIsDefault: destinationIsDefault,
                sourceWasCustom: currentCustom != nil,
                existingFolderCount: 0
            )
        }

        let ticket = currentCustom.flatMap { SessionsFolder.acquireAccess(to: $0) }
        defer { ticket?.release() }
        // The count is presentation-only. Settings must still ask what to do
        // when it is zero: the root may be deliberately empty, or it may have
        // been temporarily unavailable at the moment of this best-effort scan.
        let count = sessionDirectories(in: SessionsFolder.sessionsDirectory(in: source)).count
        return SessionsFolderChangeRequest(
            sourceBaseURL: source,
            destinationBaseURL: destination,
            destinationIsDefault: destinationIsDefault,
            sourceWasCustom: currentCustom != nil,
            existingFolderCount: count
        )
    }

    /// Refresh a bookmark when the user chooses the already-active folder.
    static func reauthorize(_ request: SessionsFolderChangeRequest) async throws {
        if request.destinationIsDefault {
            SessionsFolder.clearUserFolder()
        } else if !SessionsFolder.setUserFolder(request.destinationBaseURL) {
            throw SessionsFolderChangeError.bookmarkFailed
        }
        await SessionStore.shared.refresh()
    }

    static func apply(
        _ action: SessionsFolderExistingFilesAction,
        request: SessionsFolderChangeRequest
    ) async throws -> SessionsFolderChangeReport {
        // Persist the new destination before touching data. If the process is
        // interrupted halfway through, the old custom root remains in the
        // legacy list and both sides are visible on the next launch.
        if request.sourceWasCustom {
            guard SessionsFolder.rememberLegacyFolder(request.sourceBaseURL) else {
                throw SessionsFolderChangeError.sourceUnavailable
            }
        }
        if request.destinationIsDefault {
            SessionsFolder.clearUserFolder()
        } else if !SessionsFolder.setUserFolder(request.destinationBaseURL) {
            throw SessionsFolderChangeError.bookmarkFailed
        }

        if action == .keep {
            await SessionStore.shared.refresh()
            return SessionsFolderChangeReport(
                completedCount: 0,
                remainingCount: request.existingFolderCount,
                failedNames: []
            )
        }

        let sourceTicket = request.sourceWasCustom
            ? SessionsFolder.acquireAccess(to: request.sourceBaseURL, requireWrite: true)
            : nil
        if request.sourceWasCustom, sourceTicket == nil {
            await SessionStore.shared.refresh()
            throw SessionsFolderChangeError.sourceUnavailable
        }
        defer { sourceTicket?.release() }

        let destinationTicket = request.destinationIsDefault
            ? nil
            : SessionsFolder.acquireAccess(
                to: request.destinationBaseURL,
                requireWrite: true
            )
        if !request.destinationIsDefault, destinationTicket == nil {
            await SessionStore.shared.refresh()
            throw SessionsFolderChangeError.destinationUnavailable
        }
        defer { destinationTicket?.release() }

        let sourceDirectory = SessionsFolder.sessionsDirectory(in: request.sourceBaseURL)
        let destinationDirectory = SessionsFolder.sessionsDirectory(in: request.destinationBaseURL)
        let report = await Task.detached(priority: .utility) {
            switch action {
            case .move:
                return moveSessionDirectories(from: sourceDirectory, to: destinationDirectory)
            case .delete:
                return trashSessionDirectories(in: sourceDirectory)
            case .keep:
                preconditionFailure("Handled before filesystem work")
            }
        }.value

        // `isComplete`, not `remainingCount == 0`. The count comes from
        // re-listing the source, and that listing swallows its error
        // (`try?` → `[]`) — so an external drive that goes away
        // mid-move reads as "nothing left there" while `failedNames` is
        // full of sessions that never made it. Forgetting the folder
        // then drops it from the legacy list, and recordings that are
        // physically fine stop being scanned: the same "absent from
        // this scan ⇒ delete the record of it" class that has cost this
        // project data three times (audit 2026-09-01).
        if request.sourceWasCustom, report.isComplete {
            SessionsFolder.forgetLegacyFolder(request.sourceBaseURL)
        } else if request.sourceWasCustom {
            log.warning("Keeping the old folder in the legacy list — \(report.remainingCount, privacy: .public) session(s) still there, \(report.failedNames.count, privacy: .public) failed to move")
        }
        await SessionStore.shared.refresh()
        return report
    }

    nonisolated private static func sessionDirectories(in root: URL) -> [URL] {
        let values = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        return (values ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    nonisolated static func moveSessionDirectories(
        from sourceRoot: URL,
        to destinationRoot: URL
    ) -> SessionsFolderChangeReport {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        } catch {
            let names = sessionDirectories(in: sourceRoot).map(\.lastPathComponent)
            return SessionsFolderChangeReport(
                completedCount: 0,
                remainingCount: names.count,
                failedNames: names
            )
        }

        let sources = sessionDirectories(in: sourceRoot)
        var completed = 0
        var failed: [String] = []
        for source in sources {
            let destination = uniqueDestination(
                named: source.lastPathComponent,
                in: destinationRoot
            )
            do {
                do {
                    try fm.moveItem(at: source, to: destination)
                } catch {
                    try copyThenRemove(source: source, destination: destination)
                }
                completed += 1
            } catch {
                failed.append(source.lastPathComponent)
            }
        }
        let remaining = sessionDirectories(in: sourceRoot).count
        return SessionsFolderChangeReport(
            completedCount: completed,
            remainingCount: remaining,
            failedNames: failed
        )
    }

    nonisolated private static func trashSessionDirectories(
        in sourceRoot: URL
    ) -> SessionsFolderChangeReport {
        let fm = FileManager.default
        let sources = sessionDirectories(in: sourceRoot)
        var completed = 0
        var failed: [String] = []
        for source in sources {
            do {
                var resultingURL: NSURL?
                try fm.trashItem(at: source, resultingItemURL: &resultingURL)
                completed += 1
            } catch {
                failed.append(source.lastPathComponent)
            }
        }
        return SessionsFolderChangeReport(
            completedCount: completed,
            remainingCount: sessionDirectories(in: sourceRoot).count,
            failedNames: failed
        )
    }

    nonisolated private static func uniqueDestination(named name: String, in root: URL) -> URL {
        let fm = FileManager.default
        let preferred = root.appendingPathComponent(name, isDirectory: true)
        guard fm.fileExists(atPath: preferred.path) else { return preferred }
        var suffix = 2
        while true {
            let candidate = root.appendingPathComponent(
                "\(name)-migrated-\(suffix)",
                isDirectory: true
            )
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }

    /// Cross-volume fallback. Copy into a hidden staging directory, compare
    /// file count and byte size, publish it atomically, then remove source.
    /// If source removal fails, discard the copy and keep the original as the
    /// single source of truth.
    nonisolated private static func copyThenRemove(source: URL, destination: URL) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(
            ".daisy-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        guard directorySignature(source) == directorySignature(staging) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fm.moveItem(at: staging, to: destination)
        do {
            try fm.removeItem(at: source)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    nonisolated private static func directorySignature(_ directory: URL) -> DirectorySignature {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return DirectorySignature(files: 0, bytes: 0) }
        var files = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return DirectorySignature(files: files, bytes: bytes)
    }

    nonisolated private struct DirectorySignature: Equatable {
        let files: Int
        let bytes: Int64
    }
}
