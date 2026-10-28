//
//  SyncCoordinator.swift
//  Daisy
//
//  backlog 9 Ф3-A: the Mac end of the phone ⇄ Mac text sync. The engine,
//  the merge rules and the CloudKit transport live in DaisyCore and are
//  the very same code the phone runs; this file only decides WHEN to
//  run them and WHERE the sessions are.
//
//  Where: whatever folder the user picked (`SessionsFolder.acquireBase`
//  — the Obsidian vault, the external disk), falling back to the app
//  container. The engine is rebuilt when that folder changes; its
//  memory (`sync-state-<hash>.json`) is keyed by the folder, so a
//  switch does not make the old folder's sessions look deleted.
//
//  When: launch, the app coming to the front, a minute-long ticker,
//  and a few seconds after every Library refresh (which is what follows
//  a finished recording, a diarization pass or an edit) — the same
//  debounce as on the phone, so a burst of writes is one push.
//

import AppKit
import CryptoKit
import DaisyCore
import Foundation
import Observation
import Security
import os

@MainActor
@Observable
final class SyncCoordinator {
    static let shared = SyncCoordinator()

    enum Status: Equatable {
        case off
        case idle
        case syncing
        case noAccount
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var lastSyncAt: Date?
    private(set) var lastSummary: SessionSyncEngine.Summary?
    /// J-0 (Egor, 2026-09-22): OFF by default, including on an update —
    /// Daisy promises nothing leaves the Mac, and sync sends transcripts
    /// to the person's iCloud. Turning it on is an explicit choice made
    /// with the explanation in front of them (`SyncSettingsSection`).
    var isEnabled: Bool = UserDefaults.standard.object(forKey: "daisy.sync.enabled") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "daisy.sync.enabled")
            if isEnabled {
                migrateKeysForTheOtherDevice()
                schedule(after: 0)
            } else {
                status = .off
            }
        }
    }

    /// The server versions outlive a relaunch, so the first push after
    /// launch is not refused and followed by a full zone download.
    ///
    /// Lazy, and only behind `cloudKitAvailable` (Sentry 156682704, 27.10):
    /// `CKContainer(identifier:)` traps — EXC_BREAKPOINT inside CloudKit —
    /// for a container the app's signature doesn't list, and as a stored
    /// property this ran on the first touch of `shared`, at every launch,
    /// sync on or off. A build of the public repo without Daisy's
    /// provisioning profile died at launch.
    @ObservationIgnored private lazy var transport = CloudKitSyncTransport(
        versionsURL: (SessionsFolder.defaultBase() ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Daisy/sync-versions.json"))

    /// Whether this copy of Daisy may use its iCloud container at all.
    nonisolated static let cloudKitAvailable: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        return entitles(value, container: CloudKitSyncTransport.defaultContainerID)
    }()

    nonisolated static func entitles(_ value: Any?, container: String) -> Bool {
        (value as? [String])?.contains(container) ?? false
    }

    nonisolated static var unavailableMessage: String {
        String(localized: "This copy of Daisy isn’t signed for iCloud, so sync can’t run. The release from mydaisy.io can.")
    }
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Sync")
    @ObservationIgnored private var engine: SessionSyncEngine?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    private init() {
        if !isEnabled { status = .off }
    }

    /// Launch: first sync shortly after the Library has been read, then
    /// on every activation and once a minute while the app is up.
    /// The keys the iPhone needs (summary provider) live in the legacy
    /// keychain for anyone who used Daisy before 1.0.8. Moving them is
    /// the one thing that may ask the person for permission, so it
    /// happens here — off the main thread, and only when sync is on.
    private func migrateKeysForTheOtherDevice() {
        Task.detached(priority: .utility) {
            KeychainStore.migrateLegacyItems()
        }
    }

    func start() {
        // Sync already on from a previous run: the pass still belongs
        // off the main thread, after launch, not in `init`.
        if isEnabled { migrateKeysForTheOtherDevice() }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: 1) }
        }
        schedule(after: 3)
        startTicker()
    }

    /// Debounced: a burst of local writes becomes one sync.
    func schedule(after seconds: Double = 5) {
        guard isEnabled else { return }
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled else { return }
            // The sync itself runs in its own task: cancelling the
            // debounce must never cancel a CloudKit operation already
            // in flight (it did — "Operation … was cancelled").
            Task { @MainActor in await self?.syncNow() }
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.syncNow()
            }
        }
    }

    func syncNow() async {
        guard isEnabled, !inFlight else { return }
        guard Self.cloudKitAvailable else {
            status = .failed(Self.unavailableMessage)
            return
        }
        guard let ticket = SessionsFolder.acquireBase() else { return }
        defer { ticket.release() }
        inFlight = true
        defer { inFlight = false }
        status = .syncing
        do {
            let summary = try await engine(for: ticket.url).syncOnce()
            lastSummary = summary
            ImprovementStats.record(.syncPulled, count: summary.pulled)
            lastSyncAt = Date()
            status = .idle
            if !summary.isEmpty {
                log.notice("Sync: pulled \(summary.pulled, privacy: .public), pushed \(summary.pushed, privacy: .public), conflicts \(summary.conflicts, privacy: .public)")
            }
        } catch SyncError.noAccount {
            status = .noAccount
        } catch {
            let message = CloudKitSyncTransport.describe(error)
            status = .failed(message)
            log.error("Sync failed: \(message, privacy: .public)")
        }
    }

    /// J-0: "Delete my data from iCloud" — the server side of the sync,
    /// and this Mac's memory of it. Nothing local is touched.
    func eraseCloudData() async throws {
        // Throw, not return: the Settings sheet reads «no error» as
        // «Deleted», and nothing was.
        guard Self.cloudKitAvailable else { throw SyncError.cloud(Self.unavailableMessage) }
        guard let ticket = SessionsFolder.acquireBase() else { return }
        defer { ticket.release() }
        pending?.cancel()
        try await engine(for: ticket.url).eraseCloudData()
        lastSyncAt = nil
        lastSummary = nil
        status = isEnabled ? .idle : .off
    }

    /// The person deleted a session here: remember it for the next pass.
    func markDeleted(_ id: String) {
        // An unentitled build never syncs, so it has no deletion to carry;
        // a signed build syncing the same folder later sees the session
        // gone from disk and asks the person, as for any other gap.
        guard Self.cloudKitAvailable else { return }
        guard let ticket = SessionsFolder.acquireBase() else { return }
        defer { ticket.release() }
        engine(for: ticket.url).markDeleted(id)
        schedule()
    }

    /// One engine per sessions folder; a new folder gets a new engine
    /// and its own memory file.
    private func engine(for base: URL) -> SessionSyncEngine {
        let sessionsBase = SessionsBase(base: base)
        if let engine, engine.base == sessionsBase { return engine }
        let appSupport = SessionsFolder.defaultBase() ?? FileManager.default.temporaryDirectory
        // A stable key: String.hashValue is seeded per process.
        let digest = SHA256.hash(data: Data(base.standardizedFileURL.path.utf8))
        let key = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        let stateURL = appSupport.appendingPathComponent("Daisy/sync-state-\(key).json")
        let engine = SessionSyncEngine(base: sessionsBase, stateURL: stateURL, transport: transport)
        engine.onLocalChanged = { [weak self] ids in
            self?.log.notice("Sync pulled \(ids.count, privacy: .public) session(s) — refreshing the Library")
            Task { @MainActor in await SessionStore.shared.refresh() }
        }
        self.engine = engine
        lastSyncAt = engine.state.lastSyncAt
        return engine
    }
}
