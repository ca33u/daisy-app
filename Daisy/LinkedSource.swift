//
//  LinkedSource.swift
//  Daisy
//
//  Backlog 41: Daisy as a source for other apps under the open contract
//  Linked Sources 1 (Daisy-web `flow/docs/linked-sources.md`). One file,
//  `<base>/Daisy/.linked-source.json`, tells a reader such as Flow where
//  the sessions are, which frontmatter fields mean what, and which
//  projects exist under ids that survive a rename. The session format
//  itself does not change (`Docs/session-format.md` §8).
//
//  Written atomically (temporary file, then rename) into the ACTIVE base
//  only: at launch, whenever the project list changes, and when the base
//  changes. Previous bases are read-only to Daisy — except while
//  `SessionsFolderChange` moves sessions out of one, when that base's
//  manifest says `moving` and, once everything has moved (or gone to the
//  Trash), goes to the Trash too: the library, and its id, now live in
//  the new base. A move the app quit in the middle of is tidied up at the
//  next launch.
//

import Foundation
import os

// MARK: - The file

nonisolated enum LinkedSourceManifest {
    static let fileName = ".linked-source.json"
    static let spec = "linked-source/1"
    /// The app's reverse-DNS name as the contract and Flow's built-in
    /// Daisy profile know it (not the bundle identifier).
    static let app = "io.mydaisy.Daisy"

    /// `<base>/Daisy/.linked-source.json`.
    static func url(in base: URL) -> URL {
        base.appendingPathComponent("Daisy", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    struct Project: Equatable, Sendable {
        var id: String
        /// What sessions carry in `daisy_folder` today.
        var key: String
        var name: String
        /// The parent project's `id`.
        var parent: String?
        var system: Bool
    }

    /// The registry for the manifest: system folders first, then the
    /// user's in their order, each with its parent's id.
    static func projects(from folders: [SessionFolder]) -> [Project] {
        let idBySlug = Dictionary(folders.map { ($0.slug, $0.linkID) }, uniquingKeysWith: { first, _ in first })
        return folders.map { folder in
            Project(id: folder.linkID, key: folder.slug, name: folder.name,
                    parent: folder.parentSlug.flatMap { idBySlug[$0] },
                    system: SessionFolder.system.contains(folder))
        }
    }

    /// The manifest's bytes: pretty, keys sorted, so a write that changes
    /// nothing changes no byte.
    static func encode(sourceID: String, projects: [Project], moving: Bool) -> Data {
        let projectList: [[String: Any]] = projects.map { project in
            var entry: [String: Any] = [
                "id": project.id,
                "key": project.key,
                "name": project.name,
                "parent": project.parent ?? NSNull(),
            ]
            if project.system { entry["system"] = true }
            return entry
        }
        let manifest: [String: Any] = [
            "spec": spec,
            "source": [
                "id": sourceID,
                "app": app,
                "name": "Daisy",
                "open_item": "daisy://session/{id}",
                "open_project": "daisy://project/{id}",
            ],
            "items": [items],
            "projects": projectList,
            "state": ["moving": moving],
        ]
        // Only strings, bools, arrays, dictionaries and NSNull above: this
        // can't throw.
        return (try? JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
    }

    /// How a reader finds and reads a session (session-format.md §1–4).
    /// Static: it describes the format, not the library.
    private static var items: [String: Any] { [
        "type": "meeting",
        "files": ["Sessions/*/transcript.md"],
        "id": "dirname",
        "fields": [
            "title": "title",
            "date": "started",
            "duration_sec": "duration_sec",
            "project": "daisy_folder",
            "company": "daisy_tag",
            "people": "daisy_event_attendees",
            "emails": "daisy_event_emails",
        ],
        "summary": [
            ["json": "summary.json", "pointer": "/summary"],
            ["heading": "## Summary"],
        ],
        "actions": ["json": "summary.json", "pointer": "/actionItems"],
        "text": ["after_heading": "## Transcript"],
        "busy_if_exists": ".recording",
        // First match wins (§3.1, §3.4, §3.7): the demo meeting and
        // rehearsal takes are never shown; screenshot and other notes are
        // notes; a recording is a meeting wherever it is filed; a session
        // from before `daisy_kind` that sits in Notes is a note.
        "type_rules": [
            ["if": ["daisy_demo": "true"], "type": "hidden"],
            ["if": ["daisy_screenshot_note": "true"], "type": "note"],
            ["if": ["daisy_kind": "note"], "type": "note"],
            ["if": ["daisy_kind": "rehearsal"], "type": "hidden"],
            ["if": ["daisy_kind": "recording"], "type": "meeting"],
            ["if": ["daisy_folder": "notes"], "type": "note"],
        ],
    ] }

    /// The source id a manifest already on disk carries, if it is ours.
    static func sourceID(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["spec"] as? String == spec,
              let source = object["source"] as? [String: Any],
              let id = (source["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        return id
    }

    /// Writes the file whole or not at all (`.atomic`: a temporary file
    /// renamed over it), and only when the bytes differ.
    static func write(_ data: Data, to url: URL) throws {
        if (try? Data(contentsOf: url)) == data { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - The library's id

/// A library's id: stable for one base, new for a new one. The manifest
/// in the base is where it lives — so two Macs sharing a library folder,
/// or a reinstall, keep it; these defaults remember it per base as well,
/// for a manifest gone missing.
nonisolated struct LinkedSourceIdentity {
    static let defaultsKey = "daisy.linkedSourceIDs"
    static let movingFromKey = "daisy.linkedSourceMovingFrom"
    let defaults: UserDefaults

    /// The base sessions are being moved out of, from `beginMove` until
    /// `endMove` — still set at launch when the app quit in between.
    var movingFrom: URL? {
        get { defaults.string(forKey: Self.movingFromKey).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        nonmutating set {
            if let newValue { defaults.set(newValue.path, forKey: Self.movingFromKey) }
            else { defaults.removeObject(forKey: Self.movingFromKey) }
        }
    }

    func sourceID(for base: URL) -> String {
        if let onDisk = LinkedSourceManifest.sourceID(at: LinkedSourceManifest.url(in: base)) {
            remember(onDisk, for: base)
            return onDisk
        }
        if let stored = stored[Self.key(base)] { return stored }
        let fresh = UUID().uuidString
        remember(fresh, for: base)
        return fresh
    }

    func remember(_ id: String, for base: URL) {
        var all = stored
        guard all[Self.key(base)] != id else { return }
        all[Self.key(base)] = id
        defaults.set(all, forKey: Self.defaultsKey)
    }

    private var stored: [String: String] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    static func key(_ base: URL) -> String {
        base.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

// MARK: - Keeping it current

@MainActor
final class LinkedSourcePublisher {
    static let shared = LinkedSourcePublisher(
        folders: { FolderStore.shared.allFolders },
        acquireBase: { SessionsFolder.acquireBase() },
        acquireAccess: { SessionsFolder.acquireAccess(to: $0, requireWrite: true) },
        identity: LinkedSourceIdentity(defaults: .standard),
        retire: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    )

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "LinkedSource")
    private let folders: @MainActor () -> [SessionFolder]
    private let acquireBase: @MainActor () -> SessionsFolder.AccessTicket?
    /// Access to a base that isn't the active one — a move's source.
    private let acquireAccess: @MainActor (URL) -> SessionsFolder.AccessTicket?
    private let identity: LinkedSourceIdentity
    /// Puts a manifest that describes no library any more out of the way —
    /// into the Trash.
    private let retire: @MainActor (URL) throws -> Void
    private var started = false
    private var dirty = false
    private var drain: Task<Void, Never>?
    /// True while `SessionsFolderChange` moves sessions between bases.
    private(set) var moving = false
    /// Library ids a move carried into a base, by `LinkedSourceIdentity.key`:
    /// they win over a manifest the base had before, which a write still
    /// on its way could otherwise put back.
    private var carried: [String: String] = [:]

    init(folders: @escaping @MainActor () -> [SessionFolder],
         acquireBase: @escaping @MainActor () -> SessionsFolder.AccessTicket?,
         acquireAccess: @escaping @MainActor (URL) -> SessionsFolder.AccessTicket?,
         identity: LinkedSourceIdentity,
         retire: @escaping @MainActor (URL) throws -> Void) {
        self.folders = folders
        self.acquireBase = acquireBase
        self.acquireAccess = acquireAccess
        self.identity = identity
        self.retire = retire
    }

    /// From launch on, keep the active base's manifest current. The shared
    /// one stays off in the test host: it would write into the real
    /// library (`TestHost`). Until this, every call here does nothing.
    func start() async {
        if TestHost.isActive, self === Self.shared { return }
        started = true
        await tidyUpInterruptedMove()
        setNeedsWrite()
    }

    /// The project list or the active base changed. Writes coalesce: every
    /// change made in one turn of the main loop is one write.
    func setNeedsWrite() {
        guard started else { return }
        dirty = true
        guard drain == nil else { return }
        drain = Task { @MainActor in
            while dirty {
                dirty = false
                await writeActive()
            }
            drain = nil
        }
    }

    /// Waits until every requested write is on disk.
    func flush() async {
        await drain?.value
    }

    private func writeActive() async {
        guard let ticket = acquireBase() else {
            log.warning("No library folder to write the manifest into")
            return
        }
        defer { ticket.release() }
        await write(base: ticket.url, moving: moving)
    }

    private func write(base: URL, moving: Bool, sourceID: String? = nil) async {
        let data = LinkedSourceManifest.encode(
            sourceID: sourceID ?? carried[LinkedSourceIdentity.key(base)] ?? identity.sourceID(for: base),
            projects: LinkedSourceManifest.projects(from: folders()),
            moving: moving
        )
        let url = LinkedSourceManifest.url(in: base)
        do {
            try await Task.detached(priority: .utility) {
                try LinkedSourceManifest.write(data, to: url)
            }.value
        } catch {
            log.error("Couldn't write the manifest: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Moving sessions to another base

    /// Sessions start moving from `source` to `destination` (the base just
    /// made active). The library goes with them: the destination takes
    /// the source's id, and both manifests say `moving`, so a reader
    /// doesn't take a session that is between the two for deleted. The
    /// caller holds access to both folders until `endMove`.
    func beginMove(from source: URL, to destination: URL) async {
        guard started else { return }
        // A write already on its way would land after these, with the old
        // flag or the destination's old id.
        await flush()
        moving = true
        identity.movingFrom = source
        // Over a manifest the destination may have of its own: the library
        // that moves in is the one readers have linked to.
        let id = identity.sourceID(for: source)
        // The source is no longer this library's: a later "keep" there
        // starts a new one.
        carried[LinkedSourceIdentity.key(source)] = nil
        carried[LinkedSourceIdentity.key(destination)] = id
        identity.remember(id, for: destination)
        await write(base: source, moving: true, sourceID: id)
        await write(base: destination, moving: true, sourceID: id)
        setNeedsWrite()
        await flush()
    }

    /// The sessions have left `source` — moved after `beginMove`, or put in
    /// the Trash. When nothing is left there, its manifest goes to the
    /// Trash too: that folder holds no library any more. When something
    /// is, it stays, no longer `moving`.
    func endMove(from source: URL, complete: Bool) async {
        guard started else { return }
        await flush()
        moving = false
        await leave(source, complete: complete)
        identity.movingFrom = nil
        setNeedsWrite()
        await flush()
    }

    private func leave(_ source: URL, complete: Bool) async {
        let url = LinkedSourceManifest.url(in: source)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if complete {
            do {
                try retire(url)
                return
            } catch {
                log.error("Couldn't move the old manifest to the Trash: \(error.localizedDescription, privacy: .public)")
            }
        }
        await write(base: source, moving: false)
    }

    /// The app quit between `beginMove` and `endMove`: the old base still
    /// says `moving`. It is done or never will be — tidy it as `endMove`
    /// would have, by whether any session is left there. A base that can't
    /// be reached now is tried again next launch.
    private func tidyUpInterruptedMove() async {
        guard let source = identity.movingFrom else { return }
        guard let ticket = acquireAccess(source) else {
            log.warning("The base an interrupted move left can't be reached; trying next launch")
            return
        }
        defer { ticket.release() }
        await leave(source, complete: !Self.hasSessions(in: source))
        identity.movingFrom = nil
    }

    /// Whether any session is left in a base. A folder that can't be
    /// listed has some, as far as anyone knows: never take "not read" for
    /// "not there".
    nonisolated static func hasSessions(in base: URL) -> Bool {
        let sessions = SessionsFolder.sessionsDirectory(in: base)
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessions.path) else { return false }
        guard let entries = try? fm.contentsOfDirectory(
            at: sessions, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return true }
        return entries.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}
