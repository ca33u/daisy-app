//
//  SharedInbox.swift
//  DaisyLink
//
//  Бэклог 15 П-1: the drop box between the share extension and the app.
//
//  A share extension gets a few seconds and a hard memory ceiling — it
//  cannot transcribe, and it must not try. All it does is put the file
//  somewhere the app will find it, with the little the system told it
//  about the file, and get out of the way.
//
//  The rule that shapes everything here: **a file leaves this box only
//  after it exists somewhere else.** П-1 names the failure it prevents —
//  a file that became a session nobody transcribes and nobody mentions
//  reads as "Daisy ate my recording". Losing it outright is the same
//  bug with the evidence deleted.
//

import Foundation

/// One file waiting for the app to pick it up.
public struct DroppedFile: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    /// Where the copy lives inside the group container.
    public var fileName: String
    /// What the file was called where it came from. The share sheet is
    /// the only place this survives: once copied, the name is ours to
    /// keep or lose, and it is often the only title a call recording
    /// has ("Call with Anna, 14 Sept").
    public var originalName: String
    public var droppedAt: Date

    public init(id: UUID = UUID(), fileName: String, originalName: String, droppedAt: Date = Date()) {
        self.id = id
        self.fileName = fileName
        self.originalName = originalName
        self.droppedAt = droppedAt
    }
}

public enum SharedInbox {
    /// Under `Library/`, not `Documents/`: nothing here is the user's
    /// to browse, and everything here is transient by design.
    public nonisolated static func directory(in container: URL) -> URL {
        container.appendingPathComponent("Library/ShareInbox", isDirectory: true)
    }

    public nonisolated static func url(of file: DroppedFile, in container: URL) -> URL {
        directory(in: container).appendingPathComponent(file.fileName)
    }

    /// Copy a shared file into the box and record it.
    ///
    /// The copy is made under a fresh UUID name: two recordings called
    /// "Новая запись 3.m4a" are ordinary, and letting the second one
    /// overwrite the first would lose audio silently.
    @discardableResult
    public nonisolated static func drop(_ source: URL, in container: URL, now: Date = Date()) throws -> DroppedFile {
        let directory = directory(in: container)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let suffix = source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)"
        let file = DroppedFile(id: id, fileName: "\(id.uuidString)\(suffix)",
                               originalName: source.lastPathComponent, droppedAt: now)
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(file.fileName))
        // The manifest is written AFTER the bytes land: a manifest entry
        // whose file is missing would send the app looking for something
        // that was never there.
        var all = pending(in: container)
        all.append(file)
        try write(all, in: container)
        return file
    }

    /// Everything still waiting, oldest first.
    ///
    /// An entry whose file has gone is dropped rather than reported: it
    /// can only mean the app already took it and was interrupted before
    /// it could tidy up, and re-reporting it would import it twice.
    public nonisolated static func pending(in container: URL) -> [DroppedFile] {
        guard let data = try? Data(contentsOf: manifestURL(in: container)),
              let all = try? JSONDecoder().decode([DroppedFile].self, from: data) else { return [] }
        return all
            .filter { FileManager.default.fileExists(atPath: url(of: $0, in: container).path) }
            .sorted { $0.droppedAt < $1.droppedAt }
    }

    /// Called by the app once the file exists as a session — never
    /// before.
    public nonisolated static func remove(_ file: DroppedFile, in container: URL) {
        try? FileManager.default.removeItem(at: url(of: file, in: container))
        let rest = pending(in: container).filter { $0.id != file.id }
        try? write(rest, in: container)
    }

    private nonisolated static func manifestURL(in container: URL) -> URL {
        directory(in: container).appendingPathComponent("inbox.json")
    }

    private nonisolated static func write(_ files: [DroppedFile], in container: URL) throws {
        try FileManager.default.createDirectory(at: directory(in: container), withIntermediateDirectories: true)
        try JSONEncoder().encode(files).write(to: manifestURL(in: container), options: .atomic)
    }
}
