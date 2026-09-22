//
//  KeychainLaunchTests.swift
//  DaisyTests
//
//  backlog 10, after Egor's 2 m 41 s launch: the eager keychain
//  migration must never run at launch. Reading a legacy item whose ACL
//  does not list this binary asks the person modally, and eight of
//  those before the first window is an app that looks hung.
//
//  The test reads the source, because that is where the rule lives: no
//  runtime assertion can prove "this was not called during init".
//

import Testing
import Foundation

@Suite("Keychain migration never blocks launch")
struct KeychainLaunchTests {
    private func source(_ name: String) throws -> String {
        // The test bundle sits in Build/Products; the sources are three
        // levels above the repo's build directory. Walk up to the repo.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Daisy/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test func daisyAppInitDoesNotMigrateKeys() throws {
        let app = try source("DaisyApp.swift")
        let calls = app.components(separatedBy: "\n").filter {
            $0.contains("KeychainStore.migrateLegacyItems()") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        #expect(calls.isEmpty, "The eager keychain migration is back in DaisyApp — it blocks launch with a system dialog.")
    }

    /// The other half of the same rule: constructing AppSettings must
    /// not read the legacy keychain either — six more dialogs, same
    /// blocked launch.
    @Test func appSettingsInitNeverReadsTheLegacyKeychain() throws {
        let settings = try source("AppSettings.swift")
        let lines = settings.components(separatedBy: "\n")
        let initStart = try #require(lines.firstIndex { $0.contains("self.notionToken =") })
        let initEnd = try #require(lines[initStart...].firstIndex { $0.contains("self.kimiAPIKey =") })
        let launchReads = lines[initStart...initEnd].filter { $0.contains("KeychainStore.get(") }
        #expect(launchReads.isEmpty, "AppSettings.init reads the legacy keychain again — that blocks launch with a system dialog.")
        #expect(lines[initStart...initEnd].allSatisfy { !$0.contains("KeychainStore") || $0.contains("getWithoutPrompting") })
        // And the deferred pass exists.
        #expect(settings.contains("func loadSecretsFromLegacyKeychain()"))
        #expect(settings.contains("Task.detached"))
    }

    @Test func theOnlyCallerIsSyncAndItIsOffTheMainThread() throws {
        let coordinator = try source("SyncCoordinator.swift")
        #expect(coordinator.contains("KeychainStore.migrateLegacyItems()"))
        // The call sits inside a detached task, not on the main actor.
        let lines = coordinator.components(separatedBy: "\n")
        let index = try #require(lines.firstIndex { $0.contains("KeychainStore.migrateLegacyItems()") })
        let preceding = lines[max(0, index - 3)..<index].joined(separator: " ")
        #expect(preceding.contains("Task.detached"), "The migration must run off the main thread.")
    }
}
