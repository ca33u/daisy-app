//
//  DaisyAccount.swift
//  Daisy
//
//  The Daisy account on the Mac (27.11, plan «Одна подписка Daisy», С-3):
//  sign in with an email code, Google or Apple — the same account as on the
//  iPhone — and the Daisy Subscription that belongs to it, bought in the
//  App Store on the iPhone or on mydaisy.io through Whop. The server is
//  daisy-api: src/account.ts (signing in), src/subscription.ts (the
//  status, the checkout).
//
//  Kept on this Mac: our session token, in the keychain under a service of
//  its own, never synchronizable — each device signs in, and turning
//  iCloud sync on must not carry a session to another Mac (KeychainStore's
//  items follow that switch, so the token is not one of them). The
//  account's id, email and ways in sit in UserDefaults, to show who is
//  signed in. Nothing else.
//
//  Recording, transcription and every free provider work without it. The
//  account is only for «Подписка Daisy» as the summary provider.
//

import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
import os

// MARK: - What the server says

nonisolated struct DaisyAccountInfo: Codable, Equatable, Sendable {
    let id: String
    let email: String?
    let providers: [String]

    static func parse(_ json: [String: Any]?) -> DaisyAccountInfo? {
        guard let raw = json?["account"] as? [String: Any], let id = raw["id"] as? String else { return nil }
        return DaisyAccountInfo(id: id, email: raw["email"] as? String, providers: raw["providers"] as? [String] ?? [])
    }
}

/// GET /v1/subscription: `{active, sources:[{source, renewsAt, willRenew?, manageUrl?}], trialRemaining}`.
nonisolated struct DaisySubscriptionStatus: Equatable, Sendable {
    nonisolated struct Source: Equatable, Sendable {
        enum Kind: String, Sendable { case appStore = "appstore", web }
        let kind: Kind
        let renewsAt: Date?
        let willRenew: Bool?
        let manageURL: URL?
    }

    let active: Bool
    let sources: [Source]
    let trialRemaining: Int

    /// Bought on the website: its own page manages it. Otherwise the App Store's.
    var primary: Source? { sources.first { $0.kind == .web } ?? sources.first }

    static func parse(_ json: [String: Any]?) -> DaisySubscriptionStatus? {
        guard let json, let active = json["active"] as? Bool else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let sources: [Source] = (json["sources"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let kind = (raw["source"] as? String).flatMap(Source.Kind.init(rawValue:)) else { return nil }
            let date = (raw["renewsAt"] as? String).flatMap { iso.date(from: $0) ?? plain.date(from: $0) }
            let manage = (raw["manageUrl"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
            return Source(kind: kind, renewsAt: date, willRenew: raw["willRenew"] as? Bool, manageURL: manage)
        }
        return DaisySubscriptionStatus(active: active, sources: sources,
                                       trialRemaining: max(0, json["trialRemaining"] as? Int ?? 0))
    }
}

nonisolated enum DaisyAccountFailure: LocalizedError, Equatable, Sendable {
    case unavailable
    case invalidToken
    case badEmail
    case tooManyCodes
    case wrongCode(triesLeft: Int)
    case codeExpired
    case signedOut
    case alreadySubscribed
    case checkoutUnavailable
    case tooManyTries
    case notSaved
    case server

    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "Signing in isn't available right now. Try again later")
        case .invalidToken: String(localized: "Couldn't sign in. Try again")
        case .badEmail: String(localized: "Check the email address")
        case .tooManyCodes: String(localized: "Too many codes for this address. Try again in an hour")
        case .wrongCode(let left): String(localized: "Wrong code. Tries left: \(left)")
        case .codeExpired: String(localized: "The code has expired. Ask for a new one")
        case .signedOut: String(localized: "You're signed out of Daisy. Sign in again")
        case .alreadySubscribed: String(localized: "This account already has a Daisy Subscription")
        case .checkoutUnavailable: String(localized: "Buying on the website isn't available yet")
        case .tooManyTries: String(localized: "Too many tries. Wait a minute and try again")
        case .notSaved: String(localized: "Signed in, but this Mac's keychain refused to keep it. Try again")
        case .server: String(localized: "Daisy's server can't be reached. Try again")
        }
    }

    static func from(status: Int, json: [String: Any]?) -> DaisyAccountFailure {
        switch json?["error"] as? String {
        case "unavailable": .unavailable
        case "invalid_token": .invalidToken
        case "bad_email": .badEmail
        case "too_many_codes": .tooManyCodes
        case "wrong_code": .wrongCode(triesLeft: json?["triesLeft"] as? Int ?? 0)
        case "code_expired": .codeExpired
        case "invalid_session", "session_expired": .signedOut
        case "already_subscribed": .alreadySubscribed
        case "not_found": .checkoutUnavailable
        case "rate_limit": .tooManyTries
        default: status == 401 ? .signedOut : status == 503 ? .unavailable : status == 429 ? .tooManyTries : .server
        }
    }
}

// MARK: - The session token's own keychain item

/// Not `KeychainStore`: its items follow the iCloud sync switch, and a
/// session must stay on the Mac that signed in. Data protection keychain,
/// the app's group, never synchronizable, this device only — or, on a build
/// signed without the keychain group (errSecMissingEntitlement), the login
/// keychain, which never syncs. The test host keeps it in memory.
nonisolated enum DaisySessionKeychain {
    private static let service = "app.essazanov.Daisy.account"
    private static let account = "session"
    private static let memory = OSAllocatedUnfairLock<String?>(initialState: nil)

    private static func query(legacy: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if !legacy {
            q[kSecUseDataProtectionKeychain as String] = true
            q[kSecAttrAccessGroup as String] = KeychainStore.accessGroup
            q[kSecAttrSynchronizable as String] = false
        }
        return q
    }

    /// The login keychain only where `write` used it: a build the data
    /// protection keychain refused. Read at launch, on the main thread, and
    /// the login keychain can raise a dialog (KeychainStore's header).
    static func read() -> String? {
        if TestHost.isActive { return memory.withLock { $0 } }
        let (value, status) = read(legacy: false)
        if value != nil { return value }
        guard status == errSecMissingEntitlement || status == errSecNoAccessForItem else { return nil }
        return read(legacy: true).value
    }

    private static func read(legacy: Bool) -> (value: String?, status: OSStatus) {
        var q = query(legacy: legacy)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return (nil, status) }
        return (String(data: data, encoding: .utf8), status)
    }

    /// False when neither keychain took it.
    static func write(_ token: String) -> Bool {
        if TestHost.isActive { memory.withLock { $0 = token }; return true }
        delete()
        var q = query(legacy: false)
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecSuccess { return true }
        guard status == errSecMissingEntitlement || status == errSecNoAccessForItem else { return false }
        var legacy = query(legacy: true)
        legacy[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(legacy as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        if TestHost.isActive { memory.withLock { $0 = nil }; return }
        SecItemDelete(query(legacy: false) as CFDictionary)
        SecItemDelete(query(legacy: true) as CFDictionary)
    }
}

// MARK: - The account

@MainActor
@Observable
final class DaisyAccountStore {
    static let shared = DaisyAccountStore()

    static let base = URL(string: "https://api.mydaisy.io/v1")!
    /// How long a checkout is waited for, asking every `pollInterval`.
    static let paymentWait: Duration = .seconds(600)
    static let pollInterval: Duration = .seconds(3)

    enum Plan: String, Sendable { case month, year }

    private(set) var account: DaisyAccountInfo? {
        didSet {
            defaults.set(account.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.accountKey)
        }
    }
    private(set) var sessionToken: String?
    var isSignedIn: Bool { sessionToken != nil && account != nil }

    /// The last answer from GET /v1/subscription, and when it came.
    private(set) var subscription: DaisySubscriptionStatus?
    private(set) var subscriptionCheckedAt: Date?
    /// The last check failed without an answer: the server couldn't be reached.
    private(set) var subscriptionCheckFailed = false
    /// A checkout was opened and its payment is not seen yet.
    private(set) var awaitingPayment = false
    /// That checkout's page, to open again: the browser tab may have been
    /// closed before paying (Egor 27.11: closed it, and Settings only span).
    private(set) var pendingCheckout: URL?

    /// Signed in, signed out or the subscription changed: Summarizer asks
    /// the provider again.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    /// A payment was seen while its wait was still showing: paid from the
    /// rows in Settings, and not called off. The app then writes summaries
    /// on the subscription; a payment seen any other way (after Cancel, on
    /// a later launch) leaves that switch to the person.
    @ObservationIgnored var onPaid: (@MainActor () -> Void)?

    @ObservationIgnored private let session: URLSession
    /// Opens a page in the browser; a test's own in tests.
    @ObservationIgnored private let openInBrowser: @MainActor (URL) -> Void
    /// Tests only: the provider under test shares the account's stubbed session.
    nonisolated var urlSessionForTests: URLSession { session }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Reads of the status, numbered: Cancel's read runs beside the quiet
    /// asking, and an older answer must not replace a newer one.
    @ObservationIgnored private var subscriptionRead = 0
    @ObservationIgnored private var subscriptionReadApplied = 0
    /// `paymentWait` and `pollInterval`, shorter in a test.
    @ObservationIgnored private let waitsFor: Duration
    @ObservationIgnored private let asksEvery: Duration
    @ObservationIgnored private let log = Logger(subsystem: "app.essazanov.Daisy", category: "DaisyAccount")
    private static let accountKey = "daisy.account"
    private static let disclosureKey = "daisy.account.cloudDisclosureAcknowledged"

    /// The yes to «Send text through Daisy's server?», asked before the
    /// first sign-in (27.11): with this provider the text of meetings and
    /// dictations goes to our server, and nothing goes there unasked. The
    /// provider sends nothing without it.
    /// Kept across sign-out (an expired session must not take it back, as
    /// the ChatGPT account's isn't); a deleted account takes it along.
    private(set) var hasAcknowledgedCloudDisclosure = false

    func acknowledgeCloudDisclosure() {
        guard !hasAcknowledgedCloudDisclosure else { return }
        defaults.set(true, forKey: Self.disclosureKey)
        hasAcknowledgedCloudDisclosure = true
        onChange?()
    }

    /// `restoring`: tests only — a store that is already signed in, without
    /// the keychain.
    init(session: URLSession = .shared, defaults: UserDefaults = .standard, readStored: Bool = !TestHost.isActive,
         restoring: (token: String, account: DaisyAccountInfo)? = nil,
         openInBrowser: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
         paymentWait: Duration = DaisyAccountStore.paymentWait,
         pollInterval: Duration = DaisyAccountStore.pollInterval) {
        self.session = session
        self.openInBrowser = openInBrowser
        waitsFor = paymentWait
        asksEvery = pollInterval
        self.defaults = defaults
        hasAcknowledgedCloudDisclosure = defaults.bool(forKey: Self.disclosureKey)
        if let restoring {
            sessionToken = restoring.token
            account = restoring.account
            return
        }
        guard readStored else { return }
        sessionToken = DaisySessionKeychain.read()
        if let data = defaults.data(forKey: Self.accountKey) {
            account = try? JSONDecoder().decode(DaisyAccountInfo.self, from: data)
        }
        if sessionToken == nil { account = nil }
    }

    // MARK: Ways in

    /// Sends a six-digit code to the address.
    func startEmail(_ email: String) async throws {
        let language = Locale.preferredLanguages.first ?? "en"
        let (status, json) = try await call("auth/email/start", method: "POST",
                                            body: ["email": email, "language": language])
        guard status == 200 else { throw DaisyAccountFailure.from(status: status, json: json) }
    }

    func verifyEmail(_ email: String, code: String) async throws {
        try await signIn(path: "auth/email/verify", body: ["email": email, "code": code])
    }

    /// Google in the browser (GoogleOAuthClient.signInIDToken). False when
    /// the person closed it or said no.
    @discardableResult
    func signInWithGoogle() async throws -> Bool {
        guard let idToken = try await GoogleOAuthClient.signInIDToken() else { return false }
        try await signIn(path: "auth/google", body: ["idToken": idToken])
        return true
    }

    /// Apple: the identity token and code from `ASAuthorizationAppleIDCredential`,
    /// and the raw nonce whose SHA-256 the request carried.
    func signInWithApple(identityToken: String, authorizationCode: String?, rawNonce: String) async throws {
        var body: [String: Any] = ["identityToken": identityToken, "nonce": rawNonce]
        if let authorizationCode { body["authorizationCode"] = authorizationCode }
        try await signIn(path: "auth/apple", body: body)
    }

    /// Sign in with Apple needs `com.apple.developer.applesignin` in the
    /// signature, which the Developer ID profile carries only once the
    /// capability is on for app.essazanov.Daisy. Until then the button is
    /// not shown rather than failing with Apple's error 1000.
    nonisolated static var appleSignInAvailable: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.applesignin" as CFString, nil) != nil
    }

    // MARK: The account

    /// Asks the server who this is; a session it no longer accepts signs out.
    func refreshAccount() async {
        guard let sessionToken else { return }
        guard let (status, json) = try? await call("account", method: "GET", bearer: sessionToken) else { return }
        if status == 401 { signOut(); return }
        if status == 200, let account = DaisyAccountInfo.parse(json) { self.account = account }
    }

    func signOut() {
        // A wait for a payment ends with the session that started it.
        stopWaitingForPayment()
        DaisySessionKeychain.delete()
        sessionToken = nil
        account = nil
        subscription = nil
        subscriptionCheckedAt = nil
        subscriptionCheckFailed = false
        awaitingPayment = false
        log.info("Signed out")
        onChange?()
    }

    /// Deletes the account on the server, then signs out here. A paid
    /// subscription is not cancelled by this — the confirmation says so.
    func deleteAccount() async throws {
        guard let sessionToken else { return }
        let (status, json) = try await call("account", method: "DELETE", bearer: sessionToken)
        guard status == 200 || status == 401 else { throw DaisyAccountFailure.from(status: status, json: json) }
        // The next sign-in is a new account: it is asked again.
        defaults.removeObject(forKey: Self.disclosureKey)
        hasAcknowledgedCloudDisclosure = false
        signOut()
    }

    // MARK: The subscription

    /// GET /v1/subscription. A session the server refuses signs out; no
    /// answer keeps the last status and marks the check as failed.
    @discardableResult
    func refreshSubscription() async -> DaisySubscriptionStatus? {
        guard let sessionToken else { return nil }
        subscriptionRead &+= 1
        let read = subscriptionRead
        let reply: (Int, [String: Any]?)
        do {
            reply = try await call("subscription", method: "GET", bearer: sessionToken)
        } catch {
            // A check given up (Settings closed) says nothing about the
            // server; neither does one whose session is gone meanwhile.
            if !Task.isCancelled, self.sessionToken == sessionToken { subscriptionCheckFailed = true }
            return nil
        }
        // An answer about a session that is no longer this store's (signed
        // out, or another account signed in while it was on its way) is
        // nobody's status here.
        guard self.sessionToken == sessionToken else { return nil }
        let (status, json) = reply
        if status == 401 { signOut(); return nil }
        guard status == 200, let parsed = DaisySubscriptionStatus.parse(json) else {
            subscriptionCheckFailed = true
            return nil
        }
        // An answer to an older read than one already applied is dropped.
        guard read > subscriptionReadApplied else { return subscription }
        subscriptionReadApplied = read
        let changed = parsed != subscription
        subscription = parsed
        subscriptionCheckedAt = Date()
        subscriptionCheckFailed = false
        if parsed.active { stopWaitingForPayment() }
        if changed { onChange?() }
        return parsed
    }

    /// The status for the provider's readiness: the last one if it is
    /// fresh, else asked again.
    func currentSubscription(maxAge: TimeInterval = 60) async -> DaisySubscriptionStatus? {
        if let subscription, let at = subscriptionCheckedAt, Date().timeIntervalSince(at) < maxAge { return subscription }
        return await refreshSubscription()
    }

    /// After a summary the server said how many free ones are left.
    func noteTrialRemaining(_ left: Int) {
        guard let subscription, !subscription.active, subscription.trialRemaining != left else { return }
        self.subscription = DaisySubscriptionStatus(active: false, sources: subscription.sources, trialRemaining: left)
        onChange?()
    }

    /// POST /v1/checkout, then the page in the browser, then waiting for the
    /// payment: asked every 3 s for ten minutes, and again whenever Settings
    /// opens or `daisy://subscription` comes back.
    func checkout(_ plan: Plan) async throws {
        guard let sessionToken else { throw DaisyAccountFailure.signedOut }
        let (status, json) = try await call("checkout", method: "POST", body: ["plan": plan.rawValue], bearer: sessionToken)
        // Signed out while the page was being made: it belongs to that
        // account, and a wait here would outlive its session.
        guard self.sessionToken == sessionToken else { throw DaisyAccountFailure.signedOut }
        if status == 409 {
            await refreshSubscription()
            throw DaisyAccountFailure.alreadySubscribed
        }
        guard status == 200, let raw = json?["url"] as? String, let url = URL(string: raw), url.scheme == "https" else {
            // Whop not (fully) set up on the server: about buying, not signing in.
            if status == 503 || status == 404 { throw DaisyAccountFailure.checkoutUnavailable }
            throw DaisyAccountFailure.from(status: status, json: json)
        }
        // Paid meanwhile (seen by the quiet asking while this was on its
        // way): no second page.
        if subscription?.active == true { throw DaisyAccountFailure.alreadySubscribed }
        ImprovementStats.record(.subscriptionCheckoutOpened)
        pendingCheckout = url
        openInBrowser(url)
        waitForPayment()
    }

    /// The same checkout page again, for a tab that was closed.
    func reopenCheckout() {
        guard awaitingPayment, let pendingCheckout else { return }
        openInBrowser(pendingCheckout)
    }

    /// Stops showing the wait: the person decided not to pay now. The
    /// status keeps being asked, quietly, until the same deadline. A
    /// payment made just before Cancel then shows as «Active» as soon as
    /// Whop reports it; one read here could miss it and leave the price
    /// buttons up for a second payment (review 27.11: the server refuses a
    /// second checkout only once the first membership is live).
    func cancelCheckout() async {
        awaitingPayment = false
        pendingCheckout = nil
        await refreshSubscription()
    }

    /// `daisy://subscription`: back from the website.
    func handleReturnLink(paymentFailed: Bool) {
        Task { await returnedFromCheckout(paymentFailed: paymentFailed) }
    }

    /// Back from the page that follows a payment. Whop may not have
    /// reported it yet, so the wait starts again, with its spinner, where
    /// one read could miss it. The page is not offered again: it was paid.
    /// By what the store knows, not by this one answer: a read that failed
    /// starts no wait for someone already subscribed.
    ///
    /// Back from a page that said the payment wasn't completed («try again
    /// from Daisy»): as Cancel. The prices come back, and a wait already
    /// running keeps asking quietly — the page can't know, and a charge
    /// that went through after all still shows. No wait is started.
    func returnedFromCheckout(paymentFailed: Bool = false) async {
        guard sessionToken != nil else { return }
        if paymentFailed {
            await cancelCheckout()
            return
        }
        pendingCheckout = nil
        await refreshSubscription()
        if sessionToken != nil, subscription?.active != true { waitForPayment() }
    }

    /// Ends the wait and its asking: the payment was seen, or the session
    /// is gone.
    func stopWaitingForPayment() {
        // Counted whether the wait was still shown or called off: the
        // payment came from a checkout opened here either way.
        let paid = subscription?.active == true
        let shown = awaitingPayment
        if pollTask != nil, paid {
            ImprovementStats.record(.subscriptionActivated)
        }
        pollTask?.cancel()
        pollTask = nil
        awaitingPayment = false
        pendingCheckout = nil
        if shown, paid { onPaid?() }
    }

    private func waitForPayment() {
        pollTask?.cancel()
        awaitingPayment = true
        let waitsFor = waitsFor, asksEvery = asksEvery
        pollTask = Task { [weak self] in
            let deadline = ContinuousClock.now + waitsFor
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: asksEvery)
                guard let self, !Task.isCancelled else { return }
                if await self.refreshSubscription()?.active == true { return }
            }
            // Replaced by a newer wait, or stopped: that one's state, not ours.
            guard !Task.isCancelled, let self else { return }
            self.pollTask = nil
            self.awaitingPayment = false
            self.pendingCheckout = nil
        }
    }

    // MARK: Helpers

    /// For Sign in with Apple: the raw nonce goes to our server, its
    /// SHA-256 (hex) into Apple's request and back in the token.
    nonisolated static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }

    nonisolated static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func signIn(path: String, body: [String: Any]) async throws {
        let (status, json) = try await call(path, method: "POST", body: body)
        guard status == 200, let token = json?["sessionToken"] as? String, let account = DaisyAccountInfo.parse(json) else {
            throw DaisyAccountFailure.from(status: status, json: json)
        }
        guard DaisySessionKeychain.write(token) else { throw DaisyAccountFailure.notSaved }
        sessionToken = token
        self.account = account
        log.info("Signed in (\(account.providers.joined(separator: ","), privacy: .public))")
        onChange?()
        await refreshSubscription()
    }

    private func call(_ path: String, method: String, body: [String: Any]? = nil,
                      bearer: String? = nil) async throws -> (Int, [String: Any]?) {
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 30
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization") }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            if Task.isCancelled { throw CancellationError() }
            throw DaisyAccountFailure.server
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
