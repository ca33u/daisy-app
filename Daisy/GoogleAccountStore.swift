// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  GoogleAccountStore.swift
//  Daisy
//
//  Persistence + in-memory cache for the Google Calendar OAuth state.
//  The refresh token + connected email live in the macOS Keychain
//  (long-term, encrypted). The current access token lives only in
//  memory — it's short-lived (1h TTL) and getting refreshed from the
//  refresh token is fast (~150ms one-time per hour).
//
//  Public surface:
//   - `isConnected` — UI gates Connect / Disconnect on this.
//   - `email` — display only, what we show in Settings.
//   - `validAccessToken()` async — returns a non-expired access
//     token, refreshing it from Google if needed. Anything that
//     calls the Calendar API goes through here.
//   - `save(connect:)` — persist tokens after a successful OAuth flow.
//   - `disconnect()` — revoke on Google's end + wipe local state.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class GoogleAccountStore {
    static let shared = GoogleAccountStore()

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "GoogleAccount")

    // MARK: - Observable state

    /// True when a refresh token is on file. The actual access
    /// token may be expired or missing in memory; `validAccessToken()`
    /// handles minting one.
    private(set) var isConnected: Bool = false

    /// Display-only label of the connected account (e.g.
    /// `alex@gmail.com`). Settings reads this for the connected-state
    /// pill; nil when not connected.
    private(set) var email: String?

    // MARK: - Private state

    /// Cached current access token. Re-derived from `refreshToken`
    /// when it expires.
    private var accessToken: String?
    private var accessTokenExpiresAt: Date?

    /// In-flight refresh task — coalesces concurrent `validAccessToken()`
    /// callers so we don't fire two refresh requests when several
    /// API calls race for a fresh token.
    private var refreshTask: Task<String, Error>?

    private init() {
        // Restore connected state from Keychain on app launch.
        // Refresh token presence is what defines "connected".
        let refresh = KeychainStore.get(account: SecretKey.googleRefreshToken)
        if let refresh, !refresh.isEmpty {
            isConnected = true
            email = KeychainStore.get(account: SecretKey.googleEmail)
        }
    }

    // MARK: - Save / clear

    /// Persist the result of a successful OAuth flow. Caller is
    /// `GoogleOAuthClient.connect()`; we don't open the flow ourselves
    /// because doing so would couple the store to AppKit.
    func save(connect result: GoogleOAuthClient.ConnectResult) {
        do {
            try KeychainStore.set(result.refreshToken, account: SecretKey.googleRefreshToken)
            try KeychainStore.set(result.email, account: SecretKey.googleEmail)
        } catch {
            log.error("Couldn't persist Google credentials: \(error.localizedDescription, privacy: .public)")
            // Even if Keychain write failed, keep the in-memory
            // token so this session still works. Next launch will
            // re-prompt the user — acceptable degradation.
        }
        accessToken = result.accessToken
        accessTokenExpiresAt = result.expiresAt
        email = result.email
        isConnected = true
        // Email is PII — keep .private so it doesn't land in the
        // unified system log where any process running Console.app
        // (or another app querying os_log) could harvest it.
        log.info("Google account connected: \(result.email, privacy: .private)")
    }

    /// Tell Google to revoke the refresh token, then wipe local
    /// state. Network call is best-effort — even if Google times
    /// out we still want the local Keychain entry gone, otherwise
    /// re-Connect would silently inherit the stale token.
    func disconnect() async {
        let refresh = KeychainStore.get(account: SecretKey.googleRefreshToken)
        if let refresh, !refresh.isEmpty {
            await GoogleOAuthClient.revoke(refreshToken: refresh)
        }
        KeychainStore.remove(account: SecretKey.googleRefreshToken)
        KeychainStore.remove(account: SecretKey.googleEmail)
        accessToken = nil
        accessTokenExpiresAt = nil
        refreshTask = nil
        email = nil
        isConnected = false
        log.info("Google account disconnected")
    }

    // MARK: - Token resolution

    /// Return a non-expired access token. Callers (Calendar service)
    /// use this for every API request. Three paths:
    ///
    ///  1. Cached token is still valid → return it directly.
    ///  2. A refresh is already in flight → await its result.
    ///  3. Refresh from Google, store, return.
    ///
    /// Throws if no refresh token is on file (user never connected)
    /// or if the refresh itself fails (revoked / network).
    func validAccessToken() async throws -> String {
        // Fast path: cached token, not yet near expiry.
        if let token = accessToken,
           let expiry = accessTokenExpiresAt,
           expiry > Date() {
            return token
        }

        // Coalesce: if someone else is already refreshing, ride
        // along.
        if let inflight = refreshTask {
            return try await inflight.value
        }

        // Start a fresh refresh.
        guard let refresh = KeychainStore.get(account: SecretKey.googleRefreshToken),
              !refresh.isEmpty else {
            // User is not connected. Surface as a typed error
            // rather than letting the call hit Calendar API with
            // a nil token.
            throw GoogleOAuthClient.OAuthError.refreshFailed("No Google account connected.")
        }

        let task = Task<String, Error> { [weak self] in
            do {
                let result = try await GoogleOAuthClient.refreshAccessToken(refreshToken: refresh)
                await MainActor.run {
                    self?.accessToken = result.accessToken
                    self?.accessTokenExpiresAt = result.expiresAt
                    self?.refreshTask = nil
                }
                return result.accessToken
            } catch {
                // Only wipe the token on a PERMANENT auth failure (the
                // user revoked Daisy → invalid_grant). A transient error —
                // offline, timeout, Google 5xx — must NOT force a full
                // reconnect; keep the token and let the next call retry.
                await MainActor.run {
                    if Self.isPermanentAuthFailure(error) {
                        self?.handleRefreshFailure()
                    } else {
                        self?.refreshTask = nil
                        self?.log.warning("Google token refresh failed transiently — keeping auth, will retry")
                    }
                }
                throw error
            }
        }
        refreshTask = task
        return try await task.value
    }

    /// True only for a permanent auth failure that genuinely requires the
    /// user to reconnect (token revoked / no longer valid). Transport
    /// errors and server-side 5xx are transient and return false.
    nonisolated static func isPermanentAuthFailure(_ error: Error) -> Bool {
        if error is URLError { return false }
        if let oauth = error as? GoogleOAuthClient.OAuthError,
           case .refreshFailed(let msg) = oauth {
            let m = msg.lowercased()
            // Google returns these in the token-endpoint error body when the
            // grant itself is dead (revoked / expired / app deauthorized).
            return m.contains("invalid_grant")
                || m.contains("unauthorized_client")
                || m.contains("invalid_client")
        }
        // Unknown shape → conservative: treat as transient, keep the token.
        return false
    }

    private func handleRefreshFailure() {
        log.warning("Google refresh failed — clearing local state, forcing reconnect")
        KeychainStore.remove(account: SecretKey.googleRefreshToken)
        KeychainStore.remove(account: SecretKey.googleEmail)
        accessToken = nil
        accessTokenExpiresAt = nil
        refreshTask = nil
        email = nil
        isConnected = false
    }
}
