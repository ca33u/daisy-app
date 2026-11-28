//
//  AboutLegalTests.swift
//  DaisyTests
//
//  Daisy is under AGPL-3.0-only since 28.11.2026, and NOTICE.md at the
//  repository root says what the app shows about it: the author attribution
//  and the link to the source code among the legal notices of the About
//  window (its term 1). These hold the app to that file, so the two can't
//  drift: the attribution word for word, the copyright line, the license
//  row, and LICENSE and NOTICE.md inside the app.
//
//  AboutLookTests draws the block into PNG files, as SubscriptionLookTests
//  does for its rows. Does nothing in a normal run — only with a folder to
//  write to:
//
//    TEST_RUNNER_DAISY_LOOK_DIR=/path/to/folder xcodebuild test … \
//      -testLanguage ru -testRegion RU -only-testing:DaisyTests/AboutLookTests
//

import AppKit
import SwiftUI
import Testing
@testable import Daisy

struct AboutLegalTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DaisyTests
            .deletingLastPathComponent()   // repository root
    }

    private func repositoryText(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The app itself, not the test bundle.
    private var app: Bundle { Bundle(for: SparkleProgress.self) }

    @Test func theLicenseRowSaysAGPL() throws {
        #expect(LegalNotices.licenseName == "AGPL-3.0")
        let source = try repositoryText("Daisy/AboutView.swift")
        #expect(source.contains("detail: LegalNotices.licenseName"), "the License row shows LegalNotices.licenseName")
        #expect(!source.contains("Apache"), "AboutView still names the Apache license")
        #expect(LegalNotices.licenseText == "https://github.com/ca33u/daisy-app/blob/main/LICENSE")
        #expect(LegalNotices.notice == "https://github.com/ca33u/daisy-app/blob/main/NOTICE.md")
    }

    /// Term 1 of NOTICE.md quotes the attribution the About window shows
    /// and names the source code's address.
    @Test func theAttributionIsTheOneInTheNotice() throws {
        let notice = try repositoryText("NOTICE.md")
        let term = try #require(notice.firstMatch(
            of: /shows this author attribution among its legal notices \(the About window\): "([^"]+)", with a link to its source code \(<([^>]+)>\)/))
        #expect(String(term.1) == LegalNotices.attribution)
        #expect(String(term.2) == LegalNotices.sourceCode)
        #expect(LegalNotices.attribution.contains(LegalNotices.website))
    }

    @Test func theCopyrightLineIsTheOneInTheNoticeAndInInfoPlist() throws {
        let notice = try repositoryText("NOTICE.md")
        #expect(notice.components(separatedBy: "\n").contains(LegalNotices.copyright))
        #expect(app.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String == LegalNotices.copyright)
    }

    /// The license travels with the app: the two root files, byte for byte.
    @Test func theAppCarriesTheLicenseAndTheNotice() throws {
        for (name, ext) in [("LICENSE", nil as String?), ("NOTICE", "md")] {
            let file = ext.map { "\(name).\($0)" } ?? name
            let shipped = try #require(app.url(forResource: name, withExtension: ext), "\(file) is not in Daisy.app")
            let shippedData = try Data(contentsOf: shipped)
            let sourceData = try Data(contentsOf: root.appendingPathComponent(file))
            #expect(shippedData == sourceData, "\(file)")
        }
        let license = try String(contentsOf: try #require(app.url(forResource: "LICENSE", withExtension: nil)), encoding: .utf8)
        #expect(license.contains("GNU AFFERO GENERAL PUBLIC LICENSE"))
    }

    /// The block's own strings are in Russian too, captions without a full
    /// stop at the end, and the string that named Apache is gone.
    @Test func theLegalStringsAreInTheCatalog() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("Daisy/Localizable.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let source = try repositoryText("Daisy/AboutView.swift")
        let notice = "Daisy is free software under AGPL-3.0-only. It comes with no warranty. You may redistribute it under that license"
        for key in ["Legal notices", "Author", "Source code", "License", "Additional terms", notice] {
            #expect(source.contains("\"\(key)\""), "AboutView no longer shows «\(key)»")
            let entry = try #require(strings[key] as? [String: Any], "\(key)")
            let localizations = entry["localizations"] as? [String: Any]
            let unit = (localizations?["ru"] as? [String: Any])?["stringUnit"] as? [String: Any]
            let russian = try #require(unit?["value"] as? String, "no Russian for «\(key)»")
            #expect(!russian.hasSuffix("."), "\(russian)")
            #expect(!key.hasSuffix("."), "\(key)")
        }
        #expect(strings["Made by addicted. Open source under Apache 2.0."] == nil)
    }
}

@Suite("About look")
@MainActor
struct AboutLookTests {
    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["DAISY_LOOK_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
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

    /// The last section of About, as the sheet shows it: the sheet's width
    /// (AboutPanel), its ink for plain buttons, the grouped form.
    @Test func drawTheLegalNotices() throws {
        guard outputDirectory != nil else { return }
        let block = Form {
            AboutLegalSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .tint(Color.daisyTextPrimary)
        for scheme in [ColorScheme.light, .dark] {
            try write(block, name: "about-legal", size: CGSize(width: AboutPanel.preferredWidth, height: 290), scheme: scheme)
        }
    }
}
