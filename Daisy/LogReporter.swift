//
//  LogReporter.swift
//  Daisy
//
//  Two ways out of the same report — the last 24 h of Daisy's os.log
//  output (`/usr/bin/log show`, our subsystem only) plus an environment
//  header (app/macOS versions, permission states, the handful of
//  settings that change audio/ML behaviour):
//
//    • `sendReport` — Help → "Send Log Report…": writes a temp file and
//      opens a pre-addressed Mail compose window with the report
//      attached and the questions in the body.
//    • `exportLogs` — Help → "Export Logs…": writes the file where the
//      user says and reveals it. Nothing else. For anyone whose mail is
//      in a browser, or who just wants to hand over the log.
//
//  Neither one sends anything: Mail waits on the user pressing Send, and
//  the export just puts a file on disk. Nothing leaves the Mac without an
//  explicit, visible action, consistent with "nothing leaves your Mac".
//
//  Why `log show` and not OSLogStore: OSLogStore's process scope only
//  covers the CURRENT launch, while tester reports are usually about
//  a session that ended (or a copy that crashed) earlier today.
//  `log show` reads the persisted store across launches. Trade-off:
//  info/debug lines are best-effort (the in-memory window rotates),
//  errors/faults are always there. Anything marked privacy-private
//  comes out as `<private>` — the report is privacy-safe by
//  construction.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum LogReporter {
    /// Where tester reports go. Single hard-coded recipient on
    /// purpose — this is a built-in feedback channel, not a generic
    /// share sheet.
    private static let recipient = "support@mydaisy.io"
    /// Cap the attachment at ~5 MB — `log show --info --debug` over a
    /// chatty day can balloon, and mail providers bounce huge mails.
    /// We keep the TAIL (most recent lines) when trimming.
    /// `nonisolated`: read from the off-main log-collection closure;
    /// immutable Int, so opting out of the enum's MainActor isolation
    /// is safe.
    nonisolated private static let maxLogBytes = 5_000_000

    /// Collect → write temp file → open Mail compose.
    ///
    /// Mail is the convenient path, not the only one — see `exportLogs`.
    /// `canPerform` only tells us Mail.app EXISTS, not that it has an
    /// account, so this can still land a user in a compose window they
    /// can't send from (Ken, 2026-07-28: "it keeps trying to open the
    /// local mail client which I'm not signed into"). There's no API for
    /// "is Mail signed in", hence a second, visible action rather than a
    /// cleverer guess.
    static func sendReport(settings: AppSettings) {
        Task {
            guard let text = await collectReport(settings: settings),
                  let fileURL = writeTempReport(text) else { return }
            let body = reportBody()
            let service = NSSharingService(named: .composeEmail)
            service?.recipients = [recipient]
            service?.subject = subject()
            let items: [Any] = [body, fileURL]
            if let service, service.canPerform(withItems: items) {
                service.perform(withItems: items)
                ToastCenter.shared.show(
                    String(localized: "Report ready in Mail — just press Send."),
                    style: .info
                )
            } else {
                // No mail client at all. This is the ONE place the
                // clipboard earns its keep: there is no compose window to
                // put the questions in, so without it the reporter is left
                // with a log file and no idea what to write around it.
                copyQuestionsToClipboard(body)
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                ToastCenter.shared.show(
                    String(localized: "No mail app set up — the report is in Finder and the questions are on your clipboard. Send both to \(recipient)."),
                    style: .warning,
                    duration: .seconds(10)
                )
            }
        }
    }

    /// Collect → write the file where the user points → reveal it.
    ///
    /// One job, no side effects. The previous version of this also put the
    /// question template on the clipboard, which turned out to be actively
    /// misleading: it looks like the button's output, so you paste it,
    /// get a form with no diagnostics, and conclude the export is broken —
    /// "скопировался только шаблон, без логов, а самое важное, это логи"
    /// (Egor, 2026-07-28). The logs ARE the deliverable; the questions
    /// belong to the Mail path, which has a body to put them in.
    static func exportLogs(settings: AppSettings) {
        Task {
            guard let text = await collectReport(settings: settings) else { return }
            let panel = NSSavePanel()
            if let txt = UTType(filenameExtension: "txt") {
                panel.allowedContentTypes = [txt]
            }
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = reportFilename()
            panel.title = String(localized: "Export Logs")
            panel.message = String(localized: "Daisy's last 24 hours of logs, plus a short environment header.")
            // No `directoryURL`: the panel remembers where this app saved
            // last, which beats dragging the user back to Downloads every
            // time.
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            do {
                // Straight to the destination, atomically — no temp file to
                // leak and no remove-then-copy window where a failed copy
                // leaves the user with neither the old file nor the new one.
                try text.write(to: destination, atomically: true, encoding: .utf8)
            } catch {
                ToastCenter.shared.show(
                    String(localized: "Couldn't save the log file: \(error.localizedDescription)"),
                    style: .error
                )
                return
            }
            // Reveal rather than just toast: the point of the button is to
            // end up holding the file.
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            ToastCenter.shared.show(
                String(localized: "Logs exported to \(destination.lastPathComponent)."),
                style: .info,
                duration: .seconds(6)
            )
        }
    }

    // MARK: - Shared steps

    /// Collect the logs and assemble the full report text. Returns nil
    /// only if something went wrong loudly enough to toast about.
    private static func collectReport(settings: AppSettings) async -> String? {
        ToastCenter.shared.show(
            String(localized: "Collecting today's logs…"),
            style: .info,
            duration: .seconds(3)
        )
        let logText = await collectLogs()
        return header(settings: settings) + "\n" + logText
    }

    /// Park the report in a temp file so Mail has something to attach.
    /// Only the Mail path needs this — `exportLogs` writes straight to
    /// the user's chosen destination, so nothing is left behind when the
    /// save panel is cancelled.
    private static func writeTempReport(_ text: String) -> URL? {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(reportFilename())
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            ToastCenter.shared.show(
                String(localized: "Couldn't write the log report: \(error.localizedDescription)"),
                style: .error
            )
            return nil
        }
    }

    private static func copyQuestionsToClipboard(_ body: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
    }

    private static func dateStamp() -> String {
        ISO8601DateFormatter.daisyDayStamp.string(from: Date())
    }

    private static func reportFilename() -> String {
        "Daisy-log-report-\(dateStamp()).txt"
    }

    /// Subject stays English on purpose: it's the triage line in the
    /// maintainer's inbox, and version + date must be greppable
    /// regardless of the reporter's language.
    private static func subject() -> String {
        "Daisy log report — \(appVersionString) — \(dateStamp())"
    }

    // MARK: - The questions

    /// Pre-filled body of the report mail. Localized, so a reporter on a
    /// Russian interface gets Russian questions — a form in a language
    /// you don't read gets answered with one vague line, which is how we
    /// ended up guessing at "звонок не записывался" with four sessions in
    /// the log and no way to tell which one.
    ///
    /// Five questions, and the reason each one earns its line:
    ///  1. what/expected — the report itself.
    ///  2. WHEN + which app — the log holds a whole day; without a time
    ///     we can't tell which SESSION SUMMARY is the failing one, and
    ///     system-audio capture behaves differently per meeting app.
    ///  3. headphones — the top confounder by far. Bluetooth output
    ///     alone kills system audio and drags the mic to silence; the
    ///     header's route line is captured when the mail is composed,
    ///     which can be hours after the call with other gear plugged in.
    ///  4. what was MISSING — audio, transcript and summary fail through
    ///     different code paths, and "didn't record" reads the same for
    ///     all three.
    ///  5. speaking or listening — decides whether to suspect the mic
    ///     path or the system-audio path.
    ///
    /// The questions come FIRST and the attachment note last: reporters
    /// type at the very top of the mail, so the top of the body has to be
    /// question 1 rather than a preamble (the previous template put
    /// boilerplate there and got answered above it).
    private static func reportBody() -> String {
        let questions = [
            String(localized: "1. What happened, and what you expected instead:"),
            String(localized: "2. When was the call, and in which app (Zoom, Meet, Teams…):"),
            String(localized: "3. Headphones / mic / speakers at the time — model, and wired or Bluetooth:"),
            String(localized: "4. What was missing: the audio recording, the transcript, the summary, or all of it:"),
            String(localized: "5. Were you speaking, or mostly listening:"),
        ]
        // Two blank lines under each question so there's visible room to
        // type below it rather than beside it.
        let form = questions.joined(separator: "\n\n\n")
        let footer = [
            // Explicitly optional: Daisy's promise is that nothing leaves
            // the Mac unless the user sends it, so the transcript is an
            // offer, never an expectation.
            String(localized: "If you can share it, attach the session folder or just the transcript — that's the fastest way to see what Daisy actually heard."),
            String(localized: "The attached log covers the last 24 hours. It holds diagnostics only — no transcript text."),
        ].joined(separator: "\n")
        return "\(form)\n\n\u{2014}\n\(footer)\n"
    }

    // MARK: - Pieces

    /// `log show --last 24h` for our subsystem, off the main actor.
    /// Daisy is non-sandboxed, so spawning /usr/bin/log is fine.
    nonisolated private static func collectLogs() async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
                process.arguments = [
                    "show", "--last", "24h", "--info", "--debug",
                    "--predicate", "subsystem == \"app.essazanov.Daisy\"",
                    "--style", "compact",
                ]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "(log show failed to launch: \(error.localizedDescription))")
                    return
                }
                // Read BEFORE waitUntilExit — `log show` output easily
                // exceeds the 64 KB pipe buffer, and waiting first
                // deadlocks: the child blocks on a full pipe, we block
                // on the child.
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                var text = String(data: data, encoding: .utf8) ?? "(log output was not valid UTF-8)"
                if text.utf8.count > maxLogBytes {
                    // Keep the most recent tail — that's where the
                    // session being reported on lives.
                    text = "(trimmed to the most recent \(maxLogBytes / 1_000_000) MB)\n"
                        + String(decoding: Array(text.utf8.suffix(maxLogBytes)), as: UTF8.self)
                }
                continuation.resume(returning: text.isEmpty ? "(no log entries in the last 24 h)" : text)
            }
        }
    }

    /// Environment block that makes a report actionable without a
    /// follow-up email: versions, permissions, the settings that
    /// change audio/ML behaviour. No transcript content, no titles.
    ///
    /// `ScreenRec:` earns its own line even though `Permissions:`
    /// already carries `screenRec=`, for the same reason `Disk:` does:
    /// the one-word state is not the diagnosis. "denied" alone cannot
    /// tell a user who never granted it from one whose grant macOS
    /// silently reset — and the second is what happened on the 27.0
    /// beta, costing two meetings that recorded mic-only. This line
    /// carries the grant HISTORY and the count of sessions that
    /// degraded because of it. See
    /// `ScreenRecordingPermission.diagnosticsLine`.
    private static func header(settings: AppSettings) -> String {
        let permissions = SystemPermissions.shared
        permissions.refresh()
        return """
        ── Daisy log report ─────────────────────────────
        Generated:  \(Date().formatted(date: .abbreviated, time: .standard))
        App:        \(appVersionString)
        macOS:      \(ProcessInfo.processInfo.operatingSystemVersionString)
        Permissions: mic=\(label(permissions.microphone)) screenRec=\(label(permissions.screenRecording)) accessibility=\(label(permissions.accessibility)) calendar=\(label(permissions.calendar)) notifications=\(label(permissions.notifications))
        Audio:      captureSystemAudio=\(settings.captureSystemAudio) liveTier=\(settings.liveTranscriptionTier) dictationEngine=\(settings.dictationEngine.rawValue) nemotronLivePreview=\(settings.dictationUseNemotronLive)
        Disk:       \(diskLine())
        ScreenRec:  \(ScreenRecordingPermission.diagnosticsLine())
        Locale:     ui=\(Bundle.main.preferredLocalizations.first ?? "?") summaryLanguage=\(settings.summaryLanguage.isEmpty ? "auto" : settings.summaryLanguage)
        Route:      \(AudioInputDevices.routeDiagnostics(selectedMicUID: settings.selectedMicDeviceUID))
        Mic device: \(AudioInputDevices.describe(AudioInputDevices.systemDefaultInputID()))
        Bundle:     \(Bundle.main.bundleURL.path)
        Auto-stop:  fromCalendar=\(settings.autoStopFromCalendar) graceSec=\(settings.autoStopGraceSec) promptMode=\(settings.autoStopPromptMode) notifyOnStop=\(settings.notifyOnAutoStop)
        Layout fix: auto=\(settings.layoutFixAuto) hotkey=\(settings.layoutFixHotkey.label) switchSource=\(settings.layoutFixSwitchesSource) running=\(LayoutAutoFix.shared.isRunning) suspendedFor=\(LayoutAutoFix.shared.conflictingSwitcherName ?? "—") \(LayoutFix.diagnostics())
        Versions:   \(VersionInfo.versionTrailLine())
        Updates:    \(updaterLine())
        ─────────────────────────────────────────────────
        """
    }

    /// Free space, plus an explicit verdict when it's under the floor
    /// that silently turns meetings transcript-only.
    ///
    /// Worth its own line because a full disk doesn't look like a disk
    /// problem in the log: archiving is skipped by design, so BOTH
    /// archives report zero frames and zero write errors, the post-stop
    /// audit calls that `.empty` / `.truncated`, and the report reads
    /// exactly like a dead microphone. 2026-07-27: cost a full
    /// investigation on a report where the real cause was 0.4 GB free —
    /// the only hint in the whole log was a Whisper download refusing to
    /// start. Measures the volume recordings actually land on, so a
    /// sessions folder on an external disk reports that disk, not the
    /// boot drive.
    private static func diskLine() -> String {
        guard let free = DiskSpace.recordingsVolumeFreeBytes() else { return "unknown" }
        let gb = 1_073_741_824.0
        let line = String(format: "%.1f GB free", Double(free) / gb)
        guard free < DiskSpace.recordingFloorBytes else { return line }
        return line + String(
            format: " — BELOW the %.1f GB floor: meetings record TRANSCRIPT-ONLY, no audio archive",
            Double(DiskSpace.recordingFloorBytes) / gb
        )
    }

    /// Sparkle updater state — the single most-asked "why didn't it
    /// update?" follow-up, surfaced so the answer is in the report
    /// itself: whether automatic checks are on, when the last one ran,
    /// whether the user opted into the beta channel, and the feed URL
    /// the app is actually pointed at. Reads `SparkleUpdater.shared`
    /// (real impl or the no-Sparkle stub — both expose these four).
    private static func updaterLine() -> String {
        let u = SparkleUpdater.shared
        let last = u.lastUpdateCheckDate.map {
            $0.formatted(date: .abbreviated, time: .shortened)
        } ?? "never"
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "?"
        return "autoCheck=\(u.automaticallyChecksForUpdates) betaChannel=\(u.receiveBetaUpdates) lastCheck=\(last) canCheck=\(u.canCheckForUpdates) feed=\(feed)"
    }

    private static var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private static func label(_ status: SystemPermissions.Status) -> String {
        switch status {
        case .notDetermined: return "notAsked"
        case .granted:       return "granted"
        case .denied:        return "denied"
        case .restricted:    return "restricted"
        case .insufficient:  return "writeOnly"
        }
    }
}

private extension ISO8601DateFormatter {
    /// `2026-06-12` — filename-safe day stamp.
    static let daisyDayStamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()
}
