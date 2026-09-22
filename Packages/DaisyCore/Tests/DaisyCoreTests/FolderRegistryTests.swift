import Testing
import Foundation
@testable import DaisyCore

@Suite("FolderRegistry (§9, Ф3-C)")
struct FolderRegistryTests {
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
