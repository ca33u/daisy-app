//
//  AboutPanel.swift
//  Daisy
//
//  Replacement for the default `NSApplication.orderFrontStandardAboutPanel`.
//  System default shows just the bundle version and reads "we forgot
//  to fill in copyright". This one names Addicted Studio, lists a
//  contact email and a website, and keeps the standard macOS panel
//  chrome so it still feels like the platform's About dialog (no
//  custom window, no SwiftUI sheet — that would feel off-brand for a
//  macOS app).
//
//  Wiring: `DaisyApp.body.commands { CommandGroup(replacing: .appInfo) }`
//  routes the Daisy menu's "About Daisy" item here.
//

import AppKit
import Foundation

@MainActor
enum AboutPanel {
    /// Open the standard About panel populated with our credits +
    /// version metadata. Idempotent — calling twice just brings the
    /// existing panel forward.
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Daisy",
            .applicationVersion: shortVersion,
            .version: buildNumber,
            .credits: creditsAttributed,
            // Copyright — Apple's About panel reads
            // `NSHumanReadableCopyright` from Info.plist by default,
            // but we override here so it stays consistent with the
            // string the in-app About view shows.
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"):
                String(localized: "Made by Addicted Studio. Open source under Apache 2.0.")
        ])
    }

    // MARK: - Pieces

    private static var shortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }

    private static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }

    /// Credits string rendered in the About panel's text area. The
    /// panel accepts an `NSAttributedString`, so we hand-build it
    /// with a small font and a couple of clickable URLs. AppKit
    /// renders the `.link` attribute as an underlined link the
    /// user can click — `NSWorkspace.shared.open` runs from the
    /// system handler automatically.
    private static var creditsAttributed: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4

        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let result = NSMutableAttributedString()
        result.append(.init(
            string: String(localized: "Local meeting capture for Mac\n"),
            attributes: base
        ))
        result.append(.init(
            string: String(localized: "Built by Addicted Studio\n"),
            attributes: base
        ))
        result.append(link("addicted.sh", url: "https://addicted.sh", base: base))
        result.append(.init(string: " · ", attributes: base))
        result.append(link("mydaisy.io", url: "https://mydaisy.io", base: base))
        result.append(.init(string: "\n", attributes: base))
        result.append(link(
            "hello@mydaisy.io",
            url: "mailto:hello@mydaisy.io",
            base: base
        ))
        // Donation link (2026-08-31) — same low-key styling as the
        // other links; the in-app About view carries the prominent
        // "Support Daisy" section, this is just parity.
        result.append(.init(string: "\n", attributes: base))
        result.append(link(
            "ko-fi.com/ca33u",
            url: "https://ko-fi.com/ca33u",
            base: base
        ))
        return result
    }

    /// Build an attributed `link` run with the same base styling but
    /// the `.link` attribute set — AppKit's About panel turns this
    /// into a clickable, underlined URL.
    private static func link(
        _ text: String,
        url: String,
        base: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        var attrs = base
        attrs[.link] = URL(string: url) ?? text
        attrs[.foregroundColor] = NSColor.linkColor
        return NSAttributedString(string: text, attributes: attrs)
    }
}
