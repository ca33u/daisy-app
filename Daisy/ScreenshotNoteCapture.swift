//
//  ScreenshotNoteCapture.swift
//  Daisy
//
//  A screenshot becomes a note, and for a few seconds after it, dictation
//  goes into that note instead of into whatever app is in front.
//
//  THE FEATURE IS THE ROUTING, NOT THE LISTENING. The obvious design is
//  "screenshot → open the microphone for ten seconds → if they said
//  something, keep it". It was rejected, and the reason is worth keeping
//  written down: a microphone that switches itself on with no gesture
//  from the user, on a trigger that fires dozens of times a day for
//  reasons that have nothing to do with notes, lights the macOS
//  recording indicator every single time. Someone screenshotting a bank
//  statement and seeing that dot appear does not think "how
//  convenient". For an app whose whole promise is that nothing leaves
//  the Mac, the microphone turning itself on is the one behaviour that
//  can undo that in a second — and in the common case it would spend an
//  indicator flash, ten seconds of inference and battery on a
//  screenshot nobody wanted a note about.
//
//  Daisy already has push-to-talk dictation with a key the user holds
//  every day. All that was missing is a DESTINATION: normally the
//  transcript is pasted into the frontmost app; while a capture is
//  pending it lands in the note instead. No new microphone path, no new
//  permission, no new indicator behaviour, and the moment the user
//  releases the key is an unambiguous "I'm done" — no ten-second window
//  to cut them off mid-sentence, no threshold deciding whether a mumble
//  counted as a note.
//
//  THE NOTE IS WRITTEN IMMEDIATELY, before anyone says anything. Ignoring
//  the prompt is a legitimate choice, not a way to lose a screenshot:
//  the note exists with the image in it either way, and the Notes tab is
//  a text editor — someone who would rather type can just type there.
//
//  WHAT IT DOES NOT DO. It never moves, renames or deletes the user's
//  screenshot; the file in their screenshot folder is theirs and stays
//  exactly where they put it. We copy. It reads nothing else in that
//  folder — only files that appear after we start watching.
//

import AppKit
import Foundation
import os

@Observable
@MainActor
final class ScreenshotNoteCapture {
    static let shared = ScreenshotNoteCapture()

    /// A note written moments ago and still open for context. Non-nil
    /// only inside `pendingWindow` after a screenshot.
    private(set) var pending: Pending?

    struct Pending {
        let noteDirectory: URL
        let imageName: String
        let createdAt: Date
    }

    /// How long dictation keeps being redirected. Long enough to notice
    /// the toast, read it, and start talking; short enough that a
    /// dictation two minutes later still goes where the user expects.
    /// A hold that STARTS inside the window counts even if it finishes
    /// after it — `claimPending` is checked at press, not at release.
    private static let pendingWindow: TimeInterval = 12

    private var source: DispatchSourceFileSystemObject?
    private var watchedFD: CInt = -1
    private var watchedDir: URL?
    private var known: Set<String> = []
    private var expiry: Task<Void, Never>?
    /// Read for the dictation hotkey's label, so the prompt can name the
    /// key instead of gesturing at it. Weak, like every other service
    /// that holds settings.
    private weak var settings: AppSettings?
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "ScreenshotNotes")

    private init() {}

    // MARK: - Watching

    var isWatching: Bool { source != nil }

    /// Start watching the folder macOS drops screenshots into. Idempotent.
    func start() {
        guard source == nil else { return }
        guard let dir = Self.screenshotFolder() else {
            log.error("No screenshot folder resolved — capture not started")
            return
        }
        // Snapshot what's already there. Everything present now is
        // history — we only ever react to files that appear later.
        known = Self.imageNames(in: dir)

        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            // Desktop / Documents / Downloads are TCC-protected: the
            // first open() is what raises the system's "Daisy would like
            // to access files in your Desktop folder" prompt. A denial
            // lands here and must say so — silence is how a feature
            // becomes "it does nothing".
            log.error("Can't watch \(dir.path, privacy: .private) (errno \(errno, privacy: .public)) — folder access likely denied")
            ToastCenter.shared.show(
                String(localized: "Daisy can’t see your screenshots folder. Grant access in System Settings → Privacy & Security → Files and Folders."),
                style: .warning
            )
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The folder itself went away or was renamed — including
                // the likeliest case, the user changing their screenshot
                // location right after switching this on. The fd would
                // otherwise stay open on an unlinked vnode and watch
                // nothing for the rest of the session.
                let flags = src.data
                if flags.contains(.delete) || flags.contains(.rename) {
                    self.log.info("Screenshot folder moved or removed — re-resolving")
                    self.stop()
                    self.start()
                    return
                }
                self.folderChanged()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()

        source = src
        watchedFD = fd
        watchedDir = dir
        log.info("Watching screenshots in \(dir.lastPathComponent, privacy: .public)")
    }

    func stop() {
        source?.cancel()
        source = nil
        watchedFD = -1
        watchedDir = nil
        known = []
        clearPending()
    }

    func apply(settings: AppSettings) {
        self.settings = settings
        if settings.screenshotNotesEnabled { start() } else { stop() }
    }

    /// The directory changed. Diff against what we knew: a directory
    /// event carries no filename, and a screenshot is a create.
    private func folderChanged() {
        guard let dir = watchedDir else { return }
        let now = Self.imageNames(in: dir)
        defer { known = now }
        let fresh = now.subtracting(known)
        guard !fresh.isEmpty else { return }

        // One screenshot at a time. A burst (a folder full of images
        // dragged in, a sync client landing a backlog) is not somebody
        // taking a screenshot, and turning it into a pile of notes is
        // worse than doing nothing — take the newest only, and only if
        // the burst is small enough to be a person.
        // ⌘⇧3 writes ONE FILE PER DISPLAY, so the ceiling has to follow
        // the hardware — a fixed 2 would switch the feature off entirely
        // for anyone with two external monitors, silently and forever.
        let ceiling = max(2, NSScreen.screens.count)
        guard fresh.count <= ceiling else {
            log.info("\(fresh.count, privacy: .public) images appeared at once (ceiling \(ceiling, privacy: .public)) — not a screenshot, ignoring")
            return
        }
        let candidates = fresh
            .map { dir.appendingPathComponent($0) }
            .filter { Self.isRecent($0) }
        guard let newest = candidates.max(by: { Self.creation($0) < Self.creation($1) }) else { return }
        Task { await capture(image: newest) }
    }

    // MARK: - Capture

    /// A directory event fires when the entry is CREATED, not when the
    /// writer is finished with it. Copying immediately can capture a
    /// truncated or zero-byte file — likelier the bigger the display and
    /// the slower (or more network-backed) the disk. Wait for the size to
    /// stop moving.
    private static func settled(_ url: URL) async -> Bool {
        func size() -> Int? {
            (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }
        var last = size()
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(150))
            let now = size()
            if let now, now > 0, now == last { return true }
            last = now
        }
        return (last ?? 0) > 0
    }

    /// Copy the image into a fresh note and open the context window.
    private func capture(image: URL) async {
        guard await Self.settled(image) else {
            log.info("Screenshot never settled on disk — skipped")
            return
        }
        guard let ticket = SessionsFolder.acquireBase() else {
            log.error("No sessions folder ticket — screenshot note skipped")
            return
        }
        defer { ticket.release() }

        let now = Date()
        // Same shape every other session directory uses
        // (`RecordingSession.makeSessionDirectory`) — ISO-8601 with the
        // colons swapped out — under the SAME `Daisy/Sessions` root that
        // `SessionStore` scans. A note written anywhere else is a note
        // nobody ever sees.
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let safeStamp = stamp.string(from: now).replacingOccurrences(of: ":", with: "-")
        let base = ticket.url.appendingPathComponent("Daisy/Sessions", isDirectory: true)

        let fm = FileManager.default
        // Two screenshots inside one second must both survive — the
        // stamp has second resolution and ⌘⇧3 twice in a row is a
        // normal thing to do.
        var noteDir = base.appendingPathComponent(safeStamp, isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: noteDir.path), suffix < 20 {
            noteDir = base.appendingPathComponent("\(safeStamp)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        guard !fm.fileExists(atPath: noteDir.path) else { return }
        do {
            try fm.createDirectory(at: noteDir, withIntermediateDirectories: true)
        } catch {
            log.error("Screenshot note dir failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // COPY. The original stays where the user put it — this feature
        // is not a file manager, and a screenshot that vanishes from the
        // Desktop because Daisy "helpfully" filed it is a bug report
        // about lost work.
        // `screenshots/NNN.ext`, not a loose file: that folder and the
        // numeric name are the contract `SessionStore.parseSession` and
        // `ScreenshotFile.isFrame` read, and a picture outside it is
        // invisible in the Library — the detail view's strip stays empty
        // and the markdown link renders as literal text.
        let ext = image.pathExtension.isEmpty ? "png" : image.pathExtension.lowercased()
        let imageName = "screenshots/001.\(ext)"
        do {
            try fm.createDirectory(
                at: noteDir.appendingPathComponent("screenshots", isDirectory: true),
                withIntermediateDirectories: true
            )
            try fm.copyItem(at: image, to: noteDir.appendingPathComponent(imageName))
        } catch {
            log.error("Screenshot copy failed: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: noteDir)
            return
        }

        let markdown = Self.renderNote(imageName: imageName, created: now, context: nil)
        do {
            try Data(markdown.utf8).write(
                to: noteDir.appendingPathComponent("transcript.md"), options: .atomic
            )
        } catch {
            log.error("Screenshot note write failed: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: noteDir)
            return
        }

        pending = Pending(noteDirectory: noteDir, imageName: imageName, createdAt: now)
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pendingWindow))
            guard !Task.isCancelled else { return }
            self?.clearPending()
        }

        await SessionStore.shared.refresh()
        log.info("Screenshot note created")

        // The race the 2026-08-21 log report exposed: the screenshot
        // FILE lands seconds after the shot (macOS holds it back for
        // the floating thumbnail), so a fast reaction — screenshot,
        // then immediately hold the dictation key — puts key-down
        // BEFORE this window even opens, and the words sail past the
        // note into the clipboard (15:41: shot at :08, hold at ~:16,
        // note created after — dictation fell to ⌘V in Electron). If a
        // dictation hold is ALREADY live and young, this screenshot is
        // what it's answering: hand the note over now, late.
        if let session = RecordingSession.current,
           session.status == .recording,
           session.currentMode == .dictation,
           session.pendingScreenshotNote == nil,
           session.elapsed < 10 {
            session.pendingScreenshotNote = claimPending()
            log.info("Live dictation hold adopted the fresh screenshot note (held \(Int(session.elapsed), privacy: .public)s)")
            // No "hold your key" pill — they're already holding it; the
            // confirmation pill lands at release via `announceAttached`.
            return
        }

        announceHoldHint()
    }

    /// The "hold your key" offer. Reads the dictation hotkey LIVE from
    /// settings at present time, so the pill always names whatever key
    /// dictation is currently bound to. With no hotkey bound there is
    /// nothing to hold, so say the plain thing instead of pointing at a
    /// key that doesn't exist.
    private func announceHoldHint() {
        guard let note = pending else { return }
        let key = settings?.dictationHotkey
        let message: String
        if let key, key != .none {
            message = String(
                format: String(localized: "Hold %@ to add context"),
                key.label
            )
        } else {
            message = String(localized: "Screenshot saved to Notes")
        }
        announce(message, discarding: note)
    }

    // MARK: - Dictation hand-off

    /// Claim the pending capture for a dictation that is STARTING now.
    /// Called at key-down: a hold that begins inside the window owns the
    /// note however long the person keeps talking.
    func claimPending() -> Pending? {
        guard let pending else { return nil }
        expiry?.cancel()
        expiry = nil
        self.pending = nil
        // The person is answering the prompt RIGHT NOW — freeze the
        // pill's countdown so it can't expire under them mid-sentence.
        // Un-frozen by whatever ends the dictation: attach success
        // presents the confirmation pill, an empty take re-opens the
        // window via `restorePending`, a clipboard fallback dismisses
        // via `withdrawHoldHint`.
        WidgetBubbleCenter.shared.pauseCountdown(tag: Self.bubbleTag)
        log.info("Pending screenshot note claimed by dictation key-down")
        return pending
    }

    /// The claimed dictation produced no usable text — give the window
    /// back whole. Without this, an empty take silently burns the one
    /// chance to attach context (field report, 2026-08-21: «зажимал Fn,
    /// но комментарий не оставился» — and the note was unclaimable
    /// afterwards). Full fresh window + a fresh pill, not the remainder.
    func restorePending(_ p: Pending) {
        pending = p
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pendingWindow))
            guard !Task.isCancelled else { return }
            self?.clearPending()
        }
        log.info("Dictation produced no text — screenshot-note window reopened")
        announceHoldHint()
    }

    /// The claimed dictation went to the clipboard instead (note write
    /// failed with real text) — the frozen "hold" pill is moot and has
    /// no timer left to remove itself.
    func withdrawHoldHint() {
        WidgetBubbleCenter.shared.dismiss(tag: Self.bubbleTag)
    }

    /// Confirm where the words went — same visibility rule as the
    /// prompt: a dictation that vanished from the frontmost app needs to
    /// say where it landed, and it can't say it in a hidden window.
    ///
    /// Carries the trash too, and by then the note HAS the dictated text
    /// in it. Deleting anyway is the point: this pill is the only moment
    /// the note is in front of the person, they are being told a thing
    /// was created, and "no, not that one" has to mean the same thing it
    /// meant one second earlier. A note whose only content is a
    /// screenshot they didn't want plus a sentence about a screenshot
    /// they didn't want is not worth keeping half of.
    func announceAttached(_ pending: Pending) {
        announce(String(localized: "Added to the note"), discarding: pending)
    }

    // MARK: - Throwing it away

    /// Undo the whole capture: stop the dictation that was feeding it,
    /// give back the claim, and remove the note — image and all.
    ///
    /// No confirmation, by design. The artifact is seconds old, it was
    /// created without being asked for, and the pill offering this is
    /// itself the notice that it exists; a dialog in front of "I didn't
    /// want that" would be the second unrequested thing in a row.
    ///
    /// Takes the note EXPLICITLY rather than reading `pending`. The pill
    /// outlives the field twice over — `claimPending` hands the note to
    /// the dictation session and nils it, and the confirmation pill
    /// arrives after even that is gone — so a trash bound to whatever
    /// `pending` happens to hold at click time would be bound to nothing
    /// in exactly the two states where it is most likely to be pressed.
    func discard(_ note: Pending) {
        // 1. The dictation hold that claimed this note has nowhere left to
        //    land. Cancel it whole: letting it finish would either write
        //    the note's markdown back out (`attach` recreates the file) or
        //    paste the words into whatever app is in front — and the
        //    person pressing trash asked for neither.
        //
        //    The claim is cleared FIRST because `reset()` does not clear
        //    it: both the release path and `failFast` would otherwise hand
        //    the deleted note to `restorePending`, which would re-present a
        //    pill for a note that no longer exists.
        //
        //    And clearing the claim is NOT enough on its own. The likeliest
        //    moment for this button is the second after the key comes up,
        //    when the pill is still frozen on screen and `finishDictation`
        //    is suspended inside the ASR pass: `discard()` is a no-op at
        //    `.stopping`, and a nil claim there reads as "ordinary
        //    dictation", so the cancelled sentence would be pasted into
        //    whatever app is in front. `screenshotNoteDiscarded` is what
        //    the finalizer reads to drop the take with the note.
        if let session = RecordingSession.current,
           session.pendingScreenshotNote?.noteDirectory == note.noteDirectory {
            session.pendingScreenshotNote = nil
            session.screenshotNoteDiscarded = true
            // `.dictation` guard on the DISCARD only: nothing else sets
            // that field, but a bug that let a MEETING carry it must not
            // turn this button into "throw away the meeting". A session
            // still starting isn't discardable either (`discard` acts on
            // .recording/.paused) — the flag covers that case.
            if session.currentMode == .dictation {
                Task { await session.discard(announcing: false) }
            }
        }

        // 2. Our own window, for the case where the claim was never taken.
        if pending?.noteDirectory == note.noteDirectory {
            clearPending()
        }

        // 3. The note itself. Trash rather than unlink, matching
        //    `RecordingSession.discard`: nothing here is worth recovering,
        //    but a misfired click on a note that HAD been dictated into is
        //    recoverable for free.
        let ticket = SessionsFolder.acquireBase()
        defer { ticket?.release() }
        let fm = FileManager.default
        do {
            try fm.trashItem(at: note.noteDirectory, resultingItemURL: nil)
        } catch {
            do {
                try fm.removeItem(at: note.noteDirectory)
            } catch {
                log.error("Discarding the screenshot note failed: \(error.localizedDescription, privacy: .public)")
                // By now the hold has been cancelled and the window given
                // up, so silence here would read as "deleted" while the
                // note is still in the Library. Say so where the person
                // actually is — the same surface that offered the button.
                announce(
                    String(localized: "Couldn’t delete the note"),
                    notificationTitle: String(localized: "Couldn’t delete the note")
                )
                return
            }
        }
        // Belt and braces: the panel hides the pill when the button fires,
        // but the center still thinks ours is the bubble on screen.
        WidgetBubbleCenter.shared.dismiss(tag: Self.bubbleTag)
        log.info("Screenshot note discarded from the pill")
        Task { await SessionStore.shared.refresh() }
    }

    /// Write dictated context into a claimed note. Returns whether it
    /// landed — a `false` sends the text to the clipboard as usual, so
    /// nobody's words disappear because a file write failed.
    @discardableResult
    func attach(context: String, to pending: Pending) -> Bool {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let markdown = Self.renderNote(
            imageName: pending.imageName,
            created: pending.createdAt,
            context: trimmed
        )
        do {
            try Data(markdown.utf8).write(
                to: pending.noteDirectory.appendingPathComponent("transcript.md"),
                options: .atomic
            )
        } catch {
            log.error("Attaching context failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        Task { await SessionStore.shared.refresh() }
        log.info("Context attached to screenshot note (\(trimmed.count, privacy: .public) chars)")
        return true
    }

    /// Say it where it can actually be seen.
    ///
    /// A toast lives in the main window's overlay, and a screenshot is BY
    /// DEFINITION taken from another app with Daisy in the background — so
    /// a toast would be invisible in the one case this feature exists for.
    /// The widget bubble floats over every app; `WidgetBubbleCenter` shows
    /// it there when the widget is up, and falls back to a notification
    /// when it isn't. No action button — the affordance is "hold your
    /// dictation key", which is a gesture, not a tap.
    /// Stable bubble tag so claim/restore/withdraw only ever touch the
    /// screenshot-note pill, never an unrelated prompt.
    private static let bubbleTag = "screenshot-note"

    /// Every pill that ANNOUNCES a note carries the trash — each one is
    /// telling the person about something Daisy made without being asked,
    /// and that is the moment to be able to say no. `note: nil` is for the
    /// pills that announce something else (a failure), which have nothing
    /// left to delete.
    ///
    /// The fallback notification never carries it: a banner can't offer
    /// "delete it" and be sure the answer was read, and the artifact is one
    /// Library row away.
    private func announce(
        _ message: String,
        discarding note: Pending? = nil,
        notificationTitle: String = String(localized: "Screenshot saved to Notes")
    ) {
        // Spelled out rather than mapped: the property's type is
        // `(@MainActor () -> Void)?`, and inference through `Optional.map`
        // into an isolated function type is not worth the cleverness.
        var discardAction: (@MainActor () -> Void)?
        if let note {
            discardAction = { [weak self] in self?.discard(note) }
        }
        WidgetBubbleCenter.shared.present(
            WidgetBubbleContent(
                text: message,
                tag: Self.bubbleTag,
                destructiveTitle: note == nil
                    ? nil : String(localized: "Delete this note"),
                destructiveAction: discardAction
            ),
            notificationTitle: notificationTitle
        )
    }

    private func clearPending() {
        expiry?.cancel()
        expiry = nil
        pending = nil
    }

    // MARK: - Note markdown

    /// Obsidian-shaped note: the same minimum frontmatter every other
    /// note carries (`title`, `started`, `daisy_kind: note`) so
    /// SessionStore classifies it `.valid` and the Notes tab lists it.
    /// Rewritten whole when context arrives — the file is a few hundred
    /// bytes and a whole-file atomic write can't half-apply.
    ///
    /// The image link is RELATIVE: the note lives in the same folder, and
    /// a relative link survives the vault being moved or synced.
    nonisolated static func renderNote(imageName: String, created: Date, context: String?) -> String {
        let iso = ISO8601DateFormatter()
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let titleDate = df.string(from: created)

        var lines: [String] = []
        lines.append("---")
        lines.append("title: \"Screenshot — \(titleDate)\"")
        lines.append("started: \(iso.string(from: created))")
        lines.append("duration_sec: 0")
        lines.append("daisy_kind: \(SessionKind.note.rawValue)")
        lines.append("daisy_folder: \(SessionFolder.inbox.slug)")
        lines.append("daisy_screenshot_note: true")
        lines.append("---")
        lines.append("")
        lines.append("# Screenshot — \(titleDate)")
        lines.append("")
        if let context, !context.isEmpty {
            lines.append(context)
            lines.append("")
        }
        lines.append("![\(titleDate)](\(imageName))")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - Where screenshots land

    /// The folder macOS writes screenshots to: whatever the user set with
    /// `defaults write com.apple.screencapture location` (or the
    /// Screenshot app's Options menu), else the Desktop.
    ///
    /// Reading another app's defaults domain is fine here — Daisy is not
    /// sandboxed (see Daisy.entitlements). A path that no longer exists
    /// falls back rather than watching nothing.
    nonisolated static func screenshotFolder() -> URL? {
        if let raw = UserDefaults(suiteName: "com.apple.screencapture")?
            .string(forKey: "location"), !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    /// Image files currently in `dir`. Names only — cheap to diff, and we
    /// never read the contents of anything we didn't just see appear.
    ///
    /// Extension-based, deliberately NOT name-based: macOS localises the
    /// "Screenshot …" prefix, so matching it would work in English and
    /// silently do nothing in Russian. The cost is that an image SAVED to
    /// this folder by something else looks the same as a screenshot —
    /// which is why the folder being the screenshot folder is doing the
    /// real work here, and why bursts are ignored.
    nonisolated private static func imageNames(in dir: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.filter { name in
            let ext = (name as NSString).pathExtension.lowercased()
            // Screenshot formats only. The screenshot folder is usually
            // the Desktop, and a Desktop holds invoices, contracts and
            // scans; copying a PDF into a synced vault because it landed
            // next to a screenshot is not a feature.
            return ["png", "jpg", "jpeg"].contains(ext)
        })
    }

    nonisolated private static func creation(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
    }

    /// Guards against a folder event that surfaces an OLD file (a sync
    /// client rewriting metadata, an editor touching a file). A
    /// screenshot is seconds old by the time we see it.
    nonisolated private static func isRecent(_ url: URL) -> Bool {
        Date().timeIntervalSince(creation(url)) < 20
    }
}
