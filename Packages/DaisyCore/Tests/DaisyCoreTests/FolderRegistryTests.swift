import Testing
import Foundation
@testable import DaisyCore

@Suite("FolderRegistry (§9, Ф3-C)")
struct FolderRegistryTests {
    @Test func aFoldersTrackersRideTheRegistryAndSurviveARecase() throws {
        var phone = FolderRegistry()
        phone.upsert(name: "Daisy")
        phone.setProject(ProjectContext(repo: "ca33u/daisy-app", linearTeam: "DAI"), for: "daisy")
        let data = try #require(phone.encoded())
        let decoded = try #require(FolderRegistry.decode(data))
        #expect(decoded.entry("daisy")?.project?.repo == "ca33u/daisy-app")
        var mac = decoded
        mac.upsert(name: "DAISY")                       // a recase on the other side
        #expect(mac.entry("daisy")?.project?.linearTeam == "DAI")
        mac.setProject(ProjectContext(), for: "daisy")  // emptied → cleared
        #expect(mac.entry("daisy")?.project == nil)
    }

    @Test func newerEntryWinsAndTombstonesHold() {
        let t0 = Date(timeIntervalSince1970: 1_000), t1 = t0.addingTimeInterval(10), t2 = t0.addingTimeInterval(20)
        var mac = FolderRegistry()
        mac.upsert(name: "Work", at: t0)
        mac.upsert(name: "Clients", at: t0)
        var phone = mac
        phone.upsert(name: "Side Notes", parentSlug: "Work", at: t1)     // phone adds a child
        mac.remove("clients", at: t1)                                      // Mac deletes
        mac.upsert(name: "WORK", at: t2)                                   // Mac recases
        let merged = mac.merged(with: phone)
        #expect(merged.entry("work")?.name == "WORK")
        #expect(merged.entry("side notes")?.parentSlug == "work")
        #expect(merged.entry("clients") == nil)
        #expect(merged.entries["clients"]?.isDeleted == true)
        // Symmetric.
        #expect(phone.merged(with: mac) == merged)
        // A session naming the deleted slug brings it back, newer than the tombstone.
        var revived = merged
        revived.upsert(name: "Clients", at: t2.addingTimeInterval(1))
        #expect(revived.entry("clients") != nil)
    }

    @Test func removingAParentDetachesChildrenAndSystemSlugsAreRefused() {
        let t = Date(timeIntervalSince1970: 2_000)
        var r = FolderRegistry()
        r.upsert(name: "Project", at: t)
        r.upsert(name: "Child", parentSlug: "project", at: t)
        r.remove("project", at: t.addingTimeInterval(1))
        #expect(r.entry("child")?.parentSlug == nil)
        #expect(r.upsert(name: "Inbox") == "inbox")
        #expect(r.entries["inbox"] == nil)
        #expect(r.live.map(\.slug) == ["child"])
        let data = r.encoded()!
        #expect(FolderRegistry.decode(data) == r)
    }

    // MARK: Backlog 41 — stable ids

    @Test func anEntryKeepsItsIDThroughARecaseARemovalAndARevival() throws {
        let t0 = Date(timeIntervalSince1970: 3_000)
        var r = FolderRegistry()
        r.upsert(name: "Acme", at: t0)
        let id = try #require(r.entry("acme")?.id)
        #expect(r.entry("acme")?.idAssignedAt == t0)
        r.upsert(name: "ACME", id: "SOMETHING-ELSE", at: t0.addingTimeInterval(1))   // a live id stays
        #expect(r.entry("acme")?.id == id)
        r.remove("acme", at: t0.addingTimeInterval(2))
        #expect(r.entries["acme"]?.id == id)
        r.upsert(name: "Acme", at: t0.addingTimeInterval(3))                         // §9 brings it back
        #expect(r.entry("acme")?.id == id)
        #expect(r.slug(forID: id) == "acme")
        let data = try #require(r.encoded())
        #expect(FolderRegistry.decode(data) == r)
    }

    @Test func theNewSlugOfARenameTakesTheOldID() throws {
        let t0 = Date(timeIntervalSince1970: 4_000)
        var r = FolderRegistry()
        r.upsert(name: "Acme", id: "A", at: t0)
        r.upsert(name: "Acme Corp", id: "A", at: t0.addingTimeInterval(5))
        r.remove("acme", at: t0.addingTimeInterval(6))
        #expect(r.entry("acme corp")?.id == "A")
        #expect(r.entry("acme corp")?.idAssignedAt == t0)   // when it was first given out
        #expect(r.slug(forID: "A") == "acme corp")
        // A new project under the old name is not the renamed one — with an
        // id of its own, or with none (another device's §9 revival)…
        let kvs = r
        r.upsert(name: "Acme", id: "NEW", at: t0.addingTimeInterval(7))
        #expect(r.entry("acme")?.id == "NEW")
        var phone = kvs
        phone.upsert(name: "Acme", at: t0.addingTimeInterval(8))
        let phoneID = try #require(phone.entry("acme")?.id)
        #expect(phoneID != "A")
        // …and no merge with the stored tombstone hands it the renamed one's.
        #expect(r.merged(with: kvs).entry("acme")?.id == "NEW")
        #expect(kvs.merged(with: r).entry("acme")?.id == "NEW")
        #expect(phone.merged(with: kvs).entry("acme")?.id == phoneID)
        #expect(r.merged(with: kvs).slug(forID: "A") == "acme corp")
        // A device that was offline through all of it still has the old
        // project live under A: the new one keeps its own, on both sides.
        var offline = FolderRegistry()
        offline.upsert(name: "Acme", id: "A", at: t0)
        #expect(offline.merged(with: r).entry("acme")?.id == "NEW")
        #expect(r.merged(with: offline).entry("acme")?.id == "NEW")
        #expect(r.merged(with: offline).entry("acme corp")?.id == "A")
        // …also when the offline device edited it last, and its entry wins.
        offline.upsert(name: "ACME", at: t0.addingTimeInterval(9))
        #expect(offline.merged(with: r).entry("acme")?.name == "ACME")
        #expect(offline.merged(with: r).entry("acme")?.id == "NEW")
        #expect(r.merged(with: offline).entry("acme")?.id == "NEW")
    }

    @Test func twoDevicesThatGaveOutIDsSettleOnTheEarlier() {
        let t0 = Date(timeIntervalSince1970: 5_000)
        var mac = FolderRegistry(), phone = FolderRegistry()
        mac.upsert(name: "Acme", id: "MAC", at: t0)
        phone.upsert(name: "Acme", id: "PHONE", at: t0.addingTimeInterval(10))
        phone.upsert(name: "ACME", at: t0.addingTimeInterval(20))   // the phone's entry is newer…
        let merged = mac.merged(with: phone)
        #expect(merged.entry("acme")?.name == "ACME")                // …and wins the name,
        #expect(merged.entry("acme")?.id == "MAC")                   // not the id.
        #expect(merged.entry("acme")?.idAssignedAt == t0)
        #expect(phone.merged(with: mac) == merged)
        // An entry an older version wrote has no id; the merge takes the other's.
        var old = FolderRegistry(entries: ["acme": .init(name: "Acme", updatedAt: t0.addingTimeInterval(30))])
        old = old.merged(with: mac)
        #expect(old.entry("acme")?.id == "MAC")
    }
}

@Suite("Forward compatibility (backlog 9 rule)")
struct ForwardCompatibilityTests {
    /// New fields optional on read, unknown fields kept on write — for
    /// the two structures two versions of Daisy share.
    @Test func unknownFieldsSurviveARoundTripAndNewOnesAreOptional() throws {
        let stateJSON = """
        {"deviceID":"D1","sessions":{"s1":{"frontmatter":{"title":"T"},"bodyHash":"h","futureFlag":true}},
         "futureTop":{"a":[1,2]},"lastSyncAt":0}
        """
        let state = try JSONDecoder().decode(SyncState.self, from: Data(stateJSON.utf8))
        #expect(state.pendingDeletes.isEmpty && state.tombstones.isEmpty)
        #expect(state.extra["futureTop"] == .object(["a": .array([.number(1), .number(2)])]))
        #expect(state.sessions["s1"]?.extra["futureFlag"] == .bool(true))
        let back = try JSONDecoder().decode(SyncState.self, from: JSONEncoder().encode(state))
        #expect(back == state)

        let registryJSON = """
        {"entries":{"work":{"name":"Work","updatedAt":1000,"colour":"red"}},"schema":2}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let registry = try decoder.decode(FolderRegistry.self, from: Data(registryJSON.utf8))
        #expect(registry.entries["work"]?.extra["colour"] == .string("red"))
        #expect(registry.extra["schema"] == .number(2))
        let encoded = try #require(registry.encoded())
        let again = try #require(FolderRegistry.decode(encoded))
        #expect(again.entries["work"]?.extra["colour"] == .string("red"))
        #expect(again.extra["schema"] == .number(2))
    }
}
