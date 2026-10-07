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
//  there. So items now go to the data protection keychain, in the
//  shared access group, marked `kSecAttrSynchronizable`.
//
//  ─── The migration ────────────────────────────────────────────────
//
//  Switching keychains makes existing items INVISIBLE — same API, same
//  service, same account, no result. Left alone that silently logs
//  every user out of Notion, Google and their summary provider. So
//  `get` falls back to the legacy keychain, and a hit there is copied
//  forward before it is returned; `migrateLegacyItems()` does the same
//  eagerly at launch for every known key. `remove` deletes from BOTH,
//  or Disconnect would leave a live token behind in the old keychain.
//
//  The legacy copy is deliberately LEFT IN PLACE after migration: an
//  older Daisy (a user who downgrades, or runs a second install) still
//  reads it, and a stale-but-valid token beats an empty field. It gets
//  overwritten on the next `set`, and removed on Disconnect.
//
//  ─── The fallback ─────────────────────────────────────────────────
//
//  The data protection keychain needs the `keychain-access-groups`
//  entitlement, and Daisy is Developer ID-signed and non-sandboxed —
//  a combination where a signing mistake shows up at runtime, not at
//  build time, as `errSecMissingEntitlement`. If that happens every
//  path degrades to the legacy keychain rather than failing: worse
//  sync, working app. `sharedKeychainAvailable` reports which way it
//  went so Settings can be honest about it.
//

import Foundation
import Security
import os

nonisolated enum KeychainStore {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "Keychain")
    private static let service = "app.essazanov.Daisy"

    /// Team-prefixed group shared with the iPhone app (`DaisyLite`).
    /// Mirrors `keychain-access-groups` in Daisy.entitlements, where it
    /// is written as `$(AppIdentifierPrefix)app.essazanov.Daisy.shared`
    /// — the prefix is the team ID, expanded at build time. At runtime
    /// the literal is required, so the two must be changed together.
    static let accessGroup = "LW64FQXZCU.app.essazanov.Daisy.shared"

    enum KeychainError: Error {
        case osError(OSStatus)
    }

    // MARK: - Which keychain

    private enum Store {
        /// Data protection keychain: syncs, shares with the iPhone.
        case shared
        /// login.keychain — where everything lived before 1.0.7.73.
        case legacy
    }

    private static func baseQuery(_ store: Store, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if store == .shared {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = accessGroup
            // Synchronizable items are a separate namespace: a query
            // that doesn't say so matches only non-synchronizable ones.
            query[kSecAttrSynchronizable as String] = true
        }
        return query
    }

    /// False when the data protection keychain refused us — signing or
    /// entitlements — and everything is running on the legacy keychain.
    /// Nothing is broken; the iPhone just won't see these keys.
    nonisolated(unsafe) private(set) static var sharedKeychainAvailable = true

    private static func noteEntitlementFailure(_ status: OSStatus, op: StaticString) {
        guard status == errSecMissingEntitlement || status == errSecNoAccessForItem else { return }
        if sharedKeychainAvailable {
            log.error("Shared keychain unavailable (\(op, privacy: .public) → \(status)); using the legacy keychain. iCloud sync with iPhone is off.")
        }
        sharedKeychainAvailable = false
    }

    // MARK: - Read / write

    /// Store or update a string value under `account`.
    static func set(_ value: String, account: String) throws {
        if sharedKeychainAvailable {
            let status = write(value, account: account, store: .shared)
            if status == errSecSuccess { return }
            noteEntitlementFailure(status, op: "set")
            guard !sharedKeychainAvailable else {
                log.error("Keychain write failed: \(status)")
                throw KeychainError.osError(status)
            }
        }
        let status = write(value, account: account, store: .legacy)
        guard status == errSecSuccess else {
            log.error("Legacy keychain write failed: \(status)")
            throw KeychainError.osError(status)
        }
    }

    private static func write(_ value: String, account: String, store: Store) -> OSStatus {
        let data = Data(value.utf8)
        let query = baseQuery(store, account: account)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus != errSecItemNotFound { return updateStatus }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        // Not a `...ThisDeviceOnly` class: those never sync, which
        // would quietly defeat the whole point.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// Retrieve a string value, or nil if not present.
    ///
    /// The shared keychain only — never the legacy one, so this can
    /// never raise the system's permission dialog. For the launch path
    /// (`AppSettings.init`), which must not block: what is missing here
    /// is filled in afterwards, off the main thread, by `get`.
    nonisolated static func getWithoutPrompting(account: String) -> String? {
        guard sharedKeychainAvailable else { return nil }
        let (value, status) = read(account: account, store: .shared)
        noteEntitlementFailure(status, op: "read-shared")
        return value
    }

    /// A value found only in the legacy keychain is copied forward
    /// before it is returned, so the first launch after the switch
    /// migrates whatever the user actually uses.
    static func get(account: String) -> String? {
        if sharedKeychainAvailable {
            let (value, status) = read(account: account, store: .shared)
            if let value { return value }
            noteEntitlementFailure(status, op: "get")
        }

        let (legacyValue, _) = read(account: account, store: .legacy)
        guard let legacyValue else { return nil }

        if sharedKeychainAvailable {
            let status = write(legacyValue, account: account, store: .shared)
            if status == errSecSuccess {
                log.notice("Migrated \(account, privacy: .public) to the shared keychain.")
            } else {
                noteEntitlementFailure(status, op: "migrate")
                log.error("Could not migrate \(account, privacy: .public): \(status)")
            }
        }
        return legacyValue
    }

    private static func read(account: String, store: Store) -> (String?, OSStatus) {
        var query = baseQuery(store, account: account)
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

    /// Remove a stored value from both keychains. Disconnect has to
    /// mean disconnected — a token left in the legacy keychain would
    /// be read back by `get`'s fallback on the very next launch.
    @discardableResult
    static func remove(account: String) -> Bool {
        var ok = true
        if sharedKeychainAvailable {
            let status = SecItemDelete(baseQuery(.shared, account: account) as CFDictionary)
            noteEntitlementFailure(status, op: "remove")
            ok = status == errSecSuccess || status == errSecItemNotFound || !sharedKeychainAvailable
        }
        let legacyStatus = SecItemDelete(baseQuery(.legacy, account: account) as CFDictionary)
        return ok && (legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound)
    }

    // MARK: - Migration

    /// Copy every known secret from the legacy keychain to the shared
    /// one. `get` already migrates lazily; this makes it deterministic
    /// so a key the user doesn't happen to touch on the Mac still
    /// reaches the iPhone.
    ///
    /// **Never on the main thread, never at launch.** Reading a legacy
    /// item whose ACL does not list this binary makes macOS ask the
    /// person, modally; eight of those before the first window is an
    /// app that appears to hang (2026-09-22). Items already migrated
    /// are skipped, so the pass is cheap on every run after the first.
    /// Called from `SyncCoordinator` when sync is switched on — the
    /// only feature that needs the keys on another device.
    nonisolated static func migrateLegacyItems() {
        guard sharedKeychainAvailable else { return }
        var migrated = 0
        for account in SecretKey.all {
            let (existing, status) = read(account: account, store: .shared)
            if existing != nil { continue }
            noteEntitlementFailure(status, op: "migrate-scan")
            guard sharedKeychainAvailable else { return }

            let (legacyValue, _) = read(account: account, store: .legacy)
            guard let legacyValue else { continue }
            if write(legacyValue, account: account, store: .shared) == errSecSuccess {
                migrated += 1
            }
        }
        if migrated > 0 {
            log.notice("Keychain migration: moved \(migrated) item(s) to the shared keychain.")
        }
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
        googleRefreshToken,
        googleEmail,
    ]
}
