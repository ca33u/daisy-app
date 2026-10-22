//
//  VersionInfo.swift
//  Daisy
//
//  Tiny shared helper for "what version is this app + put it on the
//  clipboard". Used by the click-to-copy affordance on the sidebar
//  version pill (MainView) and the About header version line
//  (AboutView). Pre-1.0.7.3 both sites had inlined identical copies
//  of the implementation; lifted out here so a future change (e.g.
//  add a debug-build flag to the copied string) lands once.
//

import AppKit
import os
import Foundation

@MainActor
enum VersionInfo {

    /// "1.0.7.3" — the marketing version shown in tight UI like the
    /// sidebar footer pill.
    static var marketingVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    /// "30" — the build number Sparkle uses to compare appcast
    /// entries. This is the authoritative "what binary is running"
    /// identifier; marketingVersion alone can ship across multiple
    /// builds (e.g. a re-signed bundle).
    static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
    }

    /// "Daisy 1.0.7.3 (30)" — the format we paste to clipboard for
    /// support pastes. App name prefix removes context ambiguity
    /// once the string lands in someone else's Slack / inbox; build
    /// number disambiguates re-signed or hotfixed binaries.
    static var supportPayload: String {
        "Daisy \(marketingVersion) (\(buildNumber))"
    }

    // MARK: - What this Mac has actually run

    /// Every build that has run on this Mac, oldest first, each stamped
    /// with when it first ran.
    ///
    /// Exists because of a question nobody could answer: a tester reported
    /// having to update several times in a row after skipping versions,
    /// and neither he nor the log report could say which versions those
    /// were. The report knows only what is running RIGHT NOW, Sparkle logs
    /// under its own subsystem and never reaches our report, and a PID
    /// change tells you an app relaunched, not what it relaunched into.
    /// Two entries three minutes apart is the whole diagnosis: it means
    /// Sparkle offered an intermediate build instead of the newest, which
    /// is a feed problem. One entry means it jumped straight there and the
    /// complaint is release cadence.
    ///
    /// Written once per build change, so it costs one defaults read per
    /// launch and stays short. Capped — the last handful is what any
    /// diagnosis needs.
    static func recordLaunch() {
        // The test host would log the dev build as an update, and then the
        // real update to that build wouldn't be recorded.
        guard !TestHost.isActive else { return }
        let current = "\(marketingVersion) (\(buildNumber))"
        var trail = UserDefaults.standard.stringArray(forKey: k_versionTrail) ?? []
        // Same build as last launch: nothing new to say.
        if let last = trail.last, last.hasPrefix(current) { return }
        let previous = trail.last
        trail.append("\(current) \(launchStamp())")
        if trail.count > maxTrailEntries {
            trail.removeFirst(trail.count - maxTrailEntries)
        }
        UserDefaults.standard.set(trail, forKey: k_versionTrail)
        // Also in the log body, which survives changes to the report
        // header format.
        if let previous {
            log.info("Now running \(current, privacy: .public) — previous build on this Mac: \(previous, privacy: .public)")
        } else {
            log.info("First run recorded: \(current, privacy: .public)")
        }
    }

    /// The trail as one line for the log report, newest last. "first run"
    /// when this build is the only one this Mac has seen.
    static func versionTrailLine() -> String {
        let trail = UserDefaults.standard.stringArray(forKey: k_versionTrail) ?? []
        guard trail.count > 1 else { return trail.first ?? "first run" }
        return trail.suffix(5).joined(separator: " → ")
    }

    private static let maxTrailEntries = 8
    private static let k_versionTrail = "daisy.versionTrail"
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "Version")

    /// Fixed format, fixed locale: this string is read by whoever is
    /// debugging a bug report, not by the user, and it has to sort and
    /// compare across machines and languages.
    private static func launchStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }

    /// Copy the support payload to clipboard and show a toast
    /// confirmation. Wired to the sidebar version pill tap handler
    /// in MainView and the About header version line in AboutView.
    static func copyToClipboardWithToast() {
        let payload = supportPayload
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(payload, forType: .string)
        ToastCenter.shared.show(String(localized: "Copied \(payload)"), style: .success)
    }
}
