//
//  SubscriptionLookTests.swift
//  DaisyTests
//
//  A way to look at the Daisy Subscription rows of Settings in each state,
//  and at the sign-in sheet, without running a second Daisy beside the
//  person's own (same preferences, keychain and hotkeys): it draws them into
//  PNG files. Does nothing in a normal run — only with a folder to write to:
//
//    TEST_RUNNER_DAISY_LOOK_DIR=/path/to/folder xcodebuild test … \
//      -testLanguage ru -only-testing:DaisyTests/SubscriptionLookTests
//
//  Found this way on 27.11: price buttons with no label, the email prompt
//  drawn as a link, two primary buttons side by side.
//

import AppKit
import SwiftUI
import Testing
@testable import Daisy

/// Its own stub, answering by path. Not DaisySubscriptionTests' one: the
/// suites run side by side, and a shared stub hands one suite's answers to
/// the other's requests. And not a queue: the rows ask for the account and
/// the subscription themselves when drawn, at a moment of their own, so
/// an answer has to belong to a question, not to a turn.
final class SubscriptionLookStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: (status: Int, body: String)] = [:]

    /// The answers by the path's last component («subscription», «checkout»);
    /// any other path gets a 500.
    static func answer(_ answers: [String: (Int, String)]) {
        lock.withLock { Self.answers = answers.mapValues { (status: $0.0, body: $0.1) } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.lastPathComponent ?? ""
        let next = Self.lock.withLock { Self.answers[path] } ?? (status: 500, body: "no stub")
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Subscription look", .serialized)
@MainActor
struct SubscriptionLookTests {
    private let scratch = ScratchDefaults("SubscriptionLook")

    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["DAISY_LOOK_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func stubSession(_ answers: [String: (Int, String)]) -> URLSession {
        SubscriptionLookStub.answer(answers)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SubscriptionLookStub.self]
        return URLSession(configuration: config)
    }

    private func store(signedIn: Bool, consented: Bool, status: (Int, String)?) async -> DaisyAccountStore {
        let store = DaisyAccountStore(
            session: stubSession(status.map { ["subscription": $0] } ?? [:]),
            defaults: scratch.make(),
            readStored: false,
            restoring: signedIn
                ? (token: "s1.session.sig", account: DaisyAccountInfo(id: "acct", email: "anna@example.com", providers: ["email"]))
                : nil)
        if consented { store.acknowledgeCloudDisclosure() }
        if signedIn, status != nil { await store.refreshSubscription() }
        return store
    }

    private func write<V: View>(_ view: V, name: String, size: CGSize, scheme: ColorScheme) throws {
        guard let directory = outputDirectory else { return }
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let hosting = NSHostingView(rootView: view
            .environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height)
            .background(Color.daisyBgPrimary))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("\(name)-\(language)-\(scheme == .dark ? "dark" : "light").png"))
    }

    private func rows(_ store: DaisyAccountStore) -> some View {
        Form {
            Section("Summary") {
                LabeledContent("Provider") { Text("Daisy Subscription") }
                DaisySubscriptionRows(store: store) {}
            }
        }
        .formStyle(.grouped)
    }

    @Test func drawEveryState() async throws {
        guard outputDirectory != nil else { return }
        let active = #"{"active":true,"sources":[{"source":"web","renewsAt":"2026-12-27T12:00:00.000Z","willRenew":true,"manageUrl":"https://whop.com/billing/manage/mber_x/"}],"trialRemaining":0}"#
        let appStore = #"{"active":true,"sources":[{"source":"appstore","renewsAt":"2026-12-27T12:00:00.000Z","manageUrl":"https://apps.apple.com/account/subscriptions"}],"trialRemaining":0}"#
        let free = #"{"active":false,"sources":[],"trialRemaining":2}"#
        let used = #"{"active":false,"sources":[],"trialRemaining":0}"#
        let states: [(String, Bool, Bool, (Int, String)?)] = [
            ("1-signed-out", false, false, nil),
            ("2-no-consent", true, false, (200, free)),
            ("3-free", true, true, (200, free)),
            ("4-free-used", true, true, (200, used)),
            ("5-active-web", true, true, (200, active)),
            ("6-active-appstore", true, true, (200, appStore)),
            ("7-server-down", true, true, (500, "oops")),
        ]
        for (name, signedIn, consented, status) in states {
            let store = await store(signedIn: signedIn, consented: consented, status: status)
            for scheme in [ColorScheme.light, .dark] {
                try write(rows(store), name: name, size: CGSize(width: 640, height: 330), scheme: scheme)
            }
        }
        // Waiting for a payment: a checkout opened (into nothing) and not paid.
        let waiting = DaisyAccountStore(
            session: stubSession(["subscription": (200, free), "checkout": (200, #"{"url":"https://whop.com/checkout/plan_x"}"#)]),
            defaults: scratch.make(), readStored: false,
            restoring: (token: "s1.session.sig", account: DaisyAccountInfo(id: "acct", email: "anna@example.com", providers: ["email"])),
            openInBrowser: { _ in },
            pollInterval: .seconds(600))
        waiting.acknowledgeCloudDisclosure()
        await waiting.refreshSubscription()
        try await waiting.checkout(.year)
        for scheme in [ColorScheme.light, .dark] {
            try write(rows(waiting), name: "9-waiting", size: CGSize(width: 640, height: 330), scheme: scheme)
        }
        waiting.stopWaitingForPayment()
        let signedOut = await store(signedIn: false, consented: true, status: nil)
        for scheme in [ColorScheme.light, .dark] {
            try write(DaisySubscriptionRows.signInSheetForInspection(store: signedOut), name: "8-sign-in", size: CGSize(width: 420, height: 380), scheme: scheme)
        }
    }
}
