//
//  KeychainStore.swift
//  Daisy
//
//  Thin Keychain wrapper for API tokens and OAuth refresh tokens.
//
//  ─── Two keychains, and why it matters (2026-09-19) ────────────────
//
//  macOS has two: the legacy file-based keychain (login.keychain) and
//  the data protection keychain — the same one iOS has. `SecItemAdd`
//  on macOS writes to the LEGACY one unless you pass
//  `kSecUseDataProtectionKeychain: true`. Daisy wrote to the legacy
//  one for its whole life, and that keychain:
//
//    • does not sync through iCloud Keychain, at all, ever;
//    • treats `kSecAttrAccessGroup` differently (no team-prefixed
//      sharing between apps).
//
//  Both are required for the iPhone companion: the user enters an
//  Anthropic key on the Mac once, and DaisyLite finds it already
//  there. So items go to the data protection keychain, in the shared
//  access group.
//
//  ─── iCloud only behind the sync switch (2026-11-16) ──────────────
//
//  Until 1.0.8.52 every item was marked `kSecAttrSynchronizable`, sync
//  on or off: with iCloud Keychain on in macOS, each key and token went
//  to iCloud the moment it was saved, while Settings said «nothing
//  leaves this Mac until you turn it on». Now the place follows the
//  switch (`ICloudSwitch`):
//
//    • sync on  — `.iCloud`: synchronizable, as before;
//    • sync off — `.thisMac`: same keychain, same group, not
//      synchronizable. iCloud Keychain never sees it.
//
//  The two are separate namespaces (synchronizable is part of an item's
//  identity), so one account can have a copy in each. The rules:
//
//    • a write goes to the switch's place; with sync on the this-Mac
//      copy is dropped, so there is one truth. An empty value is a
//      removal (`save`);
//    • a read looks in the switch's place. With sync off the iCloud
//      copy is not read: a key that arrived from another Mac must not
//      switch a cloud provider on here without anyone asking;
//    • `remove` deletes everywhere — Disconnect has to mean
//      disconnected, and a copy left in iCloud would come back the day
//      sync goes on. One exception, with sync off: a secret this Mac
//      does not have is not deleted from iCloud either. Several callers
//      remove «what is not set here» while saving, and on a Mac that
//      never took the iCloud copy that would wipe another device's key;
//    • the switch going on: what was saved here while it was off goes
//      up and wins — it is the person's latest (`changedHereKey`). A
//      copy this Mac only took from iCloud gives way to what iCloud has
//      now, which another device may have changed since. Nothing is
//      dropped that iCloud does not also have;
//    • the switch going off copies iCloud's items to this Mac, and
//      leaves iCloud as it is — «turning sync off does not delete what
//      is already in iCloud».
//
//  An install that updates with sync off has everything in `.iCloud`.
//  The first call copies those items to `.thisMac`, once
//  (`SecretVault.adoptedKey`) — or the update would log the person out
//  of Notion, Google and their summary provider. The iCloud copies are
//  left alone: deleting a synchronizable item deletes it on every
//  device, and another Mac running an older Daisy reads nothing else. A
//  new install copies nothing.
//
//  The data protection keychain never asks the person anything, so it
//  is used under one lock (`gate`): a write, a read and the switch
//  cannot interleave. The legacy keychain can raise a dialog and is
//  always touched outside that lock.
//
import Foundation
import Security
import os

/// Where a secret can live.
nonisolated enum KeychainPlace: Sendable {
    /// Data protection keychain, shared group, synchronizable: iCloud
    /// Keychain carries it to the person's other devices.
    case iCloud
    /// Data protection keychain, shared group, this Mac only.
    case thisMac
    /// login.keychain — where everything lived before 1.0.7.73.
    case legacy
}

/// The keychain as `SecretVault` uses it. A protocol so the rules can be
/// tested: the real one needs a signed process with the access group.
nonisolated protocol KeychainBackend: Sendable {
    func read(account: String, in place: KeychainPlace) -> (value: String?, status: OSStatus)
    func write(_ value: String, account: String, in place: KeychainPlace) -> OSStatus
    func delete(account: String, in place: KeychainPlace) -> OSStatus
    /// Every account of Daisy's in `place`. Not asked of `.legacy`.
    func accounts(in place: KeychainPlace) -> (accounts: [String], status: OSStatus)
}

nonisolated struct SystemKeychain: KeychainBackend {
    private static let service = "app.essazanov.Daisy"

    private func baseQuery(_ place: KeychainPlace, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if place != .legacy {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = KeychainStore.accessGroup
            // Synchronizable items are a separate namespace: a query
            // says which of the two it means.
            query[kSecAttrSynchronizable as String] = place == .iCloud
        }
        return query
    }

    func read(account: String, in place: KeychainPlace) -> (value: String?, status: OSStatus) {
        var query = baseQuery(place, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return (nil, status)
        }
        return (value, status)
    }

    func write(_ value: String, account: String, in place: KeychainPlace) -> OSStatus {
        let data = Data(value.utf8)
        let query = baseQuery(place, account: account)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus != errSecItemNotFound { return updateStatus }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        // Not a `...ThisDeviceOnly` class: those never sync, which for
        // `.iCloud` would quietly defeat the whole point.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(addQuery as CFDictionary, nil)
    }

    func delete(account: String, in place: KeychainPlace) -> OSStatus {
        SecItemDelete(baseQuery(place, account: account) as CFDictionary)
    }

    func accounts(in place: KeychainPlace) -> (accounts: [String], status: OSStatus) {
        var query = baseQuery(place, account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var items: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess, let list = items as? [[String: Any]] else { return ([], status) }
        return (list.compactMap { $0[kSecAttrAccount as String] as? String }, status)
    }
}

/// A keychain that lives and dies with the process — the test host's.
/// The app is its own test host, and the real keychain there is the
/// person's: a test run must neither read their keys nor leave any.
nonisolated final class InMemoryKeychain: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [KeychainPlace: [String: String]] = [:]

    func read(account: String, in place: KeychainPlace) -> (value: String?, status: OSStatus) {
        lock.withLock {
            guard let value = items[place]?[account] else { return (nil, errSecItemNotFound) }
            return (value, errSecSuccess)
        }
    }

    func write(_ value: String, account: String, in place: KeychainPlace) -> OSStatus {
        lock.withLock {
            items[place, default: [:]][account] = value
            return errSecSuccess
        }
    }

    func delete(account: String, in place: KeychainPlace) -> OSStatus {
        lock.withLock {
            items[place]?.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    func accounts(in place: KeychainPlace) -> (accounts: [String], status: OSStatus) {
        lock.withLock {
            let accounts = (items[place] ?? [:]).keys.sorted()
            return (accounts, accounts.isEmpty ? errSecItemNotFound : errSecSuccess)
        }
    }
}

/// The rules of the header, over any keychain.
nonisolated final class SecretVault: @unchecked Sendable {
    /// Set once this install's iCloud items have a this-Mac copy (or it
    /// is a new install with none to copy).
    static let adoptedKey = "daisy.keychain.iCloudItemsAdopted.v1"
    /// The accounts saved on this Mac while sync was off: the ones whose
    /// value here is the person's latest. Account names, never values.
    static let changedHereKey = "daisy.keychain.changedOnThisMac.v1"

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Keychain")
    private let backend: any KeychainBackend
    private let iCloudOn: @Sendable () -> Bool
    private let isExistingInstall: @Sendable () -> Bool
    /// Where the two keys above are kept. `nil`: never adopt, and keep
    /// the list in memory — the test host, whose defaults are the
    /// person's real ones.
    private let defaults: UserDefaults?

    /// Held over every use of the data protection keychain, and never
    /// over the legacy one (see the header). Guards the three below.
    private let gate = NSLock()
    private var prepared = false
    private var changedHereInMemory: Set<String> = []
    private let available = OSAllocatedUnfairLock(initialState: true)

    init(backend: any KeychainBackend,
         iCloudOn: @escaping @Sendable () -> Bool,
         isExistingInstall: @escaping @Sendable () -> Bool,
         defaults: UserDefaults?) {
        self.backend = backend
        self.iCloudOn = iCloudOn
        self.isExistingInstall = isExistingInstall
        self.defaults = defaults
    }

    /// False when the data protection keychain refused us — signing or
    /// entitlements — and everything is running on the legacy keychain.
    /// Nothing is broken; the iPhone just won't see these keys.
    var dataProtectionAvailable: Bool { available.withLock { $0 } }

    private func noteEntitlementFailure(_ status: OSStatus, op: StaticString) {
        guard status == errSecMissingEntitlement || status == errSecNoAccessForItem else { return }
        let wasAvailable = available.withLock { state in
            defer { state = false }
            return state
        }
        if wasAvailable {
            log.error("Shared keychain unavailable (\(op, privacy: .public) → \(status)); using the legacy keychain. iCloud sync with iPhone is off.")
        }
    }

    /// The place the switch points at.
    private var place: KeychainPlace { iCloudOn() ? .iCloud : .thisMac }

    /// Only under `gate`.
    private var changedHere: Set<String> {
        get {
            guard let defaults else { return changedHereInMemory }
            return Set(defaults.stringArray(forKey: Self.changedHereKey) ?? [])
        }
        set {
            guard let defaults else { changedHereInMemory = newValue; return }
            defaults.set(newValue.sorted(), forKey: Self.changedHereKey)
        }
    }

    // MARK: - Read / write

    /// What a settings field holds: trimmed, and an empty field is a
    /// removal. Writing "" instead (as until 16.11) would leave the real
    /// key in iCloud Keychain behind an empty copy on this Mac.
    func save(_ raw: String, account: String) throws {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            remove(account: account)
        } else {
            try set(value, account: account)
        }
    }

    /// Store or update a string value under `account`.
    func set(_ value: String, account: String) throws {
        let outcome: OSStatus? = gate.withLock {
            prepareLocked()
            guard dataProtectionAvailable else { return nil }
            let status = writeLocked(value, account: account, savedHere: true)
            if status != errSecSuccess { noteEntitlementFailure(status, op: "set") }
            return status
        }
        if outcome == errSecSuccess { return }
        if let outcome, dataProtectionAvailable {
            log.error("Keychain write failed: \(outcome)")
            throw KeychainStore.KeychainError.osError(outcome)
        }
        let status = backend.write(value, account: account, in: .legacy)
        guard status == errSecSuccess else {
            log.error("Legacy keychain write failed: \(status)")
            throw KeychainStore.KeychainError.osError(status)
        }
    }

    /// A value into the switch's place. `savedHere`: the person saved it
    /// on this Mac just now, so with sync off it is marked as this Mac's
    /// latest. Not for a value carried over from the legacy keychain —
    /// that one is as old as the day the keychains were switched, and
    /// must not win over what iCloud holds when sync goes on.
    private func writeLocked(_ value: String, account: String, savedHere: Bool) -> OSStatus {
        let place = place
        // The same value again (some callers re-save every token on any
        // change) is not a change: a copy taken from iCloud stays one.
        if place == .thisMac, backend.read(account: account, in: .thisMac).value == value {
            return errSecSuccess
        }
        let status = backend.write(value, account: account, in: place)
        guard status == errSecSuccess else { return status }
        if place == .iCloud {
            // One truth while sync is on: a this-Mac copy left from
            // before would go stale with the next change elsewhere.
            _ = backend.delete(account: account, in: .thisMac)
            changedHere.remove(account)
        } else if savedHere {
            changedHere.insert(account)
        }
        return status
    }

    /// The data protection keychain only — never the legacy one, so this
    /// can never raise the system's permission dialog.
    func getWithoutPrompting(account: String) -> String? {
        readProtected(account: account, op: "read-shared")
    }

    /// A value found only in the legacy keychain is copied forward
    /// before it is returned, so the first launch after the switch of
    /// keychains migrates whatever the person actually uses.
    func get(account: String) -> String? {
        readProtected(account: account, op: "get") ?? copyForwardFromLegacy(account: account, op: "migrate")
    }

    private func readProtected(account: String, op: StaticString) -> String? {
        gate.withLock {
            prepareLocked()
            return readProtectedLocked(account: account, op: op)
        }
    }

    private func readProtectedLocked(account: String, op: StaticString) -> String? {
        guard dataProtectionAvailable else { return nil }
        guard iCloudOn() else {
            let (value, status) = backend.read(account: account, in: .thisMac)
            noteEntitlementFailure(status, op: op)
            return value
        }
        // Saved here while sync was off, and the move at switch-on did
        // not carry it (the keychain was locked, say): it is still the
        // person's latest, whatever iCloud holds. Carry it now.
        if changedHere.contains(account), let kept = backend.read(account: account, in: .thisMac).value {
            _ = writeLocked(kept, account: account, savedHere: true)
            return kept
        }
        let (value, status) = backend.read(account: account, in: .iCloud)
        if let value { return value }
        noteEntitlementFailure(status, op: op)
        guard dataProtectionAvailable else { return nil }
        // A copy on this Mac and nothing in iCloud: the last one.
        let (kept, _) = backend.read(account: account, in: .thisMac)
        guard let kept else { return nil }
        _ = writeLocked(kept, account: account, savedHere: false)
        return kept
    }

    /// The legacy keychain's value for `account`, copied to the switch's
    /// place on the way. The read may raise the system's dialog, so it
    /// runs outside `gate`; whatever was saved meanwhile wins.
    private func copyForwardFromLegacy(account: String, op: StaticString) -> String? {
        let (legacyValue, _) = backend.read(account: account, in: .legacy)
        guard let legacyValue else { return nil }
        return gate.withLock {
            guard dataProtectionAvailable else { return legacyValue }
            if let newer = readProtectedLocked(account: account, op: op) { return newer }
            let status = writeLocked(legacyValue, account: account, savedHere: false)
            if status == errSecSuccess {
                log.notice("Migrated \(account, privacy: .public) out of the legacy keychain.")
            } else {
                noteEntitlementFailure(status, op: op)
                log.error("Could not migrate \(account, privacy: .public): \(status)")
            }
            return legacyValue
        }
    }

    /// Remove a stored value from every place. Disconnect has to mean
    /// disconnected — a token left in the legacy keychain would be read
    /// back by `get`'s fallback on the very next launch, and one left in
    /// iCloud the day sync goes on.
    ///
    /// With sync off, the iCloud copy goes only when this Mac had the
    /// secret: see the header.
    @discardableResult
    func remove(account: String) -> Bool {
        let legacyStatus = backend.delete(account: account, in: .legacy)
        let protectedOK = gate.withLock { () -> Bool in
            prepareLocked()
            guard dataProtectionAvailable else { return true }
            var statuses = [backend.delete(account: account, in: .thisMac)]
            changedHere.remove(account)
            if iCloudOn() || statuses[0] == errSecSuccess || legacyStatus == errSecSuccess {
                statuses.append(backend.delete(account: account, in: .iCloud))
            }
            var ok = true
            for status in statuses {
                noteEntitlementFailure(status, op: "remove")
                if status != errSecSuccess, status != errSecItemNotFound, dataProtectionAvailable { ok = false }
            }
            return ok
        }
        return protectedOK && (legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound)
    }

    // MARK: - Migration out of the legacy keychain

    /// Copy every known secret from the legacy keychain forward. `get`
    /// already migrates lazily; this makes it deterministic so a key the
    /// person doesn't happen to touch on the Mac still reaches the iPhone.
    ///
    /// **Never on the main thread, never at launch.** Reading a legacy
    /// item whose ACL does not list this binary makes macOS ask the
    /// person, modally; eight of those before the first window is an
    /// app that appears to hang (2026-09-22). Items already migrated
    /// are skipped, so the pass is cheap on every run after the first.
    func migrateLegacyItems(_ accounts: [String]) {
        var migrated = 0
        for account in accounts {
            if readProtected(account: account, op: "migrate-scan") != nil { continue }
            guard dataProtectionAvailable else { return }
            if copyForwardFromLegacy(account: account, op: "migrate-scan") != nil { migrated += 1 }
        }
        if migrated > 0 {
            log.notice("Keychain migration: moved \(migrated) item(s) out of the legacy keychain.")
        }
    }

    // MARK: - The sync switch

    /// The person flipped the switch; the defaults already say `on`.
    /// The data protection keychain only: no dialog, a few milliseconds.
    func iCloudSwitchChanged(to on: Bool) {
        gate.withLock {
            prepared = true
            guard dataProtectionAvailable else { return }
            // `adoptedKey` means «this Mac has a copy of everything it
            // had in iCloud», and that stops being true the moment the
            // items move up. Off again, it is true only if the copy
            // back was whole; if not, the next launch finishes it, and
            // «Delete my data from iCloud» will not delete before then.
            if on {
                moveThisMacItemsToICloudLocked()
                defaults?.set(false, forKey: Self.adoptedKey)
            } else {
                defaults?.set(copyICloudItemsToThisMacLocked(), forKey: Self.adoptedKey)
            }
        }
    }

    /// «Delete my data from iCloud», with sync off: every item of
    /// Daisy's leaves iCloud Keychain — on every device, that is what
    /// deleting a synchronizable item does — and this Mac keeps what it
    /// has. With sync on nothing is deleted: iCloud is then the only
    /// place the keys are.
    ///
    /// Nothing is copied here first, with one exception. An item this
    /// Mac never took (it arrived from another device after the update)
    /// is the other device's to keep. But an update whose one-time copy
    /// has not finished would lose keys it has always had, so that copy
    /// is completed before anything is deleted — or nothing is.
    ///
    /// False when an item could not be deleted, or the copy not made.
    func eraseICloudItems() -> Bool {
        gate.withLock {
            prepareLocked()
            guard dataProtectionAvailable, !iCloudOn() else { return true }
            if let defaults, !defaults.bool(forKey: Self.adoptedKey) {
                guard copyICloudItemsToThisMacLocked() else { return false }
                defaults.set(true, forKey: Self.adoptedKey)
            }
            let (accounts, status) = backend.accounts(in: .iCloud)
            guard status == errSecSuccess else {
                noteEntitlementFailure(status, op: "erase-scan")
                return status == errSecItemNotFound
            }
            var complete = true
            for account in accounts {
                let deleted = backend.delete(account: account, in: .iCloud)
                if deleted != errSecSuccess, deleted != errSecItemNotFound { complete = false }
            }
            log.notice("Keychain: \(accounts.count, privacy: .public) item(s) asked out of iCloud Keychain.")
            return complete
        }
    }

    /// Once per run, before the first read or write: an install that
    /// updates with sync off gets this-Mac copies of what it kept in
    /// iCloud. Retried on the next launch until every item made it.
    private func prepareLocked() {
        guard !prepared else { return }
        prepared = true
        guard let defaults, !iCloudOn(), !defaults.bool(forKey: Self.adoptedKey) else { return }
        if isExistingInstall() {
            guard copyICloudItemsToThisMacLocked() else { return }
        }
        defaults.set(true, forKey: Self.adoptedKey)
    }

    /// A this-Mac copy of every iCloud item that has none. One that is
    /// already here stays: it is either this copy from before or what
    /// the person saved since. False when anything could not be read or
    /// written — the caller must not mark the copy as done.
    private func copyICloudItemsToThisMacLocked() -> Bool {
        let (accounts, status) = backend.accounts(in: .iCloud)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            noteEntitlementFailure(status, op: "adopt-scan")
            log.error("Could not list the iCloud keychain items: \(status)")
            return false
        }
        var complete = true
        var copied = 0
        for account in accounts {
            if backend.read(account: account, in: .thisMac).value != nil { continue }
            let (value, readStatus) = backend.read(account: account, in: .iCloud)
            guard let value else {
                if readStatus != errSecSuccess, readStatus != errSecItemNotFound { complete = false }
                continue
            }
            if backend.write(value, account: account, in: .thisMac) == errSecSuccess {
                copied += 1
            } else {
                complete = false
            }
        }
        if copied > 0 {
            log.notice("Keychain: \(copied, privacy: .public) item(s) now have a copy on this Mac only.")
        }
        return complete
    }

    /// Sync went on. Each item on this Mac either goes up or gives way:
    /// saved here while sync was off — up, and it wins; a copy taken
    /// from iCloud — iCloud's current value stands, since another
    /// device may have changed it; and where iCloud has nothing (its
    /// keychain was switched off in macOS meanwhile, say) the copy goes
    /// up rather than be lost.
    private func moveThisMacItemsToICloudLocked() {
        let (accounts, status) = backend.accounts(in: .thisMac)
        guard status == errSecSuccess else {
            noteEntitlementFailure(status, op: "attach-scan")
            return
        }
        var changed = changedHere
        var moved = 0
        for account in accounts {
            if !changed.contains(account) {
                let (current, readStatus) = backend.read(account: account, in: .iCloud)
                if current != nil {
                    _ = backend.delete(account: account, in: .thisMac)
                    continue
                }
                // Unreadable right now: leave both; the next read sorts it out.
                guard readStatus == errSecItemNotFound else { continue }
            }
            guard let value = backend.read(account: account, in: .thisMac).value else { continue }
            if backend.write(value, account: account, in: .iCloud) == errSecSuccess {
                _ = backend.delete(account: account, in: .thisMac)
                changed.remove(account)
                moved += 1
            }
        }
        changedHere = changed
        if moved > 0 {
            log.notice("Keychain: \(moved, privacy: .public) item(s) moved to iCloud Keychain with sync on.")
        }
    }
}

nonisolated enum KeychainStore {
    /// Team-prefixed group shared with the iPhone app (`DaisyLite`).
    /// Mirrors `keychain-access-groups` in Daisy.entitlements, where it
    /// is written as `$(AppIdentifierPrefix)app.essazanov.Daisy.shared`
    /// — the prefix is the team ID, expanded at build time. At runtime
    /// the literal is required, so the two must be changed together.
    static let accessGroup = "LW64FQXZCU.app.essazanov.Daisy.shared"

    enum KeychainError: Error {
        case osError(OSStatus)
    }

    /// The app's one vault. In the test host: a keychain in memory and
    /// no defaults — the real ones are the person's.
    private static let vault = SecretVault(
        backend: TestHost.isActive ? InMemoryKeychain() : SystemKeychain(),
        iCloudOn: { ICloudSwitch.isOn },
        isExistingInstall: { ICloudSwitch.isExistingInstall },
        defaults: TestHost.isActive ? nil : .standard)

    /// False when the data protection keychain refused us — signing or
    /// entitlements — and everything is running on the legacy keychain.
    /// Nothing is broken; the iPhone just won't see these keys.
    static var sharedKeychainAvailable: Bool { vault.dataProtectionAvailable }

    /// Store or update a string value under `account`.
    static func set(_ value: String, account: String) throws {
        try vault.set(value, account: account)
    }

    /// What a settings field holds: trimmed, and empty means removed.
    static func save(_ raw: String, account: String) throws {
        try vault.save(raw, account: account)
    }

    /// Retrieve a string value, or nil if not present.
    ///
    /// The data protection keychain only — never the legacy one, so this
    /// can never raise the system's permission dialog. For the launch
    /// path (`AppSettings.init`), which must not block: what is missing
    /// here is filled in afterwards, off the main thread, by `get`.
    static func getWithoutPrompting(account: String) -> String? {
        vault.getWithoutPrompting(account: account)
    }

    /// A value found only in the legacy keychain is copied forward
    /// before it is returned.
    static func get(account: String) -> String? {
        vault.get(account: account)
    }

    /// Remove a stored value from every place it can be in.
    @discardableResult
    static func remove(account: String) -> Bool {
        vault.remove(account: account)
    }

    /// See `SecretVault.migrateLegacyItems`. Called from
    /// `SyncCoordinator` when sync is switched on — the only feature
    /// that needs the keys on another device.
    static func migrateLegacyItems() {
        vault.migrateLegacyItems(SecretKey.all)
    }

    /// See `SecretVault.iCloudSwitchChanged`.
    static func iCloudSwitchChanged(to on: Bool) {
        vault.iCloudSwitchChanged(to: on)
    }

    /// See `SecretVault.eraseICloudItems`.
    static func eraseICloudItems() -> Bool {
        vault.eraseICloudItems()
    }
}

// MARK: - Typed accessors

nonisolated enum SecretKey {
    static let notionToken = "notion.token"
    static let notionParentID = "notion.parent_id"
    static let anthropicAPIKey = "anthropic.api_key"
    static let openaiAPIKey = "openai.api_key"
    static let cursorAPIKey = "cursor.api_key"
    static let kimiAPIKey = "kimi.api_key"
    static let geminiAPIKey = "gemini.api_key"
    static let yandexAPIKey = "yandex.api_key"
    static let gigachatAPIKey = "gigachat.api_key"
    static let deepseekAPIKey = "deepseek.api_key"
    static let grokAPIKey = "grok.api_key"
    /// YandexGPT's folder ID, mirrored from `Summarizer.yandexFolderID`
    /// for the iPhone (04.11). Not a secret and not in `all`: it never
    /// lived in the legacy keychain.
    static let yandexFolderID = "yandex.folder_id"
    /// Google OAuth refresh token — long-lived, used to mint new
    /// access tokens. Cleared on Disconnect (after a revoke roundtrip
    /// to Google so the consent grant is gone server-side too).
    static let googleRefreshToken = "google.refresh_token"
    /// Email address of the Google account Daisy is connected to.
    /// Display-only — shows in Settings as "Connected as <email>".
    /// Stored alongside the token so they can't drift apart.
    static let googleEmail = "google.email"

    /// Everything `migrateLegacyItems()` walks. A new key added above
    /// and forgotten here still migrates lazily on first read — this
    /// list only makes it eager.
    static let all: [String] = [
        notionToken,
        notionParentID,
        anthropicAPIKey,
        openaiAPIKey,
        cursorAPIKey,
        kimiAPIKey,
        geminiAPIKey,
        yandexAPIKey,
        gigachatAPIKey,
        deepseekAPIKey,
        grokAPIKey,
        googleRefreshToken,
        googleEmail,
    ]
}
