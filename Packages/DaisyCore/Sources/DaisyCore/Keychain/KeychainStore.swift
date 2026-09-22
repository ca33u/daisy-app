//
//  KeychainStore.swift
//  DaisyCore
//
//  Copied from daisy-app/Daisy/KeychainStore.swift (macOS Daisy
//  1.0.7.72, 2026-09-19), with two changes for the phone (backlog B-6):
//
//   1. `kSecAttrSynchronizable: true` on every query — this is what
//      makes an item ride iCloud Keychain between devices. The Mac
//      does NOT set this yet (its items are device-local), so a key
//      typed on the Mac today does not show up here — that migration
//      is Mac-side work, not something the phone can do to someone
//      else's already-written items. Recorded in the night report as
//      a task for daisy-app.
//   2. `kSecAttrAccessGroup` — a shared keychain-access-groups
//      entitlement, so a future watch app or widget extension could
//      read the same items without their own copy. Name to confirm
//      with Egor; using the backlog's placeholder for now.
//
//  Same `service` string as the Mac ("app.essazanov.Daisy", not
//  ".DaisyLite") and the same `SecretKey` account names — that overlap
//  is what lets a synchronizable item entered on one platform be FOUND
//  by the other once both sides opt in to sync.
//

import Foundation
import Security
import os

public nonisolated enum KeychainStore {
    private static let log = Logger(subsystem: DaisyCore.logSubsystem, category: "Keychain")
    private static let service = "app.essazanov.Daisy"
    /// Placeholder — confirm the exact string with Egor before relying
    /// on cross-target sharing (backlog B-6). `$(AppIdentifierPrefix)`
    /// is a build-setting variable Xcode substitutes into the
    /// entitlements file at sign time, so this literal (used only for
    /// the query dictionary) must match whatever the entitlement
    /// resolves to on THIS build's team.
    public static let accessGroup = "app.essazanov.Daisy.shared"

    public enum KeychainError: Error, Sendable {
        case osError(OSStatus)
    }

    /// Store or update a string value under `account`.
    public static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
        ]

        let attrs: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                log.error("Keychain add failed: \(addStatus)")
                throw KeychainError.osError(addStatus)
            }
            return
        }
        log.error("Keychain update failed: \(updateStatus)")
        throw KeychainError.osError(updateStatus)
    }

    /// Retrieve a string value, or nil if not present.
    public static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Remove a stored value.
    @discardableResult
    public static func remove(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - Typed accessors (subset the phone cares about)

/// Same account strings as the Mac's `SecretKey`: the four
/// summary-provider keys, plus the Google refresh token the phone
/// reads (never writes) so a calendar connected on the Mac shows up
/// here without a second sign-in (backlog 12 L-3).
public nonisolated enum SecretKey {
    public static let anthropicAPIKey = "anthropic.api_key"
    public static let openaiAPIKey = "openai.api_key"
    public static let cursorAPIKey = "cursor.api_key"
    public static let kimiAPIKey = "kimi.api_key"
    /// Written by the Mac's OAuth flow only. The phone mints access
    /// tokens from it and keeps them in memory; connecting and
    /// disconnecting Google stays a Mac action.
    public static let googleRefreshToken = "google.refresh_token"
    public static let googleEmail = "google.email"

    /// All four, for a Settings screen that shows which keys arrived.
    public static let summaryProviderKeys: [(label: String, account: String)] = [
        ("Anthropic", anthropicAPIKey),
        ("OpenAI", openaiAPIKey),
        ("Cursor", cursorAPIKey),
        ("Kimi", kimiAPIKey),
    ]
}
