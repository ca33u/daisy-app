//
//  GoogleOAuthClient.swift
//  Daisy
//
//  Google OAuth 2.0 client for desktop applications using the
//  "installed app" loopback flow with PKCE. Picks an ephemeral
//  localhost port, opens Google's auth page in the user's default
//  browser, captures the callback via a one-shot embedded HTTP
//  listener, and exchanges the authorization code for access +
//  refresh tokens.
//
//  ─── Why loopback + PKCE ──────────────────────────────────────
//
//  Google's OAuth client we registered in Cloud Console is a
//  "Desktop app" with `http://localhost` as the only allowed redirect.
//  Per Google's installed-app spec, this requires the loopback flow:
//  the app starts a local HTTP server on an ephemeral port, embeds
//  that exact port into the redirect_uri, and waits for the browser
//  to redirect to it.
//
//  PKCE (RFC 7636) replaces the role of `client_secret` for
//  installed apps. Google still requires the secret in the token
//  exchange request — but per their docs, it is NOT a true secret
//  for desktop apps and embedding it in source is acceptable.
//
//  ─── Threat model ────────────────────────────────────────────
//
//  - State nonce verified on callback → CSRF protection.
//  - PKCE code_verifier kept in-process → an attacker who intercepts
//    the code can't exchange it for tokens.
//  - Listener bound to 127.0.0.1 only → outside machines can't hit
//    the callback even on a shared Wi-Fi.
//  - 120s timeout → if the user closes Safari we don't leak the
//    listener forever.
//

import AppKit
import CryptoKit
import Foundation
import Network
import Security
import os

@MainActor
enum GoogleOAuthClient {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "GoogleOAuth")

    // MARK: - Client credentials
    //
    // ── Public by design ─────────────────────────────────────────
    //
    // These values come from the Daisy Desktop OAuth client in
    // Google Cloud project `daisy-496801`. They are embedded in the
    // source tree intentionally and remain so when the repository
    // is made public.
    //
    // For Google's "Desktop app" client type, `client_secret` is
    // explicitly NOT a confidentiality boundary. Google's own docs
    // say so:
    //
    //   "The process results in a client ID and, in some cases, a
    //    client secret, which you embed in the source code of your
    //    application. (In this context, the client secret is
    //    obviously not treated as a secret.)"
    //   — developers.google.com/identity/protocols/oauth2#installed
    //
    // The protocol-level protection on this flow is PKCE (RFC 7636):
    // every authorization request includes a one-time code_verifier
    // that Daisy keeps in-process, and Google won't exchange the
    // returned `code` for tokens unless the matching verifier is
    // produced. An attacker who clones this file gets nothing useful
    // — they can stand up their own loopback OAuth flow, but they
    // can't impersonate a Daisy install, intercept user tokens, or
    // extract anyone's calendar data with these strings alone.
    //
    // Trade-off documented here so it doesn't surprise public-repo
    // readers: because the secret is visible, it can't be rotated
    // for confidentiality reasons (since it isn't one). If Google
    // ever changes the model and a real rotation becomes necessary,
    // we'd cut a new client in Google Cloud Console and ship a new
    // build — that's the rotation cost we're accepting.

    static let clientID = "684526507676-qhj6k8ofmtca7o7913ce9vqcbvt0m5ju.apps.googleusercontent.com"
    static let clientSecret = "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"

    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    static let userInfoEndpoint = URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!

    /// Scopes Daisy requests at connect time. `calendar.readonly`
    /// is the only payload we actually use; `openid email profile`
    /// is needed to fetch the signed-in user's email for the
    /// Settings UI display ("Connected as alex@gmail.com").
    static let scopes: [String] = [
        "https://www.googleapis.com/auth/calendar.readonly",
        "openid",
        "email",
        "profile",
    ]

    // MARK: - Errors

    enum OAuthError: LocalizedError {
        case browserLaunchFailed
        case listenerFailed(String)
        case userCancelled
        case stateMismatch
        case missingCode(String?)
        case tokenExchangeFailed(String)
        case userInfoFailed(String)
        case refreshFailed(String)
        case timedOut
        case calendarScopeNotGranted

        var errorDescription: String? {
            switch self {
            case .browserLaunchFailed:
                return "Couldn't open Safari to start Google sign-in."
            case .listenerFailed(let m):
                return "Couldn't start the local callback listener: \(m)"
            case .userCancelled:
                return "Sign-in was cancelled."
            case .stateMismatch:
                return "Sign-in failed a security check (state mismatch). Try again."
            case .missingCode(let err):
                return err.map { "Google returned an error: \($0)" }
                    ?? "Google's response didn't include an authorization code."
            case .tokenExchangeFailed(let m):
                return "Couldn't trade the sign-in code for tokens: \(m)"
            case .userInfoFailed(let m):
                return "Connected, but couldn't read the account email: \(m)"
            case .refreshFailed(let m):
                return "Couldn't refresh the Google access token: \(m). Sign in again."
            case .timedOut:
                return "Sign-in didn't complete in 2 minutes — try again."
            case .calendarScopeNotGranted:
                return "Daisy couldn't see your calendar — the \"See events on your calendar\" checkbox was unticked during sign-in. Click Connect again and make sure that box is checked."
            }
        }
    }

    /// Scope identifier we MUST receive back from Google. Anything
    /// less means the user unchecked the Calendar permission on the
    /// consent screen (Google lets users grant only a subset of the
    /// scopes the app requested). Without this, every Calendar API
    /// call would silently return 403.
    private static let requiredScope = "https://www.googleapis.com/auth/calendar.readonly"

    // MARK: - Token DTOs

    /// What we hand back to the caller after a successful sign-in.
    /// Maps cleanly onto `GoogleAccountStore` for persistence.
    struct ConnectResult: Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let email: String
    }

    /// Token exchange response from Google. Includes the `scope`
    /// field so we can verify the user actually granted Calendar
    /// access on the consent screen — Google's UI presents each
    /// requested scope as a separate checkbox, and the user can
    /// untick any of them. Without verification, OAuth would
    /// "succeed" with only `openid email` granted, the user would
    /// see "Connected" in Settings, and every API call would
    /// silently return 403.
    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
        let scope: String?
    }

    /// Userinfo endpoint response — used right after token exchange
    /// to capture the signed-in email for UI display.
    private struct UserInfo: Decodable {
        let email: String
    }

    // MARK: - Public API

    /// Run the full sign-in flow. Returns a `ConnectResult` with
    /// fresh tokens + user email, or throws `OAuthError` on any
    /// failure. Caller is expected to persist the result via
    /// `GoogleAccountStore.save(_:)`.
    static func connect() async throws -> ConnectResult {
        // 1. Generate PKCE pair + state nonce.
        let codeVerifier = Self.randomURLSafeString(length: 64)
        let codeChallenge = Self.codeChallenge(for: codeVerifier)
        let state = Self.randomURLSafeString(length: 32)

        // 2. Start local listener on an ephemeral port, get the
        //    actual port so we can build the redirect_uri.
        let callback = try await CallbackListener.start()
        defer { callback.stop() }

        let redirectURI = "http://localhost:\(callback.port)"

        // 3. Build + open the Google auth URL in default browser.
        var authComponents = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
        authComponents.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // `access_type=offline` is what produces a refresh_token.
            // Without it Google returns an access token only and
            // Daisy would have to re-prompt every hour.
            URLQueryItem(name: "access_type", value: "offline"),
            // `prompt=consent` forces Google to issue a refresh token
            // even if the user already authorized Daisy in a previous
            // session. Without it, repeat-connect flows hand back an
            // access token with no refresh token — silently breaking
            // long-term auth.
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let authURL = authComponents.url else {
            throw OAuthError.browserLaunchFailed
        }

        log.info("Opening Google OAuth in browser, listener on :\(callback.port, privacy: .public)")
        guard NSWorkspace.shared.open(authURL) else {
            throw OAuthError.browserLaunchFailed
        }

        // 4. Wait for the browser redirect (with timeout).
        let params = try await callback.awaitCallback(timeoutSeconds: 120)

        // 5. Verify state, extract code.
        guard params["state"] == state else {
            log.error("State mismatch — possible CSRF")
            throw OAuthError.stateMismatch
        }
        if let error = params["error"] {
            log.warning("Google returned error: \(error, privacy: .public)")
            throw OAuthError.missingCode(error)
        }
        guard let code = params["code"], !code.isEmpty else {
            throw OAuthError.missingCode(nil)
        }

        // 6. Exchange code for tokens (POST form-urlencoded).
        let tokens = try await exchangeCodeForTokens(
            code: code,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI
        )
        let expiresAt = Date().addingTimeInterval(TimeInterval(tokens.expires_in - 60))
        // -60s safety margin so we refresh slightly before Google
        // expires the token; saves a 401 round-trip.

        // Verify the user actually granted Calendar — Google's
        // consent screen presents each requested scope as a
        // separate checkbox, and if the user unticks the Calendar
        // one, OAuth still "succeeds" with the remaining scopes.
        // Without this check Daisy would happily save tokens that
        // can't fetch a single event.
        let grantedScopes = Set((tokens.scope ?? "").split(separator: " ").map(String.init))
        guard grantedScopes.contains(Self.requiredScope) else {
            log.warning("Google OAuth completed but calendar.readonly scope wasn't granted (got: \(tokens.scope ?? "<nil>", privacy: .public))")
            // Don't save the partial token — surface to the user
            // so they re-consent with the right checkbox ticked.
            if let refresh = tokens.refresh_token {
                await Self.revoke(refreshToken: refresh)
            }
            throw OAuthError.calendarScopeNotGranted
        }

        guard let refresh = tokens.refresh_token else {
            // We forced `prompt=consent` so Google should always
            // emit a refresh_token here. If it didn't, something
            // is wrong with the consent screen config.
            throw OAuthError.tokenExchangeFailed("Google didn't return a refresh_token — check OAuth consent screen config (must request offline access).")
        }

        // 7. Fetch user email for display.
        let email = try await fetchEmail(accessToken: tokens.access_token)

        return ConnectResult(
            accessToken: tokens.access_token,
            refreshToken: refresh,
            expiresAt: expiresAt,
            email: email
        )
    }

    /// Refresh an access token using a stored refresh token.
    /// Returns the new access token + its expiry. The refresh
    /// token itself doesn't change.
    static func refreshAccessToken(refreshToken: String) async throws -> (accessToken: String, expiresAt: Date) {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = Self.formEncode([
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "no body"
            throw OAuthError.refreshFailed(msg)
        }
        struct RefreshResponse: Decodable {
            let access_token: String
            let expires_in: Int
        }
        let parsed = try JSONDecoder().decode(RefreshResponse.self, from: data)
        let expiresAt = Date().addingTimeInterval(TimeInterval(parsed.expires_in - 60))
        return (parsed.access_token, expiresAt)
    }

    /// Revoke a refresh token at Google's end. Called when user
    /// hits "Disconnect" — without this, Google still considers
    /// Daisy authorized, the OAuth consent page never re-appears,
    /// and a partial reconnect could silently inherit stale state.
    /// Network failures are ignored; we still wipe local tokens.
    static func revoke(refreshToken: String) async {
        var components = URLComponents(url: revokeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: refreshToken)]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Private — token exchange + userinfo

    private static func exchangeCodeForTokens(
        code: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> TokenResponse {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = Self.formEncode([
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ])
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "no body"
            throw OAuthError.tokenExchangeFailed(msg)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func fetchEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: userInfoEndpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? "no body"
                throw OAuthError.userInfoFailed(msg)
            }
            let info = try JSONDecoder().decode(UserInfo.self, from: data)
            return info.email
        } catch let error as OAuthError {
            throw error
        } catch {
            throw OAuthError.userInfoFailed(error.localizedDescription)
        }
    }

    // MARK: - Private — PKCE helpers

    /// Generate a cryptographically random URL-safe string of the
    /// requested character length. Used for both `code_verifier`
    /// (which must be ≥43 chars per PKCE spec) and `state` nonce.
    /// Uses `SecRandomCopyBytes` (kernel-level CSPRNG) so the value
    /// is suitable for security-sensitive flows; `Int.random` would
    /// also work in practice but is weaker.
    private static func randomURLSafeString(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        if status != errSecSuccess {
            // Fallback to Swift's system RNG if Security framework
            // rejected us — practically impossible on Apple Silicon,
            // but better than crashing if it ever happens.
            return String((0..<length).map { _ in alphabet.randomElement()! })
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    /// SHA-256 → base64url(no padding) of the verifier. This is
    /// the `code_challenge` Daisy embeds in the auth URL.
    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let data = Data(digest)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// form-urlencoded body, percent-escaping per RFC 3986.
    /// Foundation's `URLComponents` would do this but only inside a
    /// URL — for a request body we build the string directly.
    private static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        // URL-encoded form values must escape '&', '+', '=' even
        // though `urlQueryAllowed` lets them through.
        allowed.remove(charactersIn: "&+=")
        return params
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}

// MARK: - Loopback HTTP callback listener
//
// Minimal TCP+HTTP one-shot listener using NWListener. Binds to
// 127.0.0.1 only on an ephemeral port. The first complete HTTP
// request line is parsed for `code` / `state` / `error` query
// params; everything else (headers, body) is ignored. After
// responding with a small HTML success page we shut down.
//
// Why NWListener vs CFSocket / Foundation HTTPServer:
//  - NWListener is the modern Network.framework primitive, comes
//    with macOS 10.14+ — no extra dependency.
//  - We don't need Vapor / SwiftNIO; the OAuth callback is one
//    request, ≤2 KB, no real HTTP parsing required.
//  - Sandbox: requires `network.server` entitlement (Daisy already
//    has it for the local MCP server).

private final class CallbackListener: @unchecked Sendable {
    let port: UInt16
    // `listener` and `paramsPromise` are immutable `let`s of types
    // that are already Sendable (NWListener is Sendable since macOS
    // 14; AsyncThrowingPromise is declared @unchecked Sendable
    // below). No isolation opt-out needed — Swift figures it out.
    private let listener: NWListener
    private let paramsPromise: AsyncThrowingPromise<[String: String]>

    private init(listener: NWListener, port: UInt16, paramsPromise: AsyncThrowingPromise<[String: String]>) {
        self.listener = listener
        self.port = port
        self.paramsPromise = paramsPromise
    }

    /// Spin up the listener on an OS-assigned port. Both
    /// stateUpdateHandler AND newConnectionHandler are wired up
    /// BEFORE `listener.start()` — this closes the race window
    /// where Google could redirect to localhost before we'd attached
    /// the connection handler, and silences NWListener's
    /// "Started without setting … connection handler" warning.
    @MainActor
    static func start() async throws -> CallbackListener {
        let parameters = NWParameters.tcp
        // Bind to loopback only — external hosts must not be able
        // to deliver an OAuth callback to us.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw GoogleOAuthClient.OAuthError.listenerFailed(error.localizedDescription)
        }

        let portPromise = AsyncThrowingPromise<UInt16>()
        let paramsPromise = AsyncThrowingPromise<[String: String]>()

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard let port = listener.port?.rawValue else {
                    portPromise.fail(GoogleOAuthClient.OAuthError.listenerFailed("listener ready but no port"))
                    return
                }
                portPromise.fulfill(port)
            case .failed(let error):
                portPromise.fail(GoogleOAuthClient.OAuthError.listenerFailed(error.localizedDescription))
            default:
                break
            }
        }

        listener.newConnectionHandler = { connection in
            // First-callback-wins: the promise's lock dedups so
            // subsequent connections (rare; browsers sometimes
            // probe with a duplicate request) are no-ops.
            Self.serveCallback(on: connection, fulfilling: paramsPromise)
        }

        listener.start(queue: .main)
        let port = try await portPromise.value
        return CallbackListener(listener: listener, port: port, paramsPromise: paramsPromise)
    }

    /// Wait for the OAuth callback to arrive (or timeout). The
    /// listener has been delivering connections to `paramsPromise`
    /// since `start()`; this method just races the promise against
    /// a sleep.
    @MainActor
    func awaitCallback(timeoutSeconds: Int) async throws -> [String: String] {
        // Race awaiting the params against a timeout. Whichever
        // finishes first wins; the loser is ignored thanks to the
        // promise's once-only semantics.
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { [paramsPromise] in
                try await paramsPromise.value
            }
            group.addTask { [paramsPromise] in
                try await Task.sleep(for: .seconds(timeoutSeconds))
                paramsPromise.fail(GoogleOAuthClient.OAuthError.timedOut)
                throw GoogleOAuthClient.OAuthError.timedOut
            }
            // First successful or thrown result; cancel siblings.
            guard let first = try await group.next() else {
                throw GoogleOAuthClient.OAuthError.timedOut
            }
            group.cancelAll()
            return first
        }
    }

    nonisolated func stop() {
        listener.cancel()
    }

    // MARK: - Connection handling
    //
    // All connection-handling is now `static` because the listener's
    // newConnectionHandler is set BEFORE the `CallbackListener`
    // instance exists. The handler closure captures the
    // `paramsPromise` directly (not `self`) and writes there; the
    // outer instance reads from the same promise via awaitCallback.

    nonisolated static func serveCallback(
        on connection: NWConnection,
        fulfilling paramsPromise: AsyncThrowingPromise<[String: String]>
    ) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, error in
            defer { connection.cancel() }
            if let error {
                paramsPromise.fail(GoogleOAuthClient.OAuthError.listenerFailed(error.localizedDescription))
                return
            }
            guard let data, let raw = String(data: data, encoding: .utf8) else {
                paramsPromise.fail(GoogleOAuthClient.OAuthError.listenerFailed("empty request"))
                return
            }
            let params = parseQueryParams(fromHTTPRequest: raw)
            // Send a friendly HTML page back so the browser shows
            // "you can close this tab" instead of a blank page.
            let html = Self.successHTML
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(html.utf8.count)\r
            Connection: close\r
            \r
            \(html)
            """
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })
            paramsPromise.fulfill(params)
        }
    }

    // MARK: - HTTP request → query params

    /// Crude HTTP request line parser: pulls the first line, splits
    /// out the path, returns the query items as a dictionary. We
    /// don't validate Host / headers / verb — this is a one-shot
    /// throwaway server on localhost.
    private static func parseQueryParams(fromHTTPRequest raw: String) -> [String: String] {
        guard let firstLine = raw.split(separator: "\r\n").first else { return [:] }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return [:] }
        let target = String(parts[1])  // e.g. "/?code=...&state=..."
        // Pad with scheme + host so URLComponents parses the query.
        guard let comps = URLComponents(string: "http://localhost\(target)") else { return [:] }
        var out: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            out[item.name] = item.value
        }
        return out
    }

    /// HTML returned to the browser after successful callback. Tells
    /// the user to come back to Daisy + auto-closes the tab where
    /// the browser allows it (most don't, due to security policy).
    ///
    /// The SVG mark is hand-inlined here (rather than referencing
    /// an asset) so the success page is a single self-contained
    /// HTTP response — no extra `/daisy.svg` request, no asset
    /// pipeline. Geometry is Daisy B+, as `BrandLogo.tsx` on the
    /// website and `DaisyMark.imageset` in-app draw it: eight ink
    /// teardrop petals and the favicon's amber core.
    static let successHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>Daisy — Connected</title>
      <style>
        body {
          margin: 0;
          padding: 0;
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          background: #faf7f0;
          color: #1c1a17;
          display: flex;
          align-items: center;
          justify-content: center;
          min-height: 100vh;
        }
        .card {
          max-width: 420px;
          text-align: center;
          padding: 48px 32px;
        }
        .mark {
          width: 56px;
          height: 56px;
          margin: 0 auto 24px;
          display: block;
        }
        h1 { font-size: 22px; font-weight: 600; margin: 0 0 12px; }
        p { font-size: 15px; color: #6c6962; margin: 0 0 24px; line-height: 1.5; }
        .btn {
          display: inline-block;
          background: #1c1a17;
          color: #faf7f0;
          border: 0;
          border-radius: 10px;
          padding: 10px 20px;
          font: 500 14px/1 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          cursor: pointer;
          text-decoration: none;
        }
        .btn:hover { opacity: 0.9; }
      </style>
    </head>
    <body>
      <div class="card">
        <svg class="mark" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
          <defs><path id="petal" d="M 50,35.8 C 46.75,35.8 44.9,31.3 43.4,26.1 C 42.05,21.35 40.15,17.5 42.25,13.1 C 43.8,9.9 46.65,8 50,8 C 53.35,8 56.2,9.9 57.75,13.1 C 59.85,17.5 57.95,21.35 56.6,26.1 C 55.1,31.3 53.25,35.8 50,35.8 Z"/></defs>
          <g fill="#1c1a17">
            <use href="#petal" transform="rotate(0 50 50)"/>
            <use href="#petal" transform="rotate(45 50 50)"/>
            <use href="#petal" transform="rotate(90 50 50)"/>
            <use href="#petal" transform="rotate(135 50 50)"/>
            <use href="#petal" transform="rotate(180 50 50)"/>
            <use href="#petal" transform="rotate(225 50 50)"/>
            <use href="#petal" transform="rotate(270 50 50)"/>
            <use href="#petal" transform="rotate(315 50 50)"/>
          </g>
          <circle cx="50" cy="50" r="10.5" fill="#F4A623"/>
        </svg>
        <h1>Daisy connected to Google Calendar</h1>
        <p>You can close this tab and return to Daisy.</p>
        <button class="btn" onclick="window.close()">Close this tab</button>
      </div>
      <!--
        Auto-close after 1.2s for browsers that permit it.
        Many modern browsers block window.close() on tabs the user
        opened directly (security policy) — that's why the explicit
        button above exists. Users without auto-close still get a
        clear single-click path back to Daisy.
      -->
      <script>setTimeout(() => window.close(), 1200);</script>
    </body>
    </html>
    """
}

// MARK: - Tiny async promise primitive
//
// We need to await the listener's `.ready` state from an outside
// async context. CheckedContinuation does that but can't be re-
// resolved if the state changes again — wrap it in a small promise
// type so stateUpdateHandler can fulfill / fail exactly once.

private final class AsyncThrowingPromise<T: Sendable>: @unchecked Sendable {
    // `nonisolated(unsafe)` because fulfill/fail are called from
    // arbitrary callback queues (NWListener stateUpdateHandler).
    // The NSLock below serializes access; compiler can't infer
    // that through default-MainActor isolation, so we opt out.
    nonisolated(unsafe) private var continuation: CheckedContinuation<T, Error>?
    nonisolated(unsafe) private var resolved = false
    nonisolated(unsafe) private var pending: (Result<T, Error>)?
    private let lock = NSLock()

    nonisolated var value: T {
        get async throws {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if let pending {
                    resolved = true
                    lock.unlock()
                    cont.resume(with: pending)
                } else {
                    continuation = cont
                    lock.unlock()
                }
            }
        }
    }

    // fulfill / fail are called from non-isolated NWListener
    // callbacks. Mark `nonisolated` to opt out of the project's
    // default-MainActor isolation rule; lock protects internal state.

    nonisolated func fulfill(_ value: T) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        if let cont = continuation {
            resolved = true
            continuation = nil
            lock.unlock()
            cont.resume(returning: value)
        } else {
            pending = .success(value)
            lock.unlock()
        }
    }

    nonisolated func fail(_ error: Error) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        if let cont = continuation {
            resolved = true
            continuation = nil
            lock.unlock()
            cont.resume(throwing: error)
        } else {
            pending = .failure(error)
            lock.unlock()
        }
    }
}
