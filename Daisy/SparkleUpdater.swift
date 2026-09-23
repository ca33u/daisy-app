//
//  SparkleUpdater.swift
//  Daisy
//
//  Thin wrapper over Sparkle 2.x's SPUStandardUpdaterController. Owns
//  the singleton lifetime, exposes a SwiftUI-friendly API for the
//  "Check for Updates…" menu command and the Settings toggle, and
//  gates everything on `#if canImport(Sparkle)` so the project keeps
//  building during the brief window between this file landing in the
//  repo and the SPM dependency being added in Xcode.
//
//  Once Sparkle is added (Xcode → File → Add Package Dependencies →
//  https://github.com/sparkle-project/Sparkle, version "Up to Next
//  Major" from 2.6), the `canImport` evaluates to true and the real
//  implementation kicks in.
//
//  Configuration lives in build settings (because the project uses
//  GENERATE_INFOPLIST_FILE = YES — no physical Info.plist). The user
//  must add four custom `INFOPLIST_KEY_*` entries to the target's
//  Build Settings:
//
//    INFOPLIST_KEY_SUFeedURL          = https://mydaisy.io/appcast.xml
//    INFOPLIST_KEY_SUPublicEDKey      = <public EdDSA key, base64>
//    INFOPLIST_KEY_SUEnableAutomaticChecks = YES
//    INFOPLIST_KEY_SUEnableInstallerLauncherService = YES
//
//  The EdDSA key pair is generated once via Sparkle's `generate_keys`
//  CLI tool — private key goes into the local Keychain on the build
//  machine, public key into SUPublicEDKey above. Each future release
//  is signed with the private key via `sign_update` and the resulting
//  signature is embedded in `appcast.xml`.
//

import Foundation
import SwiftUI
import os

/// A pending update Daisy has been told about by Sparkle but that the
/// user hasn't installed yet. Drives the quiet "Обновиться" affordance in
/// the sidebar (a non-modal complement to Sparkle's own prompt — it stays
/// put after "Remind Me Later"). Cleared when a check finds nothing (also
/// covers the user "Skip"-ing a version, and the relaunch into the new
/// build where the appcast no longer offers it).
struct AvailableUpdate: Equatable, Sendable {
    /// Marketing version, e.g. "1.0.7.35" (SUAppcastItem.displayVersionString).
    let shortVersion: String
    /// CFBundleVersion / build, e.g. "79" (SUAppcastItem.versionString).
    let build: String
}

#if canImport(Sparkle)
import Sparkle

/// SwiftUI-observable wrapper around Sparkle's updater controller.
/// The controller itself is an NSObject and lives for the lifetime of
/// the app — Sparkle's design assumes a single long-lived instance per
/// process, which is what `static let shared` gives us.
///
/// `@MainActor` because every Sparkle API that mutates updater state
/// (manual check, toggle automatic checks, fetch lastUpdateCheckDate)
/// must be called from the main thread per Sparkle's documentation.
@MainActor
@Observable
final class SparkleUpdater {
    static let shared = SparkleUpdater()

    private let controller: SPUStandardUpdaterController
    /// Strong reference — `SPUUpdater` holds its delegate weakly.
    private let channelDelegate = DaisyUpdaterDelegate()

    /// Update-channel opt-in. `false` (default) = stable releases only —
    /// appcast items without a `<sparkle:channel>` tag. `true` = also
    /// receive "beta"-channel builds (newest features, less soak time).
    /// Sparkle asks the delegate for allowed channels on EVERY check, so
    /// flipping this applies to the very next check — no restart needed.
    /// Stored straight in UserDefaults ("daisy.updates.betaChannel") so
    /// the nonisolated delegate can read it off-main without actor hops.
    var receiveBetaUpdates: Bool {
        get { UserDefaults.standard.bool(forKey: "daisy.updates.betaChannel") }
        set { UserDefaults.standard.set(newValue, forKey: "daisy.updates.betaChannel") }
    }

    /// The update Sparkle most recently found and hasn't installed yet, or
    /// nil when the app is up to date. Set by `DaisyUpdaterDelegate` on the
    /// `didFindValidUpdate` / `updaterDidNotFindUpdate` callbacks (which fire
    /// on BOTH automatic and manual checks), so any SwiftUI surface can bind
    /// to it for a quiet "update available" badge. `fileprivate(set)` so the
    /// delegate in this file can write it while callers stay read-only.
    fileprivate(set) var availableUpdate: AvailableUpdate?

    /// Mirrored from `updater.automaticallyChecksForUpdates` so SwiftUI
    /// can observe the toggle and re-render the Settings row when
    /// Sparkle's preference changes externally (e.g., the user dismisses
    /// a prompt that flipped it). Two-way sync via the computed setter.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Whether a "Check for Updates" call can fire right now. Sparkle
    /// disables the menu item while an existing check is in flight, on
    /// the rationale that a second manual probe during a download would
    /// produce confusing UI. The Settings row reads this to grey out
    /// the explicit Check button.
    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    /// Last-checked timestamp surfaced in Settings ("Last checked: 2h
    /// ago"). Sparkle persists this in user defaults across launches.
    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: channelDelegate,
            userDriverDelegate: nil
        )
    }

    /// Manual "Check for Updates…" — fired from the menu command + the
    /// Settings button. Sparkle shows its own UI: progress sheet during
    /// the check, then either "You're up to date" or the
    /// update-available prompt with release notes + Install / Skip /
    /// Remind Me Later.
    func checkForUpdates() {
        // Бэклог 16 Р-1: a check the person started themselves is not
        // blocked — they are standing at the keyboard and can read what
        // Sparkle offers. They are warned, because the offer will
        // include "Install and Relaunch", and a relaunch is the one
        // thing that would end the meeting.
        if RecordingSession.isCapturingOrTranscribing {
            ToastCenter.shared.show(
                String(localized: "A recording is in progress — an update will install after it ends."),
                style: .info
            )
        }
        controller.checkForUpdates(nil)
    }

    // MARK: - Р-1: an update must never end a recording

    /// Holds the installer's relaunch until the audio pipeline is idle.
    @ObservationIgnored fileprivate let relaunchHold = PostponedRelaunch()

    /// True while an update is installed and waiting for the meeting to
    /// end. Surfaced so Settings can say so instead of looking idle.
    var isWaitingForRecordingToRelaunch: Bool { relaunchHold.isWaiting }

    /// Starts Sparkle's normal background update cycle immediately after
    /// launch. Sparkle itself continues to schedule later checks according to
    /// `SUScheduledCheckInterval`; this launch check means a user who opens
    /// Daisy after a new release doesn't have to wait for that cadence or
    /// press “Check for Updates”.
    ///
    /// `checkForUpdatesInBackground()` is Sparkle's recommended API for this
    /// exact case. Unlike an information-only probe, it can progress through
    /// Sparkle's regular download/install flow while remaining non-modal.
    /// It must be invoked immediately after the updater is started, which is
    /// satisfied by the singleton's construction just before this method is
    /// called from `DaisyApp.init`.
    func checkForUpdatesAfterLaunch() {
        guard automaticallyChecksForUpdates else { return }
        controller.updater.checkForUpdatesInBackground()
    }
}

/// Бэклог 16 Р-1: the two decisions an update has to get right while a
/// meeting is running, kept away from Sparkle so they can be tested.
///
/// `UpdateGate` is the rule; `PostponedRelaunch` is the machinery that
/// carries an already-installed update across the end of a recording.
enum UpdateGate {
    /// Whether a check of this kind may start right now.
    ///
    /// A scheduled or background check waits: nobody asked for it, and
    /// its whole purpose is to put a dialog on screen — one whose
    /// default button relaunches the app. A check the person started
    /// themselves goes through; they are at the keyboard, and they are
    /// told a recording is running.
    static func mayCheck(kind: SPUUpdateCheck, whileCapturing capturing: Bool) -> Bool {
        guard capturing else { return true }
        return kind != .updatesInBackground
    }
}

/// An installed update waiting for the audio to finish.
///
/// Sparkle hands over its relaunch block exactly once. Dropping it would
/// leave the update staged and never applied, so the block is stored and
/// only ever released — never discarded.
@MainActor
final class PostponedRelaunch {
    /// Asked once a second while something is held. Injectable so the
    /// rule can be tested without a recording, a Sparkle updater, or a
    /// wait for real time.
    var isBusy: @MainActor () -> Bool = { RecordingSession.isCapturingOrTranscribing }

    private(set) var isWaiting = false
    private var install: (() -> Void)?
    private var watcher: Task<Void, Never>?

    /// Polling rather than a callback on purpose: "busy" is a composite
    /// of three independent things — session status, the summary task,
    /// a standalone re-transcription — and a missed edge here costs at
    /// most a second, while a missed callback would strand an installed
    /// update forever.
    func hold(_ install: @escaping () -> Void, pollEvery interval: Duration = .seconds(1)) {
        self.install = install
        isWaiting = true
        watcher?.cancel()
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                guard !isBusy() else { continue }
                release()
                return
            }
        }
    }

    /// Runs the held block, if any. Idempotent.
    func release() {
        watcher?.cancel()
        watcher = nil
        isWaiting = false
        guard let install else { return }
        self.install = nil
        Logger(subsystem: "app.essazanov.Daisy", category: "Updates")
            .notice("Audio pipeline idle — running the postponed update relaunch")
        install()
    }
}

/// Scopes Daisy's updater to Sparkle channels (2026-06-08). Stable =
/// appcast items with no `<sparkle:channel>` tag — every client sees
/// those. Beta = items tagged `<sparkle:channel>beta</sparkle:channel>`,
/// served only when the user opted in via About → "Get beta updates".
/// The UserDefaults key string is duplicated from
/// `SparkleUpdater.receiveBetaUpdates` on purpose: Sparkle may call the
/// delegate off the main thread, and reading a plain defaults bool from
/// a `nonisolated` method avoids any actor hop.
private final class DaisyUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    /// Бэклог 16 Р-1. Two hooks, and they answer two different
    /// questions.
    ///
    /// This one stops the check from ever starting. It takes the KIND of
    /// check, which matters: the backlog named the older
    /// `updaterMayCheckForUpdates(_:)`, but that one is deprecated in
    /// this Sparkle and cannot tell a scheduled probe from a person
    /// pressing "Check for Updates…" — so using it would either block
    /// the manual check too, or block nothing. Scheduled and background
    /// checks wait; a check someone asked for goes through, warned.
    @MainActor
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !UpdateGate.mayCheck(kind: updateCheck,
                                   whileCapturing: RecordingSession.isCapturingOrTranscribing) else { return }
        throw NSError(domain: "app.essazanov.Daisy.updates", code: 1, userInfo: [
            NSLocalizedDescriptionKey: String(localized: "A recording is in progress — update checks resume when it ends."),
        ])
    }

    /// And this one catches the case the first cannot: the update was
    /// already found and downloaded, the person clicked "Install and
    /// Relaunch", and a meeting started in between — or they clicked it
    /// during one. Returning true hands us the installer's block to run
    /// later; Sparkle keeps the update staged until we do.
    @MainActor
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard RecordingSession.isCapturingOrTranscribing else { return false }
        SparkleUpdater.shared.relaunchHold.hold(installHandler)
        ToastCenter.shared.show(
            String(localized: "Update ready. Daisy will restart when the recording ends."),
            style: .info
        )
        return true
    }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: "daisy.updates.betaChannel") ? ["beta"] : []
    }

    /// Sparkle found a valid update (automatic or manual check). Capture its
    /// version for the sidebar badge and hop to the main actor to publish it.
    /// The Standard user driver still shows its own prompt; the badge is the
    /// persistent, non-modal complement.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let found = AvailableUpdate(shortVersion: item.displayVersionString,
                                    build: item.versionString)
        // Logged, not just badged: WHICH item Sparkle picked out of the
        // feed is the only way to tell "the feed offered an intermediate
        // build" from "another release shipped while you were updating" —
        // the two causes of being asked to update twice in a row. Sparkle's
        // own logs go to its subsystem and never reach our bug report.
        Logger(subsystem: "app.essazanov.Daisy", category: "Updates").info(
            // `displayVersionString` / `versionString` are non-optional in
            // Sparkle 2 — the AvailableUpdate init two lines up assigns
            // them straight into `String` fields. Only `channel` is
            // nullable, and its absence means the stable channel.
            "Update offered: \(item.displayVersionString, privacy: .public) (build \(item.versionString, privacy: .public)), channel=\(item.channel ?? "stable", privacy: .public)"
        )
        Task { @MainActor in SparkleUpdater.shared.availableUpdate = found }
    }

    /// No update available (including after the user chose "Skip" for the
    /// offered version, or once we've relaunched into it) — clear the badge.
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in SparkleUpdater.shared.availableUpdate = nil }
    }
}

#else

// MARK: - Stub fallback when Sparkle isn't linked yet.
//
// Lets the rest of the codebase reference SparkleUpdater.shared without
// `#if` blocks at every call site. The stub disables itself everywhere
// so the absence of the framework is visible in UI (greyed buttons, no
// last-check timestamp) but never crashes.

@MainActor
@Observable
final class SparkleUpdater {
    static let shared = SparkleUpdater()

    var automaticallyChecksForUpdates: Bool = false
    var receiveBetaUpdates: Bool = false
    let canCheckForUpdates: Bool = false
    let lastUpdateCheckDate: Date? = nil
    let availableUpdate: AvailableUpdate? = nil

    private init() {}

    func checkForUpdates() {
        // Intentionally empty — the menu item / settings button stays
        // disabled via `canCheckForUpdates == false` until Sparkle is
        // added as an SPM dependency.
    }

    /// No-op until Sparkle is linked (see the real implementation).
    func checkForUpdatesAfterLaunch() {}
}

#endif
