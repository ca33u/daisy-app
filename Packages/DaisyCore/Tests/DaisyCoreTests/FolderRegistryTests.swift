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
