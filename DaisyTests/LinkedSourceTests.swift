//
//  LinkedSourceTests.swift
//  DaisyTests
//
//  Backlog 41: the library's manifest for readers such as Flow
//  (`.linked-source.json`), projects' stable ids and `daisy://` links.
//

import Foundation
import Testing
@testable import Daisy

@Suite("Projects' stable ids (backlog 41)")
struct ProjectStableIDTests {
    @Test func everyFolderWithoutOneGetsOne() {
        let folders = [SessionFolder(name: "Acme", stableID: "A"), SessionFolder(name: "Old"),
                       SessionFolder(name: "Empty", stableID: "")]
        let out = FolderStore.givingOutStableIDs(folders)
        #expect(out[0].stableID == "A")
        #expect(out[1].stableID?.isEmpty == false)
        #expect(out[2].stableID?.isEmpty == false)
        #expect(Set(out.compactMap(\.stableID)).count == 3)
        // Nothing to do the second time.
        #expect(FolderStore.givingOutStableIDs(out).map(\.stableID) == out.map(\.stableID))
    }

    @Test func storedFoldersWithoutAnIDStillDecode() throws {
        let data = Data(#"[{"name":"Work","parentSlug":null},{"name":"Side","parentSlug":"work"}]"#.utf8)
        let decoded = try JSONDecoder().decode([SessionFolder].self, from: data)
        #expect(decoded.map(\.stableID) == [nil, nil])
        #expect(decoded[1].parentSlug == "work")
    }

    @Test func aSlugChangingRenameKeepsTheIDTheParentAndTheChildren() throws {
        let folders = [
            SessionFolder(name: "Clients", stableID: "C"),
            SessionFolder(name: "Acme", parentSlug: "clients", stableID: "A"),
            SessionFolder(name: "Big Co", stableID: "B"),
            SessionFolder(name: "Big Co Calls", parentSlug: "big co", stableID: "BC"),
        ]
        let (next, renamed) = try #require(
            FolderStore.beginningRename(of: folders[2], to: " Big Company ", in: folders))
        #expect(renamed.name == "Big Company")
        #expect(renamed.stableID == "B")
        // Before the old one, which stays until its sessions have moved.
        #expect(next.map(\.slug) == ["clients", "acme", "big company", "big co", "big co calls"])
        #expect(next.first { $0.slug == "big co calls" }?.parentSlug == "big company")

        let (_, child) = try #require(FolderStore.beginningRename(of: folders[1], to: "Acme Inc", in: folders))
        #expect(child.parentSlug == "clients")
        #expect(child.stableID == "A")
    }

    @Test func aRenameThatIsNotOneIsRefused() {
        let folders = [SessionFolder(name: "Acme", stableID: "A"), SessionFolder(name: "Work", stableID: "W")]
        #expect(FolderStore.beginningRename(of: folders[0], to: "ACME", in: folders) == nil)     // same slug
        #expect(FolderStore.beginningRename(of: folders[0], to: "work", in: folders) == nil)     // taken
        #expect(FolderStore.beginningRename(of: folders[0], to: "Inbox", in: folders) == nil)    // system
        #expect(FolderStore.beginningRename(of: folders[0], to: "  ", in: folders) == nil)
        #expect(FolderStore.beginningRename(of: .inbox, to: "Mail", in: folders) == nil)
    }

    @Test func linkIDs() {
        #expect(SessionFolder.inbox.linkID == "inbox")
        #expect(SessionFolder.notes.linkID == "notes")
        #expect(SessionFolder(name: "Acme", stableID: "A").linkID == "A")
    }
}

@Suite("The library's manifest (backlog 41)")
struct LinkedSourceManifestTests {
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func projectsCarryTheirParentsID() {
        let folders = SessionFolder.system + [
            SessionFolder(name: "Clients", stableID: "C"),
            SessionFolder(name: "Acme Inc", parentSlug: "clients", stableID: "A"),
            SessionFolder(name: "Lost", parentSlug: "gone", stableID: "L"),
        ]
        let projects = LinkedSourceManifest.projects(from: folders)
        #expect(projects == [
            .init(id: "inbox", key: "inbox", name: "Inbox", parent: nil, system: true),
            .init(id: "notes", key: "notes", name: "Notes", parent: nil, system: true),
            .init(id: "C", key: "clients", name: "Clients", parent: nil, system: false),
            .init(id: "A", key: "acme inc", name: "Acme Inc", parent: "C", system: false),
            .init(id: "L", key: "lost", name: "Lost", parent: nil, system: false),
        ])
    }

    @Test func theFileIsTheContract() throws {
        let projects = LinkedSourceManifest.projects(from: SessionFolder.system + [
            SessionFolder(name: "Acme Inc", stableID: "A"),
        ])
        let data = LinkedSourceManifest.encode(sourceID: "LIB", projects: projects, moving: false)
        let manifest = try object(data)
        #expect(manifest["spec"] as? String == "linked-source/1")
        let source = try #require(manifest["source"] as? [String: Any])
        #expect(source["id"] as? String == "LIB")
        #expect(source["app"] as? String == "io.mydaisy.Daisy")
        #expect(source["name"] as? String == "Daisy")
        #expect(source["open_item"] as? String == "daisy://session/{id}")
        #expect(source["open_project"] as? String == "daisy://project/{id}")

        let items = try #require(manifest["items"] as? [[String: Any]])
        #expect(items.count == 1)
        let item = items[0]
        #expect(item["type"] as? String == "meeting")
        #expect(item["files"] as? [String] == ["Sessions/*/transcript.md"])
        #expect(item["id"] as? String == "dirname")
        #expect(item["fields"] as? [String: String] == [
            "title": "title", "date": "started", "duration_sec": "duration_sec", "project": "daisy_folder",
            "company": "daisy_tag", "people": "daisy_event_attendees", "emails": "daisy_event_emails",
        ])
        #expect(item["busy_if_exists"] as? String == ".recording")
        #expect((item["text"] as? [String: String])?["after_heading"] == "## Transcript")
        #expect((item["actions"] as? [String: String]) == ["json": "summary.json", "pointer": "/actionItems"])
        let summary = try #require(item["summary"] as? [[String: String]])
        #expect(summary == [["json": "summary.json", "pointer": "/summary"], ["heading": "## Summary"]])
        let rules = try #require(item["type_rules"] as? [[String: Any]])
        let pairs = rules.map { (($0["if"] as? [String: String]) ?? [:], $0["type"] as? String ?? "") }
        #expect(pairs.map(\.0) == [
            ["daisy_demo": "true"], ["daisy_screenshot_note": "true"], ["daisy_kind": "note"],
            ["daisy_kind": "rehearsal"], ["daisy_kind": "recording"], ["daisy_folder": "notes"],
        ])
        #expect(pairs.map(\.1) == ["hidden", "note", "note", "hidden", "meeting", "note"])

        let list = try #require(manifest["projects"] as? [[String: Any]])
        #expect(list.map { $0["id"] as? String } == ["inbox", "notes", "A"])
        #expect(list[0]["system"] as? Bool == true)
        #expect(list[2]["system"] == nil)
        #expect(list[2]["key"] as? String == "acme inc")
        #expect(list[2]["name"] as? String == "Acme Inc")
        // `parent` is there, and null — not left out.
        #expect(list[2]["parent"] is NSNull)
        #expect((manifest["state"] as? [String: Bool]) == ["moving": false])
        // Same input, same bytes: a write that changes nothing changes no byte.
        #expect(LinkedSourceManifest.encode(sourceID: "LIB", projects: projects, moving: false) == data)
        #expect(LinkedSourceManifest.encode(sourceID: "LIB", projects: projects, moving: true) != data)
    }

    @Test func aManifestOnDiskNamesItsLibrary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = LinkedSourceManifest.url(in: dir)
        #expect(url.path.hasSuffix("/Daisy/.linked-source.json"))
        #expect(LinkedSourceManifest.sourceID(at: url) == nil)
        try LinkedSourceManifest.write(LinkedSourceManifest.encode(sourceID: "LIB", projects: [], moving: false), to: url)
        #expect(LinkedSourceManifest.sourceID(at: url) == "LIB")
        try Data(#"{"spec":"something-else/2","source":{"id":"X"}}"#.utf8).write(to: url)
        #expect(LinkedSourceManifest.sourceID(at: url) == nil)
    }
}

@Suite("The library's id (backlog 41)")
struct LinkedSourceIdentityTests {
    private let scratch = ScratchDefaults("LinkedSourceIdentity")

    @Test func oneIDPerBaseAndTheFileOnDiskWins() throws {
        let fm = FileManager.default
        let a = fm.temporaryDirectory.appendingPathComponent("linked-a-\(UUID().uuidString)")
        let b = fm.temporaryDirectory.appendingPathComponent("linked-b-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        let identity = LinkedSourceIdentity(defaults: scratch.make())
        let first = identity.sourceID(for: a)
        #expect(identity.sourceID(for: a) == first)
        #expect(identity.sourceID(for: b) != first)
        // A manifest already there — another Mac's, a reinstall's — is the library's id.
        try LinkedSourceManifest.write(LinkedSourceManifest.encode(sourceID: "ON-DISK", projects: [], moving: false),
                                       to: LinkedSourceManifest.url(in: a))
        #expect(identity.sourceID(for: a) == "ON-DISK")
        try fm.removeItem(at: LinkedSourceManifest.url(in: a))
        #expect(identity.sourceID(for: a) == "ON-DISK")
    }
}

@Suite("Keeping the manifest current (backlog 41)")
@MainActor
struct LinkedSourcePublisherTests {
    private let scratch = ScratchDefaults("LinkedSourcePublisher")

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linked-pub-\(UUID().uuidString)")
        var active: URL
        var folders: [SessionFolder] = SessionFolder.system + [SessionFolder(name: "Acme", stableID: "A")]
        var retired: [URL] = []
        var writes = 0
        init() { active = root.appendingPathComponent("one") }
        deinit { try? FileManager.default.removeItem(at: root) }
        func manifest(in base: URL) throws -> [String: Any] {
            let data = try Data(contentsOf: LinkedSourceManifest.url(in: base))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func sourceID(in base: URL) throws -> String? {
            (try manifest(in: base)["source"] as? [String: Any])?["id"] as? String
        }
        func moving(in base: URL) throws -> Bool? {
            (try manifest(in: base)["state"] as? [String: Any])?["moving"] as? Bool
        }
    }

    private func publisher(_ fixture: Fixture, defaults: UserDefaults? = nil,
                           retire: (@MainActor (URL) throws -> Void)? = nil) -> LinkedSourcePublisher {
        LinkedSourcePublisher(
            folders: { fixture.folders },
            acquireBase: {
                fixture.writes += 1
                return SessionsFolder.AccessTicket(url: fixture.active, securityScoped: false)
            },
            acquireAccess: { SessionsFolder.AccessTicket(url: $0, securityScoped: false) },
            identity: LinkedSourceIdentity(defaults: defaults ?? scratch.make()),
            retire: retire ?? { url in fixture.retired.append(url) }
        )
    }

    @Test func nothingIsWrittenBeforeStartAndEverythingAfter() async throws {
        let fixture = Fixture()
        let pub = publisher(fixture)
        pub.setNeedsWrite()
        await pub.flush()
        #expect(!FileManager.default.fileExists(atPath: LinkedSourceManifest.url(in: fixture.active).path))

        await pub.start()
        await pub.flush()
        let first = try fixture.manifest(in: fixture.active)
        #expect((first["projects"] as? [[String: Any]])?.map { $0["key"] as? String } == ["inbox", "notes", "acme"])

        // A rename that changes the slug: same id, new key.
        fixture.folders = SessionFolder.system + [SessionFolder(name: "Acme Corp", stableID: "A")]
        pub.setNeedsWrite()
        await pub.flush()
        let second = try fixture.manifest(in: fixture.active)
        let project = try #require((second["projects"] as? [[String: Any]])?.last)
        #expect(project["id"] as? String == "A")
        #expect(project["key"] as? String == "acme corp")
        #expect(try fixture.sourceID(in: fixture.active) == (first["source"] as? [String: Any])?["id"] as? String)
        // Atomic: no temporary file left beside it.
        let left = try FileManager.default.contentsOfDirectory(atPath: fixture.active.appendingPathComponent("Daisy").path)
        #expect(left == [LinkedSourceManifest.fileName])
    }

    @Test func changesInOneTurnAreOneWrite() async {
        let fixture = Fixture()
        let pub = publisher(fixture)
        await pub.start()
        await pub.flush()
        let before = fixture.writes
        for name in ["B", "C", "D"] {
            fixture.folders.append(SessionFolder(name: name, stableID: name))
            pub.setNeedsWrite()
        }
        await pub.flush()
        #expect(fixture.writes == before + 1)
    }

    @Test func aMovedLibraryKeepsItsIDAndSaysSoWhileMoving() async throws {
        let fixture = Fixture()
        let pub = publisher(fixture)
        await pub.start()
        await pub.flush()
        let source = fixture.active
        let id = try #require(try fixture.sourceID(in: source))
        let destination = fixture.root.appendingPathComponent("two")
        // The destination was a library of its own once; the one moving in wins.
        try LinkedSourceManifest.write(LinkedSourceManifest.encode(sourceID: "OLD-TWO", projects: [], moving: false),
                                       to: LinkedSourceManifest.url(in: destination))
        fixture.active = destination   // `SessionsFolderChange` switches the base first
        // A write on its way when the move begins: it reads the
        // destination's old manifest, and must not have the last word.
        pub.setNeedsWrite()

        await pub.beginMove(from: source, to: destination)
        #expect(pub.moving)
        #expect(try fixture.moving(in: source) == true)
        #expect(try fixture.moving(in: destination) == true)
        #expect(try fixture.sourceID(in: destination) == id)

        await pub.endMove(from: source, complete: true)
        #expect(!pub.moving)
        #expect(try fixture.moving(in: destination) == false)
        #expect(try fixture.sourceID(in: destination) == id)
        #expect(fixture.retired == [LinkedSourceManifest.url(in: source)])
    }

    @Test func aMoveThatLeftSessionsBehindLeavesTheOldManifest() async throws {
        let fixture = Fixture()
        let pub = publisher(fixture)
        await pub.start()
        await pub.flush()
        let source = fixture.active
        let destination = fixture.root.appendingPathComponent("two")
        fixture.active = destination
        await pub.beginMove(from: source, to: destination)
        await pub.endMove(from: source, complete: false)
        #expect(fixture.retired.isEmpty)
        #expect(try fixture.moving(in: source) == false)
        #expect(try fixture.sourceID(in: source) == fixture.sourceID(in: destination))
    }

    @Test func aManifestThatWontGoToTheTrashStopsSayingMoving() async throws {
        let fixture = Fixture()
        let pub = publisher(fixture, retire: { _ in throw CocoaError(.fileWriteNoPermission) })
        await pub.start()
        await pub.flush()
        let source = fixture.active
        fixture.active = fixture.root.appendingPathComponent("two")
        await pub.beginMove(from: source, to: fixture.active)
        await pub.endMove(from: source, complete: true)
        #expect(try fixture.moving(in: source) == false)
    }

    @Test func oldSessionsPutInTheTrashTakeTheOldManifest() async throws {
        let fixture = Fixture()
        let pub = publisher(fixture)
        await pub.start()
        await pub.flush()
        let source = fixture.active
        fixture.active = fixture.root.appendingPathComponent("two")
        await pub.endMove(from: source, complete: true)   // `.delete`: no beginMove
        #expect(fixture.retired == [LinkedSourceManifest.url(in: source)])
        #expect(try fixture.sourceID(in: fixture.active) != nil)
    }

    @Test(arguments: [false, true])
    func aMoveTheAppQuitInTheMiddleOfIsTidiedAtLaunch(sessionLeftBehind: Bool) async throws {
        let fixture = Fixture()
        let defaults = scratch.make()
        let first = publisher(fixture, defaults: defaults)
        await first.start()
        await first.flush()
        let source = fixture.active
        fixture.active = fixture.root.appendingPathComponent("two")
        await first.beginMove(from: source, to: fixture.active)
        if sessionLeftBehind {
            try FileManager.default.createDirectory(
                at: SessionsFolder.sessionsDirectory(in: source).appendingPathComponent("2026-11-03T10-00-00Z"),
                withIntermediateDirectories: true)
        }
        // Quit here; the next launch:
        let next = publisher(fixture, defaults: defaults)
        await next.start()
        await next.flush()
        #expect(try fixture.moving(in: fixture.active) == false)
        if sessionLeftBehind {
            #expect(fixture.retired.isEmpty)
            #expect(try fixture.moving(in: source) == false)
        } else {
            #expect(fixture.retired == [LinkedSourceManifest.url(in: source)])
        }
        #expect(LinkedSourceIdentity(defaults: defaults).movingFrom == nil)
    }

    @Test func aFolderThatCantBeListedStillHasSessions() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("linked-has-\(UUID().uuidString)")
        let sessions = SessionsFolder.sessionsDirectory(in: base)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sessions.path)
            try? fm.removeItem(at: base)
        }
        #expect(!LinkedSourcePublisher.hasSessions(in: base))
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data().write(to: sessions.appendingPathComponent("loose.txt"))
        try fm.createDirectory(at: sessions.appendingPathComponent(".daisy-import-x"), withIntermediateDirectories: true)
        #expect(!LinkedSourcePublisher.hasSessions(in: base))
        try fm.createDirectory(at: sessions.appendingPathComponent("2026-11-03T10-00-00Z"), withIntermediateDirectories: true)
        #expect(LinkedSourcePublisher.hasSessions(in: base))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sessions.path)
        #expect(LinkedSourcePublisher.hasSessions(in: base))
    }
}

@Suite("daisy:// links (backlog 41)")
struct DaisyLinkTests {
    @Test(arguments: [
        ("daisy://session/2026-05-17T12-37-36Z", DaisyLink.session("2026-05-17T12-37-36Z")),
        ("DAISY://Session/2026-05-16T22-30-00+08-00", .session("2026-05-16T22-30-00+08-00")),
        ("daisy://project/0F8A6E52-1D2B-4C1E-9C6E-2F3B4A5C6D7E", .project("0F8A6E52-1D2B-4C1E-9C6E-2F3B4A5C6D7E")),
        ("daisy://project/inbox/", .project("inbox")),
        ("daisy://project/acme%20inc", .project("acme inc")),
    ])
    func parses(_ raw: String, _ expected: DaisyLink) throws {
        let url = try #require(URL(string: raw))
        #expect(DaisyLink.isDaisyLink(url))
        #expect(DaisyLink(url) == expected)
    }

    @Test(arguments: [
        "daisy://session/", "daisy://session", "daisy://session/a/b", "daisy://session/..",
        "daisy://meeting/x", "https://mydaisy.io/session/x", "daisy:session/x",
    ])
    func refuses(_ raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(DaisyLink(url) == nil)
    }
}
