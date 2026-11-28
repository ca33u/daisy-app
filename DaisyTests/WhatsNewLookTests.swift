// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  WhatsNewLookTests.swift
//  DaisyTests
//
//  A way to look at «What's New» — the Daisy Subscription's paywall — in
//  each of its states without running a second Daisy beside the person's
//  own: it draws the whole sheet into PNG files, as SubscriptionLookTests
//  does for the rows of Settings. Does nothing in a normal run — only with
//  a folder to write to:
//
//    TEST_RUNNER_DAISY_LOOK_DIR=/path/to/folder xcodebuild test … \
//      -testLanguage ru -testRegion RU -only-testing:DaisyTests/WhatsNewLookTests
//
//  The photograph is the app's own asset (the tests run inside Daisy.app),
//  so it is in the picture as it is in the window.
//

import AppKit
import SwiftUI
import Testing
@testable import Daisy

@Suite("What's New look")
@MainActor
struct WhatsNewLookTests {
    private let scratch = ScratchDefaults("WhatsNewLook")

    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["DAISY_LOOK_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The sheet at its own size: its width is fixed, its height is what
    /// its content takes.
    private func write(_ store: DaisyAccountStore, name: String, scheme: ColorScheme, maxHeight: CGFloat = .infinity) throws {
        guard let directory = outputDirectory else { return }
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let hosting = NSHostingView(rootView: WhatsNewSheet(store: store, maxHeight: maxHeight, switchOn: false, openSettings: {})
            .environment(\.colorScheme, scheme))
        let size = hosting.fittingSize
        #expect(size.width == WhatsNewSheet.width)
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
        try png.write(to: directory.appendingPathComponent("whatsnew-\(name)-\(language)-\(scheme == .dark ? "dark" : "light").png"))
    }

    @Test func drawEveryState() async throws {
        guard outputDirectory != nil else { return }
        let appStore = #"{"active":true,"sources":[{"source":"appstore","renewsAt":"2026-12-27T12:00:00.000Z","manageUrl":"https://apps.apple.com/account/subscriptions"}],"trialRemaining":0}"#
        let states: [(String, Bool, Bool, String?)] = [
            ("1-signed-out", false, false, nil),
            ("2-free", true, true, WhatsNewAccount.free),
            ("3-active", true, true, WhatsNewAccount.active),
            ("4-active-appstore", true, true, appStore),
            ("5-free-used", true, true, #"{"active":false,"sources":[],"trialRemaining":0}"#),
        ]
        for (name, signedIn, consented, status) in states {
            let account = await WhatsNewAccount(defaults: scratch.make(), signedIn: signedIn, consented: consented, status: status)
            for scheme in [ColorScheme.light, .dark] {
                try write(account.store, name: name, scheme: scheme)
            }
        }
        // A short display («Larger Text», a tall Dock): the feature rows
        // scroll under the photograph; the plans stay with the button.
        // Shorter still, the photograph gives up height. The same for a
        // subscriber's state and «Done».
        let short = await WhatsNewAccount(defaults: scratch.make(), signedIn: false, consented: false)
        let subscriber = await WhatsNewAccount(defaults: scratch.make(), signedIn: true, consented: true, status: WhatsNewAccount.active)
        for scheme in [ColorScheme.light, .dark] {
            try write(short.store, name: "6-short-display", scheme: scheme, maxHeight: 620)
            try write(short.store, name: "7-shortest-display", scheme: scheme, maxHeight: WhatsNewSheet.minimumHeight)
            try write(subscriber.store, name: "8-shortest-active", scheme: scheme, maxHeight: WhatsNewSheet.minimumHeight)
        }
        // In this run's language too: the block that never scrolls fits at the shortest limit.
        for store in [short.store, subscriber.store] {
            let fixed = NSHostingView(rootView: WhatsNewSheet(store: store, switchOn: false, openSettings: {}).fixedPartForInspection)
                .fittingSize.height
            #expect(WhatsNewSheet.heroMinimum + WhatsNewSheet.featuresMinimum + fixed <= WhatsNewSheet.minimumHeight, "\(fixed)")
        }
    }
}
