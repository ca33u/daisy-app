import Foundation
import Testing
@testable import Daisy

/// Sentry 156682704 (27.10): a build of the public repo, signed without
/// Daisy's iCloud container, died at launch — CloudKit traps on
/// `CKContainer(identifier:)` for a container the signature doesn't list,
/// and the sync transport was built the moment `SyncCoordinator.shared`
/// was first touched, sync on or off.
@Suite("Sync without the iCloud entitlement")
struct SyncEntitlementTests {
    let container = "iCloud.app.essazanov.Daisy"

    @Test("Only a signature listing Daisy's container counts")
    func entitles() {
        #expect(SyncCoordinator.entitles([container], container: container))
        #expect(SyncCoordinator.entitles(["iCloud.other", container], container: container))
        #expect(!SyncCoordinator.entitles(nil, container: container))
        #expect(!SyncCoordinator.entitles([String](), container: container))
        #expect(!SyncCoordinator.entitles(["iCloud.other"], container: container))
        #expect(!SyncCoordinator.entitles("iCloud.app.essazanov.Daisy", container: container))
    }

    @Test("The refusal is said in both languages")
    func message() throws {
        let key = "This copy of Daisy isn’t signed for iCloud, so sync can’t run. The release from mydaisy.io can."
        #expect(SyncCoordinator.unavailableMessage == key)
        let ru = try #require(Bundle.main.path(forResource: "ru", ofType: "lproj").flatMap(Bundle.init(path:)))
        let value = ru.localizedString(forKey: key, value: "∅", table: nil)
        #expect(value != "∅" && value.contains("iCloud"))
    }

    /// The test host is entitled, so the trap itself can't be reproduced
    /// here; the structure that prevents it is pinned instead: the
    /// transport is built only lazily, read only in `engine(for:)`, and
    /// every caller of `engine(for:)` checks the entitlement first.
    @Test("The transport is built only behind the entitlement check")
    func structure() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Daisy/SyncCoordinator.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("private lazy var transport = CloudKitSyncTransport("))
        #expect(!source.contains("private let transport"))
        let transportReads = source.components(separatedBy: "transport: transport").count - 1
        #expect(transportReads == 1)
        // Each function that reaches `engine(for:)` guards first.
        for name in ["func syncNow()", "func eraseCloudData()", "func markDeleted("] {
            let body = try #require(source.components(separatedBy: name).dropFirst().first)
            let beforeEngine = try #require(body.components(separatedBy: "engine(for:").first)
            #expect(beforeEngine.contains("cloudKitAvailable"), "\(name) must check the entitlement before engine(for:)")
        }
    }
}
