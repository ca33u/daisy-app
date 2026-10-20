//
//  SessionDiagnosticsLog.swift
//  Daisy
//
//  An excerpt of Daisy's own os.log kept next to the recording it is
//  about (backlog 32 B-3, 20.10.2026).
//
//  Why the log report loses the lines that matter. `log show` (what
//  Send Log Report runs) reads two different stores. Default (`.notice`),
//  Error and Fault entries are persisted by logd to disk and survive for
//  days. Info entries are kept in logd's in-memory ring only — shared by
//  every process on the Mac — and roll out within minutes on a busy
//  system: user log A (19.10) was generated at 16:14 and held Info lines
//  from 16:01 on, Default and Error lines from 12:59. Debug entries are
//  dropped by libtrace before they reach logd at all unless the
//  subsystem is explicitly enabled, so no report has ever held one.
//  Nearly everything a recording says about itself — "Import job
//  started", the Whisper passes, the queue's status, the route changes
//  the tap rode out — is Info, so a report sent hours after a call
//  carries only its post-stop SESSION SUMMARY and its errors. User
//  log B (a 77-minute call, reported hours later) had none of the
//  call's own Info lines; user log A's queue run looked like idle time.
//
//  What this does about it. While a recording runs, every five minutes,
//  at Stop, when its finalize ends and after each queue job on its
//  folder, the entries Daisy logged since the last capture are read
//  back out of OSLogStore (the current process, our subsystem — the
//  same lines `log show` would print, in the same compact layout) and
//  appended to `<session>/diagnostics.log`. The first capture reaches
//  one minute before Record, for the setup lines. The file is capped at
//  2 MB with the newest lines winning, and the log report attaches it
//  for the last three recordings — see `LogReporter`.
//
//  Privacy is the log's own: a `<private>` argument is redacted inside
//  the logging process before logd ever sees it, so OSLogStore hands
//  back the same `<private>` the report shows. No transcript text, no
//  titles — Daisy never logs them in the clear. The file is visible on
//  purpose (a person can read what Daisy saw), ignored by the Library
//  scan, which only looks at transcript.md, the audio and the markers,
//  and it travels with the folder: an exported session archive, or the
//  same folder on another Mac through iCloud, keeps it.
//

import Foundation
import OSLog

/// The pure parts: the file's layout, the compact line format, the cap
/// and the capture window. Tested without logd.
nonisolated enum DiagnosticsLog {
    static let fileName = "diagnostics.log"
    static let subsystem = "app.essazanov.Daisy"
    /// Newest lines win: the end of a recording is what reports are about.
    static let maxBytes = 2_000_000
    /// How far before Record the first capture reaches — the route and
    /// device setup lines land just before `startedAt`.
    static let leadIn: TimeInterval = 60
    /// Between captures during a recording. Shorter than the Info ring
    /// lasted on user log A's Mac (about 13 minutes), with room to spare
    /// for a chattier day.
    static let captureInterval: TimeInterval = 300
    static let headerPrefix = "── Daisy diagnostics"

    /// First line of the file. Carries no folder name: folders can be
    /// renamed to anything, and the report quotes this file verbatim.
    static func header(recordingStartedAt: Date, appVersion: String) -> String {
        "\(headerPrefix) — recording started \(timestamp(recordingStartedAt)) — app \(appVersion) — os_log excerpt, newest 2 MB kept ──"
    }

    /// Marks where one capture ends and the next begins, so a reader can
    /// tell a quiet recording from a capture that never ran.
    static func captureMarker(at date: Date, reason: String) -> String {
        "── captured \(timestamp(date)) (\(reason)) ──"
    }

    /// `log show --style compact`'s layout, so a diagnostics.log reads
    /// like the report it is attached to:
    /// `2026-10-19 12:59:55.396 Df Daisy[49731:167af4e] [app.essazanov.Daisy:SystemAudio] message`.
    static func line(
        date: Date, levelTag: String, process: String, pid: Int32, tid: UInt64,
        subsystem: String, category: String, message: String
    ) -> String {
        "\(timestamp(date)) \(levelTag.padding(toLength: 2, withPad: " ", startingAt: 0)) \(process)[\(pid):\(String(tid, radix: 16))] [\(subsystem):\(category)] \(message)"
    }

    /// The two-letter type column of the compact style.
    static func levelTag(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "Db"
        case .info: "I"
        case .notice: "Df"
        case .error: "E"
        case .fault: "F"
        case .undefined: "?"
        @unknown default: "?"
        }
    }

    /// Local time with milliseconds, as `log show` prints it.
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    /// Where a capture starts: after the last entry already in the file
    /// when one is known, else the window the caller asked for. A queue
    /// job hours later asks from its own start; the same launch's
    /// finalize asks from where Stop left off.
    static func captureStart(cursor: Date?, requested: Date) -> Date {
        guard let cursor else { return requested }
        return max(cursor, requested)
    }

    /// Whether an entry belongs to a capture over `(after, until]`.
    static func includes(entryDate: Date, after: Date, until: Date) -> Bool {
        entryDate > after && entryDate <= until
    }

    /// The file's next contents: its header kept (or `header` when the
    /// file is new or lost its own), the new lines appended, the body
    /// trimmed from the top to `maxBytes` at a line boundary.
    static func merged(existing: String?, header: String, newLines: [String]) -> String {
        var body = ""
        var keptHeader = header
        if let existing, !existing.isEmpty {
            let split = existing.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            if let first = split.first, first.hasPrefix(headerPrefix) {
                keptHeader = String(first)
                body = split.count > 1 ? String(split[1]) : ""
            } else {
                body = existing
            }
        }
        if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
        if !newLines.isEmpty { body += newLines.joined(separator: "\n") + "\n" }
        return keptHeader + "\n" + trimmedTail(body, maxBytes: maxBytes)
    }

    /// The newest `maxBytes` of `body`, cut at a line boundary and
    /// marked, so the cap never leaves half a line at the top.
    static func trimmedTail(_ body: String, maxBytes: Int) -> String {
        let bytes = body.utf8
        guard bytes.count > maxBytes else { return body }
        let tail = String(decoding: Array(bytes.suffix(maxBytes)), as: UTF8.self)
        let afterFirstBreak = tail.firstIndex(of: "\n").map { tail.index(after: $0) } ?? tail.endIndex
        return "(trimmed to the most recent \(maxBytes / 1_000_000) MB)\n" + tail[afterFirstBreak...]
    }
}

/// Reads the entries back from logd and keeps the file. One per launch:
/// the cursor of every folder captured this launch lives here, so a
/// finalize or a queue job on a folder Stop already captured appends
/// only what came after.
actor SessionDiagnosticsLog {
    static let shared = SessionDiagnosticsLog()

    private let log = Logger(subsystem: DiagnosticsLog.subsystem, category: "Diagnostics")
    /// Session folder path → date of the last entry written there this launch.
    private var cursors: [String: Date] = [:]
    /// Folder path → when its recording started, for the header.
    private var recordingStarts: [String: Date] = [:]
    private var periodic: Task<Void, Never>?
    /// Whose loop `periodic` is, so a late `end` for the previous
    /// recording can't stop the next one's.
    private var periodicKey: String?

    /// Record pressed: capture the minute before it, then every five
    /// minutes until `end`. A new recording replaces the previous loop.
    func begin(directory: URL, recordingStartedAt: Date) {
        periodic?.cancel()
        let key = directory.path
        periodicKey = key
        recordingStarts[key] = recordingStartedAt
        cursors[key] = nil
        capture(directory: directory, from: recordingStartedAt.addingTimeInterval(-DiagnosticsLog.leadIn), reason: "recording started")
        periodic = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(DiagnosticsLog.captureInterval))
                guard !Task.isCancelled, let self else { return }
                // A husk removed at Stop (<10 s, nothing captured) takes
                // its folder with it: nothing to write into, stop looping.
                guard FileManager.default.fileExists(atPath: directory.path) else { return }
                await self.capture(directory: directory, from: recordingStartedAt, reason: "periodic")
            }
        }
    }

    /// Stop pressed: the loop ends and the post-stop lines are captured.
    func end(directory: URL) {
        if periodicKey == directory.path {
            periodic?.cancel()
            periodic = nil
            periodicKey = nil
        }
        capture(directory: directory, from: Date(), reason: "stop")
    }

    /// Finalize ended, or a queue job on this folder ended: everything
    /// since the last capture — or, with no capture this launch, since
    /// `from`.
    func captureWindow(directory: URL, from: Date, reason: String) {
        capture(directory: directory, from: from, reason: reason)
    }

    private func capture(directory: URL, from requested: Date, reason: String) {
        let key = directory.path
        let after = DiagnosticsLog.captureStart(cursor: cursors[key], requested: requested)
        let until = Date()
        var lines: [String] = []
        var last: Date?
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: after)
            let predicate = NSPredicate(format: "subsystem == %@", DiagnosticsLog.subsystem)
            for entry in try store.getEntries(with: [], at: position, matching: predicate) {
                guard let entry = entry as? OSLogEntryLog,
                      DiagnosticsLog.includes(entryDate: entry.date, after: after, until: until) else { continue }
                lines.append(DiagnosticsLog.line(
                    date: entry.date, levelTag: DiagnosticsLog.levelTag(entry.level),
                    process: entry.process, pid: entry.processIdentifier, tid: entry.threadIdentifier,
                    subsystem: entry.subsystem, category: entry.category, message: entry.composedMessage
                ))
                last = entry.date
            }
        } catch {
            log.error("Diagnostics: OSLogStore read failed (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !lines.isEmpty else { return }
        let fileURL = directory.appendingPathComponent(DiagnosticsLog.fileName)
        // A file synced from another Mac and evicted by "Optimize Mac
        // Storage" would block here on a download; start over instead.
        let existing = SessionStore.isCloudEvicted(fileURL)
            ? nil
            : try? String(contentsOf: fileURL, encoding: .utf8)
        let header = DiagnosticsLog.header(
            recordingStartedAt: recordingStarts[key] ?? requested,
            appVersion: Self.appVersion
        )
        let text = DiagnosticsLog.merged(
            existing: existing, header: header,
            newLines: [DiagnosticsLog.captureMarker(at: until, reason: reason)] + lines
        )
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            cursors[key] = last
        } catch {
            // Info on purpose: the folder may be gone (husk, deleted
            // from the Library) and this must not become the loudest
            // line of the recording it is about.
            log.info("Diagnostics: not written (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
