//
//  RegistryStoreICloudTests.swift
//  DaisyCoreTests
//
//  16.11: the project list and the vocabulary go to iCloud's key-value
//  store only when the owner says so. On the Mac that is the sync switch,
//  off by default; before this both rode there from the first launch.
//

import Foundation
import Testing
@testable import DaisyCore

/// iCloud, as far as a registry store can tell. Counts every touch: a
/// store with iCloud off must make none.
@MainActor
private final class FakeCloud: RegistryCloud {
    var values: [String: Data] = [:]
    private(set) var reads = 0
    private(set) var writes = 0
    private(set) var observing = false
    private var changed: (@MainActor () -> Void)?

    func data(forKey key: String) -> Data? { reads += 1; return values[key] }
    func set(_ data: Data, forKey key: String) { writes += 1; values[key] = data }
    func removeValue(forKey key: String) { writes += 1; values[key] = nil }
    func startObserving(_ changed: @escaping @MainActor () -> Void) { observing = true; self.changed = changed }
    func stopObserving() { observing = false; changed = nil }

    /// Another device wrote.
    func arrive(_ data: Data, forKey key: String) {
        values[key] = data
        changed?()
    }
}

/// Defaults of a test's own, gone from disk when it ends. A suite named
/// the usual way leaves a plist in ~/Library/Preferences that outlives
/// `removePersistentDomain`; one named by an absolute path keeps its file
/// there instead, in a temporary folder removed with this instance.
private final class ScratchSuites: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []

    func make() -> UserDefaults {
        let name = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaisyCoreTestDefaults/registry.\(UUID().uuidString)/defaults").path
        lock.withLock { names.append(name) }
        return UserDefaults(suiteName: name)!
    }

    deinit {
        for name in names {
            UserDefaults().removePersistentDomain(forName: name)
            CFPreferencesAppSynchronize(name as CFString)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: name).deletingLastPathComponent())
        }
    }
}

@MainActor
@Suite("Registries reach iCloud only when told to")
struct RegistryStoreICloudTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private let suites = ScratchSuites()

    private func scratch() -> UserDefaults { suites.make() }

    private func folders(_ names: String..., notes: String? = nil) -> FolderRegistry {
        var registry = FolderRegistry()
        for name in names {
            let slug = registry.upsert(name: name, at: t0)
            if let notes { registry.setProject(ProjectContext(notes: notes), for: slug, at: t0) }
        }
        return registry
    }

    // MARK: - Folders

    @Test func withICloudOffTheFolderStoreNeverTouchesIt() {
        let cloud = FakeCloud()
        cloud.values[FolderRegistry.kvsKey] = folders("Elsewhere").encoded()
        let defaults = scratch()
        let store = FolderRegistryStore(defaults: defaults, usesICloud: false, cloud: cloud)
        store.update { $0.upsert(name: "Work") }
        store.update { $0.setProject(ProjectContext(notes: "who is who"), for: "work") }
        store.pull()
        #expect(cloud.reads == 0)
        #expect(cloud.writes == 0)
        #expect(!cloud.observing)
        #expect(store.registry.entry("elsewhere") == nil)

        // …and the device keeps its own: a relaunch finds the notes.
        let relaunched = FolderRegistryStore(defaults: defaults, usesICloud: false, cloud: cloud)
        #expect(relaunched.registry.entry("work")?.project?.notes == "who is who")
        #expect(cloud.reads == 0)
    }

    @Test func anInstallThatKeptItsRegistryInICloudAdoptsItOnce() {
        let cloud = FakeCloud()
        cloud.values[FolderRegistry.kvsKey] = folders("Work", notes: "terms").encoded()
        let defaults = scratch()
        let store = FolderRegistryStore(defaults: defaults, usesICloud: false, adoptsICloudCopy: true, cloud: cloud)
        #expect(store.registry.entry("work")?.project?.notes == "terms")
        #expect(cloud.writes == 0)
        #expect(!cloud.observing)

        // Once: what other devices write afterwards stays in iCloud.
        cloud.values[FolderRegistry.kvsKey] = folders("Work", "Later").encoded()
        let relaunched = FolderRegistryStore(defaults: defaults, usesICloud: false, adoptsICloudCopy: true, cloud: cloud)
        #expect(relaunched.registry.entry("later") == nil)
        #expect(cloud.reads == 1)
    }

    @Test func aNewInstallWithICloudOffAdoptsNothing() {
        let cloud = FakeCloud()
        cloud.values[FolderRegistry.kvsKey] = folders("Work").encoded()
        let store = FolderRegistryStore(defaults: scratch(), usesICloud: false, adoptsICloudCopy: false, cloud: cloud)
        #expect(store.registry.entries.isEmpty)
        #expect(cloud.reads == 0)
    }

    /// Later in its first launch a new install stops looking new. What
    /// it decided at the first one stands: nothing comes down.
    @Test func aNewInstallsNextLaunchStillAdoptsNothing() {
        let cloud = FakeCloud()
        cloud.values[FolderRegistry.kvsKey] = folders("Work").encoded()
        let defaults = scratch()
        _ = FolderRegistryStore(defaults: defaults, usesICloud: false, adoptsICloudCopy: false, cloud: cloud)
        let second = FolderRegistryStore(defaults: defaults, usesICloud: false, adoptsICloudCopy: true, cloud: cloud)
        #expect(second.registry.entries.isEmpty)
        #expect(cloud.reads == 0)
    }

    @Test func turningICloudOnMergesBothWaysAndFollowsFromThere() {
        let cloud = FakeCloud()
        cloud.values[FolderRegistry.kvsKey] = folders("Phone").encoded()
        let store = FolderRegistryStore(defaults: scratch(), usesICloud: false, cloud: cloud)
        store.update { $0.upsert(name: "Mac") }
        var told: [FolderRegistry] = []
        store.onExternalChange = { told.append($0) }

        store.setUsesICloud(true)
        #expect(store.registry.entry("phone") != nil)
        #expect(told.count == 1)
        let inCloud = cloud.values[FolderRegistry.kvsKey].flatMap(FolderRegistry.decode)
        #expect(inCloud?.entry("mac") != nil)
        #expect(inCloud?.entry("phone") != nil)
        #expect(cloud.observing)

        var remote = store.registry
        remote.upsert(name: "Later", at: Date())
        cloud.arrive(remote.encoded()!, forKey: FolderRegistry.kvsKey)
        #expect(store.registry.entry("later") != nil)
    }

    @Test func turningICloudOffStopsBothDirections() {
        let cloud = FakeCloud()
        let store = FolderRegistryStore(defaults: scratch(), usesICloud: true, cloud: cloud)
        store.update { $0.upsert(name: "Work") }
        #expect(cloud.writes == 1)

        store.setUsesICloud(false)
        #expect(!cloud.observing)
        let (reads, writes) = (cloud.reads, cloud.writes)
        store.update { $0.upsert(name: "Private") }
        store.pull()
        #expect(cloud.reads == reads)
        #expect(cloud.writes == writes)
        // What was sent before stays where it is.
        #expect(cloud.values[FolderRegistry.kvsKey].flatMap(FolderRegistry.decode)?.entry("private") == nil)
        #expect(cloud.values[FolderRegistry.kvsKey].flatMap(FolderRegistry.decode)?.entry("work") != nil)
    }

    @Test func withICloudOnTheFolderStoreKeepsADeviceCopyToo() {
        let cloud = FakeCloud()
        let defaults = scratch()
        let store = FolderRegistryStore(defaults: defaults, usesICloud: true, cloud: cloud)
        store.update { $0.upsert(name: "Work") }
        // Signed out of iCloud tomorrow: the list is still here.
        let offline = FolderRegistryStore(defaults: defaults, usesICloud: false, cloud: FakeCloud())
        #expect(offline.registry.entry("work") != nil)
    }

    // MARK: - «Delete my data from iCloud»

    /// The vocabulary only. The project list is not erased: builds
    /// before 16.11 keep it in the key-value store and nowhere else.
    @Test func erasingTakesTheVocabularyOutOfICloudAndKeepsTheDevices() {
        let cloud = FakeCloud()
        let defaults = scratch()
        let words = VocabularyRegistryStore(defaults: defaults, usesICloud: true, cloud: cloud)
        words.update { $0.append(DictationReplacement(kind: .term, to: "Daisy")) }
        words.setUsesICloud(false)

        words.eraseICloudCopy()
        #expect(cloud.values[VocabularyRegistry.kvsKey] == nil)
        #expect(words.registry.rules.map(\.to) == ["Daisy"])
        #expect(VocabularyRegistryStore(defaults: defaults, usesICloud: false, cloud: cloud).registry.rules.map(\.to) == ["Daisy"])
    }

    /// With iCloud on the next change would send it straight back.
    @Test func erasingDoesNothingWhileICloudIsOn() {
        let cloud = FakeCloud()
        let words = VocabularyRegistryStore(defaults: scratch(), usesICloud: true, cloud: cloud)
        words.update { $0.append(DictationReplacement(kind: .term, to: "Daisy")) }
        words.eraseICloudCopy()
        #expect(cloud.values[VocabularyRegistry.kvsKey] != nil)
    }

    /// The other device, still on iCloud, keeps its words when the value
    /// disappears — the vocabulary store has had a device copy since
    /// 24.09 — and sends them again with its next change.
    @Test func aDeviceStillOnICloudKeepsItsWordsWhenTheValueIsErasedElsewhere() {
        let cloud = FakeCloud()
        let defaults = scratch()
        let phone = VocabularyRegistryStore(defaults: defaults, usesICloud: true, cloud: cloud)
        phone.update { $0.append(DictationReplacement(kind: .term, to: "Daisy")) }
        cloud.removeValue(forKey: VocabularyRegistry.kvsKey)
        phone.pull()
        #expect(phone.registry.rules.map(\.to) == ["Daisy"])
        #expect(VocabularyRegistryStore(defaults: defaults, usesICloud: true, cloud: cloud).registry.rules.map(\.to) == ["Daisy"])
        phone.update { $0.append(DictationReplacement(kind: .term, to: "Later")) }
        #expect(cloud.values[VocabularyRegistry.kvsKey].flatMap(VocabularyRegistry.decode)?.rules.map(\.to) == ["Daisy", "Later"])
    }

    // MARK: - Vocabulary

    @Test func withICloudOffTheVocabularyStoreNeverTouchesIt() {
        let cloud = FakeCloud()
        var elsewhere = VocabularyRegistry()
        elsewhere.append(DictationReplacement(kind: .term, to: "Elsewhere"), at: t0)
        cloud.values[VocabularyRegistry.kvsKey] = elsewhere.encoded()
        let defaults = scratch()
        let store = VocabularyRegistryStore(defaults: defaults, usesICloud: false, cloud: cloud)
        store.update { $0.append(DictationReplacement(kind: .term, to: "Daisy")) }
        store.pull()
        #expect(cloud.reads == 0)
        #expect(cloud.writes == 0)
        #expect(!cloud.observing)
        #expect(store.registry.rules.map(\.to) == ["Daisy"])
        #expect(VocabularyRegistryStore(defaults: defaults, usesICloud: false, cloud: cloud).registry.rules.map(\.to) == ["Daisy"])
    }

    @Test func turningICloudOnSendsTheVocabularyEvenWhenNothingCameDown() {
        let cloud = FakeCloud()
        let store = VocabularyRegistryStore(defaults: scratch(), usesICloud: false, cloud: cloud)
        store.update { $0.append(DictationReplacement(kind: .term, to: "Daisy")) }
        store.setUsesICloud(true)
        #expect(cloud.values[VocabularyRegistry.kvsKey].flatMap(VocabularyRegistry.decode)?.rules.map(\.to) == ["Daisy"])
        #expect(cloud.observing)

        store.setUsesICloud(false)
        let writes = cloud.writes
        store.update { $0.append(DictationReplacement(kind: .term, to: "Later")) }
        #expect(cloud.writes == writes)
    }
}
