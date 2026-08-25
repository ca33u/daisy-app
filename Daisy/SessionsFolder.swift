//
//  SessionsFolder.swift
//  Daisy
//
//  Resolves the user's chosen folder for storing meeting sessions
//  (audio archives, transcript markdown, summary JSON, screenshots)
//  via a security-scoped bookmark. Sandbox-friendly: we hold the
//  bookmark Data in UserDefaults and resolve it to a URL on demand;
//  callers MUST pair `startAccessingSecurityScopedResource()` with a
//  matching `stop` when they're done touching files.
//
//  Default behaviour (no folder picked): sessions live inside the
//  app's container at `~/Library/Containers/.../Application Support/
//  Daisy/Sessions/`. Picking a folder reroutes new sessions there
//  (think Obsidian vault). When the destination changes, the user can
//  move old sessions, put them in the Trash, or leave them in place.
//  SessionStore keeps every retained location visible in the Library.
//

import Foundation
import AppKit
import os

@MainActor
enum SessionsFolder {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "SessionsFolder")
    private static let bookmarkKey = "daisy.sessionsFolderBookmark"
    /// Previous user-selected roots kept when the user chooses "Leave files
    /// where they are". Without retaining their bookmarks those recordings
    /// would remain on disk but disappear from the Library after the active
    /// destination changes.
    private static let legacyBookmarksKey = "daisy.sessionsFolderLegacyBookmarks"

    /// Path displayed in Settings when no folder is picked.
    static let defaultContainerLabel = String(localized: "Inside Daisy's container (default)")

    // MARK: - Persistence

    /// Store a security-scoped bookmark for the user's chosen folder.
    /// Caller has just received `url` from NSOpenPanel — we encode
    /// + persist. Returns false if bookmark creation failed (rare —
    /// usually means the URL isn't actually file-scoped).
    @discardableResult
    static func setUserFolder(_ url: URL) -> Bool {
        do {
            let data = try makeBookmark(for: url)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            forgetLegacyFolder(url)
            log.info("Stored sessions folder bookmark for \(url.path, privacy: .private)")
            return true
        } catch {
            log.error("Bookmark creation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Drop the stored bookmark — new sessions revert to the
    /// default container location until the user picks again.
    static func clearUserFolder() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        log.info("Cleared sessions folder bookmark")
    }

    /// Resolve the stored bookmark to a URL. Returns nil if no
    /// bookmark stored, the bookmark resolved to an invalid path,
    /// or the volume is unmounted. If the bookmark is stale (folder
    /// moved within the same volume) we transparently refresh it.
    ///
    /// IMPORTANT: the returned URL is NOT yet accessible — callers
    /// MUST `startAccessingSecurityScopedResource()` before any file
    /// I/O, and match with a `stop` when done.
    static func resolveUserFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        do {
            let (url, isStale) = try resolveBookmark(data)
            if isStale {
                log.info("Bookmark stale, refreshing for \(url.path, privacy: .private)")
                _ = setUserFolder(url)
            }
            return url
        } catch {
            log.warning("Couldn't resolve sessions folder bookmark: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // (`userFolderDisplayPath()` removed 2026-08-25: Settings now shows
    // the EFFECTIVE recordings directory — base + `Daisy/Sessions`, and
    // the same one for the default container — via
    // `StorageUsage.recordingsDisplayPath()`. Two functions producing
    // two different "the path" strings is how the row and the Reveal
    // button drift apart.)

    /// Whether a user folder is currently configured (regardless of
    /// whether it resolves right now — UI uses this to decide
    /// "Reset to default" vs "Choose folder".)
    static var hasUserFolder: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    /// All former custom roots that should remain visible in the Library.
    /// Invalid bookmarks are retained: a temporarily-unmounted disk should
    /// reappear automatically rather than being forgotten forever.
    static func resolveLegacyFolders() -> [URL] {
        let stored = UserDefaults.standard.array(forKey: legacyBookmarksKey) as? [Data] ?? []
        var resolved: [URL] = []
        var refreshed = stored
        var didRefresh = false

        for (index, data) in stored.enumerated() {
            do {
                let (url, isStale) = try resolveBookmark(data)
                resolved.append(url)
                if isStale, let replacement = try? makeBookmark(for: url) {
                    refreshed[index] = replacement
                    didRefresh = true
                }
            } catch {
                log.warning("Couldn't resolve previous sessions folder bookmark: \(error.localizedDescription, privacy: .public)")
            }
        }
        if didRefresh {
            UserDefaults.standard.set(refreshed, forKey: legacyBookmarksKey)
        }
        return uniqueURLs(resolved)
    }

    /// Retain a previous custom root as a read source after changing where
    /// new recordings are written.
    @discardableResult
    static func rememberLegacyFolder(_ url: URL) -> Bool {
        let normalized = normalizedPath(url)
        guard resolveLegacyFolders().contains(where: { normalizedPath($0) == normalized }) == false else {
            return true
        }
        do {
            var stored = UserDefaults.standard.array(forKey: legacyBookmarksKey) as? [Data] ?? []
            stored.append(try makeBookmark(for: url))
            UserDefaults.standard.set(stored, forKey: legacyBookmarksKey)
            return true
        } catch {
            log.error("Previous folder bookmark creation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func forgetLegacyFolder(_ url: URL) {
        let normalized = normalizedPath(url)
        let stored = UserDefaults.standard.array(forKey: legacyBookmarksKey) as? [Data] ?? []
        let filtered = stored.filter { data in
            guard let (candidate, _) = try? resolveBookmark(data) else { return true }
            return normalizedPath(candidate) != normalized
        }
        if filtered.count != stored.count {
            UserDefaults.standard.set(filtered, forKey: legacyBookmarksKey)
        }
    }

    // MARK: - Picker

    /// Open the system folder picker, store the result as a
    /// security-scoped bookmark, and return the URL. Sync API —
    /// blocks while the panel is up, returns when the user picks
    /// (or cancels → nil).
    static func chooseFolder(window: NSWindow? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a folder for Daisy sessions")
        panel.message = String(localized: "Audio, transcripts, summaries and screenshots will be saved into a `Daisy/Sessions/` subfolder here.")
        panel.prompt = String(localized: "Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }

    /// Backwards-compatible convenience for call sites that do not need a
    /// migration choice. Settings uses `chooseFolder` and commits only after
    /// the user decides what to do with existing files.
    static func presentPicker(window: NSWindow? = nil) -> URL? {
        guard let url = chooseFolder(window: window) else { return nil }
        return setUserFolder(url) ? url : nil
    }

    // MARK: - Base resolution

    /// Resolve the base URL where a new session directory should be
    /// created. Returns either the user-picked folder (security-scope
    /// acquired) or the default container location. Caller MUST call
    /// `release` on the returned ticket when done so we stop holding
    /// the security scope.
    static func acquireBase() -> AccessTicket? {
        if let userURL = resolveUserFolder() {
            if let ticket = acquireAccess(to: userURL, requireWrite: true) {
                return ticket
            }
            log.warning("Failed to start accessing user folder — falling back to default")
        }
        // Default: inside the app container's Application Support.
        if let defaultURL = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return AccessTicket(url: defaultURL, securityScoped: false)
        }
        return nil
    }

    /// Default base URL used by SessionStore even when no user
    /// folder is set — points at the app's Application Support dir.
    /// Returns nil only if Foundation can't resolve it (essentially
    /// never on macOS).
    static func defaultBase() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    /// Resolve an existing configured root for scanning or migration. Daisy
    /// currently ships without App Sandbox, so a security-scope call may
    /// legitimately return false even though the folder is readable. Verify
    /// actual filesystem access before treating that as a failure.
    static func acquireAccess(to url: URL, requireWrite: Bool = false) -> AccessTicket? {
        if url.startAccessingSecurityScopedResource() {
            return AccessTicket(url: url, securityScoped: true)
        }
        let fm = FileManager.default
        let accessible = requireWrite
            ? fm.isWritableFile(atPath: url.path)
            : fm.isReadableFile(atPath: url.path)
        return accessible ? AccessTicket(url: url, securityScoped: false) : nil
    }

    nonisolated static func sessionsDirectory(in base: URL) -> URL {
        base.appendingPathComponent("Daisy/Sessions", isDirectory: true)
    }

    /// True when `url` lives in an iCloud-synced location: iCloud Drive
    /// proper (~/Library/Mobile Documents) or a Desktop/Documents folder
    /// with "Desktop & Documents" sync enabled. Used to warn the user
    /// when they pick such a folder for recordings: with "Optimize Mac
    /// Storage" macOS evicts files there under disk pressure, and the
    /// recordings become unreadable until re-downloaded (2026-08-19
    /// field incident — "my recordings disappeared").
    nonisolated static func isCloudSynced(_ url: URL) -> Bool {
        if url.standardizedFileURL.path.contains("/Library/Mobile Documents/") {
            return true
        }
        // Desktop & Documents sync keeps the visible path (~/Desktop),
        // so path checks aren't enough — ask the filesystem. The folder
        // itself may not carry the flag; its children do.
        func ubiquitous(_ u: URL) -> Bool {
            (try? u.resourceValues(forKeys: [.isUbiquitousItemKey]))?
                .isUbiquitousItem == true
        }
        if ubiquitous(url) { return true }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isUbiquitousItemKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.prefix(5).contains(where: ubiquitous)
    }

    nonisolated static func sameFolder(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedPath(lhs) == normalizedPath(rhs)
    }

    private static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private static func resolveBookmark(_ data: Data) throws -> (URL, Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    nonisolated private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert(normalizedPath($0)).inserted }
    }

    /// One-shot access ticket. Holds onto the URL and releases the
    /// security scope when discarded. Lifetime tied to the recording
    /// session for RecordingSession, or to a scan loop for SessionStore.
    final class AccessTicket {
        let url: URL
        private let securityScoped: Bool
        private var released = false

        init(url: URL, securityScoped: Bool) {
            self.url = url
            self.securityScoped = securityScoped
        }

        func release() {
            guard !released else { return }
            released = true
            if securityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        deinit {
            if !released, securityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }
}
