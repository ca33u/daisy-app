//
//  KeychainStoreTests.swift
//  DaisyCoreTests
//
//  Pure logic only. `KeychainStore.set/get` always ask for a
//  synchronizable item (backlog B-6, that's the whole point), and
//  `kSecAttrSynchronizable` needs a real keychain-access-groups
//  entitlement from a signed process to work at all (confirmed:
//  errSecMissingEntitlement / -34018 from a bare `swift test` binary,
//  which isn't signed with one). The actual read/write round trip is
//  tested where it can genuinely run signed — DaisyLiteTests, hosted
//  inside the real (simulator-signed) app — see
//  DaisyLiteTests/KeychainStoreAppTests.swift.
//

import Testing
import Foundation
@testable import DaisyCore

@Suite("KeychainStore")
struct KeychainStoreTests {
    @Test func summaryProviderKeysCoverTheFourMacAccounts() {
        let accounts = Set(SecretKey.summaryProviderKeys.map(\.account))
        #expect(accounts == [
            SecretKey.anthropicAPIKey, SecretKey.openaiAPIKey,
            SecretKey.cursorAPIKey, SecretKey.kimiAPIKey,
        ])
        #expect(KeychainStore.accessGroup == "app.essazanov.Daisy.shared")
    }
}
