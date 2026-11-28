// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  SecretVaultTests.swift
//  DaisyTests
//
//  16.11: keys and tokens go to iCloud Keychain only with sync on. Until
//  1.0.8.52 every one was a synchronizable item from the moment it was
//  saved, while Settings said nothing left the Mac. The rules live in
//  `SecretVault`; the keychain here is a stand-in, since the real one
//  needs the signed app (and is the person's own).
//

import Foundation
import Security
import Testing
@testable import Daisy

private final class FakeKeychain: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [KeychainPlace: [String: String]] = [:]
    /// Statuses to answer the next writes to a place with, in order.
    private var writeFailures: [KeychainPlace: [OSStatus]] = [:]
    private var listFailures: [KeychainPlace: [OSStatus]] = [:]
    private var touched: Set<KeychainPlace> = []

    func put(_ value: String, account: String, in place: KeychainPlace) {
        lock.withLock { items[place, default: [:]][account] = value }
    }

    func value(_ account: String, in place: KeychainPlace) -> String? {
        lock.withLock { items[place]?[account] }
    }

    func failNextWrite(in place: KeychainPlace, with status: OSStatus) {
        lock.withLock { writeFailures[place, default: []].append(status) }
    }

    func failNextList(in place: KeychainPlace, with status: OSStatus) {
        lock.withLock { listFailures[place, default: []].append(status) }
    }

    func drop(_ account: String, in place: KeychainPlace) {
        lock.withLock { _ = items[place]?.removeValue(forKey: account) }
    }

    /// Whether the vault read, wrote, deleted or listed there at all.
    func wasTouched(_ place: KeychainPlace) -> Bool {
        lock.withLock { touched.contains(place) }
    }

    func read(account: String, in place: KeychainPlace) -> (value: String?, status: OSStatus) {
        lock.withLock {
            touched.insert(place)
            guard let value = items[place]?[account] else { return (nil, errSecItemNotFound) }
            return (value, errSecSuccess)
        }
    }

    func write(_ value: String, account: String, in place: KeychainPlace) -> OSStatus {
        lock.withLock {
            touched.insert(place)
            if var failures = writeFailures[place], !failures.isEmpty {
                let status = failures.removeFirst()
                writeFailures[place] = failures
                return status
            }
            items[place, default: [:]][account] = value
            return errSecSuccess
        }
    }

    func delete(account: String, in place: KeychainPlace) -> OSStatus {
        lock.withLock {
            touched.insert(place)
            return items[place]?.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    func accounts(in place: KeychainPlace) -> (accounts: [String], status: OSStatus) {
        lock.withLock {
            touched.insert(place)
            if var failures = listFailures[place], !failures.isEmpty {
                let status = failures.removeFirst()
                listFailures[place] = failures
                return ([], status)
            }
            let accounts = (items[place] ?? [:]).keys.sorted()
            return (accounts, accounts.isEmpty ? errSecItemNotFound : errSecSuccess)
        }
    }
}

/// The sync switch, as a test flips it.
private final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool
    init(_ on: Bool) { self.on = on }
    var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

@Suite("Keys and tokens reach iCloud Keychain only with sync on")
struct SecretVaultTests {
    private let scratch = ScratchDefaults("secret-vault")
    private let key = "anthropic.api_key"

    private func vault(_ keychain: FakeKeychain, sync: Switch, existingInstall: Bool = true,
                       defaults: UserDefaults?) -> SecretVault {
        SecretVault(backend: keychain, iCloudOn: { sync.isOn }, isExistingInstall: { existingInstall }, defaults: defaults)
    }

    // MARK: - Where a secret goes

    @Test func withSyncOffAKeyStaysOnThisMac() throws {
        let keychain = FakeKeychain()
        let vault = vault(keychain, sync: Switch(false), existingInstall: false, defaults: scratch.make())
        try vault.set("sk-1", account: key)
        #expect(keychain.value(key, in: .thisMac) == "sk-1")
        #expect(keychain.value(key, in: .iCloud) == nil)
        #expect(vault.get(account: key) == "sk-1")
        #expect(vault.getWithoutPrompting(account: key) == "sk-1")
    }

    @Test func withSyncOnAKeyGoesToICloudAndOnlyThere() throws {
        let keychain = FakeKeychain()
        keychain.put("old", account: key, in: .thisMac)
        let vault = vault(keychain, sync: Switch(true), defaults: scratch.make())
        try vault.set("sk-2", account: key)
        #expect(keychain.value(key, in: .iCloud) == "sk-2")
        #expect(keychain.value(key, in: .thisMac) == nil)
        #expect(vault.get(account: key) == "sk-2")
    }

    // MARK: - A new install

    /// The case that mattered most: a key typed on another Mac arrives
    /// through iCloud Keychain, and a cloud provider must not come alive
    /// here with nobody having asked.
    @Test func aNewInstallWithSyncOffTakesNothingFromICloud() {
        let keychain = FakeKeychain()
        keychain.put("from-another-mac", account: key, in: .iCloud)
        let defaults = scratch.make()
        let vault = vault(keychain, sync: Switch(false), existingInstall: false, defaults: defaults)
        #expect(vault.getWithoutPrompting(account: key) == nil)
        #expect(vault.get(account: key) == nil)
        #expect(keychain.value(key, in: .thisMac) == nil)
        #expect(!keychain.wasTouched(.iCloud))
        #expect(defaults.bool(forKey: SecretVault.adoptedKey))
    }

    /// Later in that first launch the install stops looking new (the
    /// build is recorded, the tour ends). What it decided stands.
    @Test func aNewInstallsNextLaunchStillTakesNothing() {
        let keychain = FakeKeychain()
        keychain.put("from-another-mac", account: key, in: .iCloud)
        let defaults = scratch.make()
        let first = vault(keychain, sync: Switch(false), existingInstall: false, defaults: defaults)
        #expect(first.getWithoutPrompting(account: key) == nil)
        let second = vault(keychain, sync: Switch(false), existingInstall: true, defaults: defaults)
        #expect(second.getWithoutPrompting(account: key) == nil)
        #expect(second.get(account: key) == nil)
        #expect(!keychain.wasTouched(.iCloud))
    }

    // MARK: - An install that updates

    @Test func anUpdateWithSyncOffKeepsItsKeysAndLeavesICloudAlone() {
        let keychain = FakeKeychain()
        keychain.put("sk-mine", account: key, in: .iCloud)
        keychain.put("secret_notion", account: "notion.token", in: .iCloud)
        let defaults = scratch.make()
        let first = vault(keychain, sync: Switch(false), defaults: defaults)
        // The launch path, which never reaches the legacy keychain.
        #expect(first.getWithoutPrompting(account: key) == "sk-mine")
        #expect(first.getWithoutPrompting(account: "notion.token") == "secret_notion")
        #expect(keychain.value(key, in: .thisMac) == "sk-mine")
        // Deleting a synchronizable item deletes it on every device.
        #expect(keychain.value(key, in: .iCloud) == "sk-mine")
        #expect(defaults.bool(forKey: SecretVault.adoptedKey))

        // Once: what another device puts there later is not taken.
        keychain.put("later", account: "openai.api_key", in: .iCloud)
        let relaunched = vault(keychain, sync: Switch(false), defaults: defaults)
        #expect(relaunched.get(account: "openai.api_key") == nil)
        #expect(relaunched.get(account: key) == "sk-mine")
    }

    @Test func theCopyIsRetriedUntilEveryItemMadeIt() {
        let keychain = FakeKeychain()
        keychain.put("sk-mine", account: key, in: .iCloud)
        keychain.failNextWrite(in: .thisMac, with: errSecInteractionNotAllowed)
        let defaults = scratch.make()
        let first = vault(keychain, sync: Switch(false), defaults: defaults)
        #expect(first.getWithoutPrompting(account: key) == nil)
        #expect(!defaults.bool(forKey: SecretVault.adoptedKey))

        let relaunched = vault(keychain, sync: Switch(false), defaults: defaults)
        #expect(relaunched.getWithoutPrompting(account: key) == "sk-mine")
        #expect(defaults.bool(forKey: SecretVault.adoptedKey))
    }

    @Test func aListingThatFailsIsNotTakenForNothingToCopy() {
        let keychain = FakeKeychain()
        keychain.put("sk-mine", account: key, in: .iCloud)
        keychain.failNextList(in: .iCloud, with: errSecInteractionNotAllowed)
        let defaults = scratch.make()
        let first = vault(keychain, sync: Switch(false), defaults: defaults)
        #expect(first.getWithoutPrompting(account: key) == nil)
        #expect(!defaults.bool(forKey: SecretVault.adoptedKey))
        #expect(vault(keychain, sync: Switch(false), defaults: defaults).getWithoutPrompting(account: key) == "sk-mine")
    }

    @Test func aKeyChangedHereAfterTheUpdateIsNotOverwrittenByTheCopy() throws {
        let keychain = FakeKeychain()
        keychain.put("old", account: key, in: .iCloud)
        keychain.put("typed-here", account: key, in: .thisMac)
        let vault = vault(keychain, sync: Switch(false), defaults: scratch.make())
        #expect(vault.get(account: key) == "typed-here")
        try vault.set("newer", account: key)
        #expect(keychain.value(key, in: .iCloud) == "old")
    }

    @Test func aVaultWithoutDefaultsNeverCopies() {
        let keychain = FakeKeychain()
        keychain.put("sk-mine", account: key, in: .iCloud)
        let vault = vault(keychain, sync: Switch(false), defaults: nil)
        #expect(vault.getWithoutPrompting(account: key) == nil)
        #expect(keychain.value(key, in: .thisMac) == nil)
        #expect(!keychain.wasTouched(.iCloud))
    }

    // MARK: - The switch

    @Test func turningSyncOnSendsWhatWasSavedHereAndItWins() throws {
        let keychain = FakeKeychain()
        keychain.put("stale", account: key, in: .iCloud)
        keychain.put("from-the-phone", account: "openai.api_key", in: .iCloud)
        let sync = Switch(false)
        let defaults = scratch.make()
        let vault = vault(keychain, sync: sync, existingInstall: false, defaults: defaults)
        try vault.set("typed-here", account: key)
        #expect(defaults.stringArray(forKey: SecretVault.changedHereKey) == [key])

        sync.isOn = true
        vault.iCloudSwitchChanged(to: true)
        #expect(keychain.value(key, in: .iCloud) == "typed-here")
        #expect(keychain.value(key, in: .thisMac) == nil)
        #expect(vault.get(account: key) == "typed-here")
        #expect(defaults.stringArray(forKey: SecretVault.changedHereKey) == [])
        // And what other devices keep there is readable from now.
        #expect(vault.get(account: "openai.api_key") == "from-the-phone")
    }

    /// The copy an update took is a snapshot. A key rotated on another
    /// Mac since must not be put back by this one.
    @Test func turningSyncOnACopyTakenFromICloudGivesWayToWhatICloudHasNow() {
        let keychain = FakeKeychain()
        keychain.put("K1", account: key, in: .iCloud)
        let sync = Switch(false)
        let vault = vault(keychain, sync: sync, defaults: scratch.make())
        #expect(vault.getWithoutPrompting(account: key) == "K1")
        keychain.put("K2", account: key, in: .iCloud)          // rotated elsewhere

        sync.isOn = true
        vault.iCloudSwitchChanged(to: true)
        #expect(keychain.value(key, in: .iCloud) == "K2")
        #expect(keychain.value(key, in: .thisMac) == nil)
        #expect(vault.get(account: key) == "K2")
    }

    /// iCloud Keychain switched off in macOS takes the synchronizable
    /// items with it; the copy here is then the only one.
    @Test func turningSyncOnNeverDropsTheLastCopy() {
        let keychain = FakeKeychain()
        keychain.put("K1", account: key, in: .iCloud)
        let sync = Switch(false)
        let vault = vault(keychain, sync: sync, defaults: scratch.make())
        #expect(vault.getWithoutPrompting(account: key) == "K1")
        keychain.drop(key, in: .iCloud)

        sync.isOn = true
        vault.iCloudSwitchChanged(to: true)
        #expect(keychain.value(key, in: .iCloud) == "K1")
        #expect(vault.get(account: key) == "K1")
    }

    @Test func aLegacyKeyCopiedForwardWithSyncOffGoesUpWhenItTurnsOn() {
        let keychain = FakeKeychain()
        keychain.put("legacy", account: key, in: .legacy)
        let sync = Switch(false)
        let vault = vault(keychain, sync: sync, defaults: scratch.make())
        #expect(vault.get(account: key) == "legacy")
        sync.isOn = true
        vault.iCloudSwitchChanged(to: true)
        #expect(keychain.value(key, in: .iCloud) == "legacy")
    }

    /// The legacy keychain stopped being written the day the keychains
    /// were switched: its value is never newer than iCloud's.
    @Test func aLegacyKeyCopiedForwardDoesNotWinOverICloud() {
        let keychain = FakeKeychain()
        keychain.put("old", account: key, in: .legacy)
        keychain.put("rotated", account: key, in: .iCloud)
        let sync = Switch(false)
        let defaults = scratch.make()
        // A Mac that reads as new, so the iCloud value was not taken.
        let vault = vault(keychain, sync: sync, existingInstall: false, defaults: defaults)
        #expect(vault.get(account: key) == "old")
        #expect(defaults.stringArray(forKey: SecretVault.changedHereKey) ?? [] == [])
        sync.isOn = true
        vault.iCloudSwitchChanged(to: true)
        #expect(keychain.value(key, in: .iCloud) == "rotated")
        #expect(vault.get(account: key) == "rotated")
    }

    /// Some callers write every token again on any save.
    @Test func savingTheSameValueAgainDoesNotMakeACopyThisMacsOwn() throws {
        let keychain = FakeKeychain()
        keychain.put("K1", account: key, in: .iCloud)
        let sync = Switch(false)
        let defaults = scratch.make()
        let vault = vault(keychain, sync: sync, defaults: defaults)
        #expect(vault.getWithoutPrompting(account: key) == "K1")
        try vault.set("K1", account: key)
        #expect(defaults.stringArray(forKey: SecretVault.changedHereKey) ?? [] == [])
        keychain.put("K2", account: key, in: .iCloud)
        sync.isOn = true
        vault.iCloudSwitchChanged(to: true)
        #expect(vault.get(account: key) == "K2")
    }

    /// The move failed for a key saved here; it is still the latest.
    @Test func aKeySavedHereIsNotShadowedByICloudAfterAFailedMove() throws {
        let keychain = FakeKeychain()
        keychain.put("K1", account: key, in: .iCloud)
        let sync = Switch(false)
        let vault = vault(keychain, sync: sync, existingInstall: false, defaults: scratch.make())
        try vault.set("K2", account: key)
        keychain.failNextWrite(in: .iCloud, with: errSecInteractionNotAllowed)
        sync.isOn = true
        vault.iCloudSwitchChanged(to: true)
        #expect(keychain.value(key, in: .iCloud) == "K1")
        #expect(vault.get(account: key) == "K2")
        #expect(keychain.value(key, in: .iCloud) == "K2")
        #expect(keychain.value(key, in: .thisMac) == nil)
    }

    @Test func turningSyncOffCopiesBackAndDeletesNothingInICloud() throws {
        let keychain = FakeKeychain()
        let sync = Switch(true)
        let defaults = scratch.make()
        let vault = vault(keychain, sync: sync, defaults: defaults)
        try vault.set("sk-3", account: key)

        sync.isOn = false
        vault.iCloudSwitchChanged(to: false)
        #expect(keychain.value(key, in: .thisMac) == "sk-3")
        #expect(keychain.value(key, in: .iCloud) == "sk-3")
        #expect(vault.get(account: key) == "sk-3")
        #expect(defaults.bool(forKey: SecretVault.adoptedKey))

        // From here a change stays on this Mac.
        try vault.set("sk-4", account: key)
        #expect(keychain.value(key, in: .iCloud) == "sk-3")
    }

    @Test func turningSyncOffKeepsWhatThisMacAlreadyHolds() {
        let keychain = FakeKeychain()
        keychain.put("in-icloud", account: key, in: .iCloud)
        keychain.put("held-here", account: key, in: .thisMac)   // a move that failed earlier
        let sync = Switch(true)
        let vault = vault(keychain, sync: sync, defaults: scratch.make())
        sync.isOn = false
        vault.iCloudSwitchChanged(to: false)
        #expect(keychain.value(key, in: .thisMac) == "held-here")
    }

    @Test func withSyncOnAKeyTheMoveLeftBehindIsCarriedOnTheNextRead() {
        let keychain = FakeKeychain()
        keychain.put("left-behind", account: key, in: .thisMac)
        let vault = vault(keychain, sync: Switch(true), defaults: scratch.make())
        #expect(vault.getWithoutPrompting(account: key) == "left-behind")
        #expect(keychain.value(key, in: .iCloud) == "left-behind")
        #expect(keychain.value(key, in: .thisMac) == nil)
    }

    // MARK: - «Delete my data from iCloud»

    @Test func erasingTakesEveryKeyOutOfICloudAndKeepsThisMacs() throws {
        let keychain = FakeKeychain()
        keychain.put("sk-mine", account: key, in: .iCloud)
        keychain.put("secret_notion", account: "notion.token", in: .iCloud)
        let vault = vault(keychain, sync: Switch(false), defaults: scratch.make())
        #expect(vault.getWithoutPrompting(account: key) == "sk-mine")       // the update's copy

        #expect(vault.eraseICloudItems())
        #expect(keychain.value(key, in: .iCloud) == nil)
        #expect(keychain.value("notion.token", in: .iCloud) == nil)
        #expect(vault.get(account: key) == "sk-mine")
        #expect(vault.get(account: "notion.token") == "secret_notion")
    }

    /// What arrived from another device after the update was never this
    /// Mac's: it leaves iCloud without being taken here on the way.
    @Test func erasingDoesNotTakeWhatThisMacNeverHad() {
        let keychain = FakeKeychain()
        keychain.put("another-macs", account: key, in: .iCloud)
        let vault = vault(keychain, sync: Switch(false), existingInstall: false, defaults: scratch.make())
        #expect(vault.getWithoutPrompting(account: key) == nil)
        #expect(vault.eraseICloudItems())
        #expect(keychain.value(key, in: .iCloud) == nil)
        #expect(keychain.value(key, in: .thisMac) == nil)
    }

    /// An update whose one-time copy never finished would lose keys it
    /// has always had: the copy comes first, or nothing is deleted.
    @Test func erasingFinishesTheUpdatesCopyFirstOrDeletesNothing() {
        let keychain = FakeKeychain()
        keychain.put("sk-mine", account: key, in: .iCloud)
        keychain.failNextWrite(in: .thisMac, with: errSecInteractionNotAllowed)   // at launch
        keychain.failNextWrite(in: .thisMac, with: errSecInteractionNotAllowed)   // at the button
        let defaults = scratch.make()
        let vault = vault(keychain, sync: Switch(false), defaults: defaults)
        #expect(vault.getWithoutPrompting(account: key) == nil)

        #expect(!vault.eraseICloudItems())
        #expect(keychain.value(key, in: .iCloud) == "sk-mine")

        #expect(vault.eraseICloudItems())
        #expect(keychain.value(key, in: .iCloud) == nil)
        #expect(keychain.value(key, in: .thisMac) == "sk-mine")
        #expect(defaults.bool(forKey: SecretVault.adoptedKey))
    }

    /// Sync was on, so the keys moved to iCloud; turned off, one copy
    /// back failed. This Mac must not be told it has everything: the
    /// button would delete the only copy, on every device.
    @Test func erasingAfterACopyBackThatFailedDeletesNothingUntilItIsWhole() throws {
        let keychain = FakeKeychain()
        keychain.put("sk-mine", account: key, in: .iCloud)
        let sync = Switch(false)
        let defaults = scratch.make()
        let vault = vault(keychain, sync: sync, defaults: defaults)
        #expect(vault.getWithoutPrompting(account: key) == "sk-mine")
        #expect(defaults.bool(forKey: SecretVault.adoptedKey))

        sync.isOn = true
        vault.iCloudSwitchChanged(to: true)
        #expect(!defaults.bool(forKey: SecretVault.adoptedKey))
        #expect(keychain.value(key, in: .thisMac) == nil)

        keychain.failNextWrite(in: .thisMac, with: errSecInteractionNotAllowed)
        sync.isOn = false
        vault.iCloudSwitchChanged(to: false)
        #expect(!defaults.bool(forKey: SecretVault.adoptedKey))

        keychain.failNextWrite(in: .thisMac, with: errSecInteractionNotAllowed)
        #expect(!vault.eraseICloudItems())
        #expect(keychain.value(key, in: .iCloud) == "sk-mine")

        // The next launch finishes the copy; then the button may delete.
        let relaunched = self.vault(keychain, sync: sync, defaults: defaults)
        #expect(relaunched.getWithoutPrompting(account: key) == "sk-mine")
        #expect(relaunched.eraseICloudItems())
        #expect(keychain.value(key, in: .iCloud) == nil)
        #expect(relaunched.get(account: key) == "sk-mine")
    }

    @Test func erasingAListingThatFailsDeletesNothing() {
        let keychain = FakeKeychain()
        keychain.put("another-macs", account: key, in: .iCloud)
        let vault = vault(keychain, sync: Switch(false), existingInstall: false, defaults: scratch.make())
        keychain.failNextList(in: .iCloud, with: errSecInteractionNotAllowed)
        #expect(!vault.eraseICloudItems())
        #expect(keychain.value(key, in: .iCloud) == "another-macs")
    }

    /// With sync on iCloud is the only place the keys are.
    @Test func erasingDeletesNoKeyWhileSyncIsOn() throws {
        let keychain = FakeKeychain()
        let vault = vault(keychain, sync: Switch(true), defaults: scratch.make())
        try vault.set("sk-1", account: key)
        #expect(vault.eraseICloudItems())
        #expect(keychain.value(key, in: .iCloud) == "sk-1")
    }

    @Test func afterErasingTurningSyncOnSendsThisMacsKeysUpAgain() {
        let keychain = FakeKeychain()
        keychain.put("sk-mine", account: key, in: .iCloud)
        let sync = Switch(false)
        let vault = vault(keychain, sync: sync, defaults: scratch.make())
        #expect(vault.getWithoutPrompting(account: key) == "sk-mine")
        #expect(vault.eraseICloudItems())
        sync.isOn = true
        vault.iCloudSwitchChanged(to: true)
        #expect(keychain.value(key, in: .iCloud) == "sk-mine")
        #expect(vault.get(account: key) == "sk-mine")
    }

    // MARK: - Remove, and the two older paths

    @Test(arguments: [true, false])
    func removeDeletesEverywhere(syncOn: Bool) {
        let keychain = FakeKeychain()
        for place in [KeychainPlace.iCloud, .thisMac, .legacy] { keychain.put("x", account: key, in: place) }
        let vault = vault(keychain, sync: Switch(syncOn), defaults: scratch.make())
        #expect(vault.remove(account: key))
        for place in [KeychainPlace.iCloud, .thisMac, .legacy] { #expect(keychain.value(key, in: place) == nil) }
        #expect(vault.get(account: key) == nil)
    }

    /// Several callers remove «what is not set here» while saving. On a
    /// Mac that never took the iCloud copy, that must not wipe the key
    /// another device still uses.
    @Test func withSyncOffRemovingWhatThisMacNeverHadLeavesICloudAlone() {
        let keychain = FakeKeychain()
        keychain.put("another-macs", account: key, in: .iCloud)
        let vault = vault(keychain, sync: Switch(false), existingInstall: false, defaults: scratch.make())
        #expect(vault.remove(account: key))
        #expect(keychain.value(key, in: .iCloud) == "another-macs")
        #expect(!keychain.wasTouched(.iCloud))
    }

    /// «A key leaves iCloud Keychain when you remove it in Daisy»: a
    /// cleared field is a removal, not an empty copy on this Mac.
    @Test func clearingAFieldRemovesTheKeyFromICloudToo() throws {
        let keychain = FakeKeychain()
        keychain.put("sk-mine", account: key, in: .iCloud)
        let defaults = scratch.make()
        let vault = vault(keychain, sync: Switch(false), defaults: defaults)
        #expect(vault.getWithoutPrompting(account: key) == "sk-mine")

        try vault.save("  \n", account: key)
        #expect(keychain.value(key, in: .thisMac) == nil)
        #expect(keychain.value(key, in: .iCloud) == nil)
        #expect(vault.get(account: key) == nil)
        #expect(defaults.stringArray(forKey: SecretVault.changedHereKey) ?? [] == [])
    }

    @Test func aPastedKeyIsSavedTrimmed() throws {
        let keychain = FakeKeychain()
        let vault = vault(keychain, sync: Switch(false), existingInstall: false, defaults: scratch.make())
        try vault.save(" sk-6\n", account: key)
        #expect(keychain.value(key, in: .thisMac) == "sk-6")
    }

    @Test(arguments: [true, false])
    func aLegacyKeyIsCopiedForwardToTheSwitchsPlace(syncOn: Bool) {
        let keychain = FakeKeychain()
        keychain.put("legacy", account: key, in: .legacy)
        let vault = vault(keychain, sync: Switch(syncOn), defaults: scratch.make())
        #expect(vault.getWithoutPrompting(account: key) == nil)       // never the legacy keychain at launch
        #expect(vault.get(account: key) == "legacy")
        #expect(keychain.value(key, in: syncOn ? .iCloud : .thisMac) == "legacy")
        #expect(keychain.value(key, in: syncOn ? .thisMac : .iCloud) == nil)
        #expect(keychain.value(key, in: .legacy) == "legacy")         // left for an older Daisy
    }

    @Test func theEagerLegacyPassFollowsTheSwitchToo() {
        let keychain = FakeKeychain()
        keychain.put("legacy", account: key, in: .legacy)
        let vault = vault(keychain, sync: Switch(false), defaults: scratch.make())
        vault.migrateLegacyItems([key])
        #expect(keychain.value(key, in: .thisMac) == "legacy")
        #expect(keychain.value(key, in: .iCloud) == nil)
    }

    @Test func aBuildWithoutTheEntitlementFallsBackToTheLegacyKeychain() throws {
        let keychain = FakeKeychain()
        keychain.failNextWrite(in: .thisMac, with: errSecMissingEntitlement)
        let vault = vault(keychain, sync: Switch(false), existingInstall: false, defaults: scratch.make())
        try vault.set("sk-5", account: key)
        #expect(!vault.dataProtectionAvailable)
        #expect(keychain.value(key, in: .legacy) == "sk-5")
        #expect(vault.get(account: key) == "sk-5")
        #expect(vault.getWithoutPrompting(account: key) == nil)
    }
}

/// The other two paths the switch holds back are wired at launch; the
/// rule is in the source, the way `KeychainLaunchTests` reads it.
@Suite("Nothing reaches iCloud or the network at launch with sync off")
struct ICloudSwitchLaunchTests {
    private func source(_ name: String) throws -> String {
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

    private func code(_ source: String) -> [String] {
        source.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    @Test func theDelegateDoesNotStartTheListenerByItself() throws {
        let delegate = code(try source("DaisyAppDelegate.swift"))
        #expect(!delegate.contains { $0.contains("AudioHandoffServer.shared.start()") },
                "The Mac announces itself on the local network again with sync off.")
        #expect(delegate.contains { $0.contains("AudioHandoffServer.shared.launch()") })
    }

    /// The whole test run shares the app's one vault, and the app is its
    /// own test host: the keychain behind it must not be the person's.
    @Test func theTestHostsKeychainIsInMemory() throws {
        let store = code(try source("KeychainStore.swift"))
        // Required, not expected: the round trip below must not run
        // against the real keychain.
        try #require(store.contains { $0.contains("backend: TestHost.isActive ? InMemoryKeychain() : SystemKeychain()") })
        try #require(TestHost.isActive)
        let account = "daisy.tests.vault.\(UUID().uuidString)"
        try KeychainStore.set("x", account: account)
        #expect(KeychainStore.get(account: account) == "x")
        #expect(KeychainStore.remove(account: account))
    }

    @Test func aClearedSettingsFieldGoesThroughSave() throws {
        let settings = code(try source("AppSettings.swift"))
        #expect(settings.contains { $0.contains("try KeychainStore.save(value, account: account)") })
    }

    @Test func bothRegistriesAskTheSwitch() throws {
        #expect(code(try source("FolderRegistryBridge.swift")).contains { $0.contains("FolderRegistryStore(usesICloud: ICloudSwitch.isOn") })
        #expect(code(try source("VocabularyBridge.swift")).contains { $0.contains("VocabularyRegistryStore(usesICloud: ICloudSwitch.isOn") })
    }
}
