//
//  ImportTranscriptionQueue.swift
//  Daisy
//
//  The persistent queue behind audio import (design 2026-08-31 §3,
//  phase Ф2). Copying files into sessions is instant and happens at
//  drop time (security-scoped access does not survive until tonight);
//  what waits is the TRANSCRIPTION — hours of Whisper for a batch of
//  interviews. This queue holds those jobs.
//
//  Requirements Egor set:
//    • the live recording always wins — a job waits for the recording
//      AND its finalisation to end; that is a pause, never an error;
//    • one job at a time, sharing `SessionAudioProcessing.isRunning` with
//      manual "Transcribe audio" rather than competing with it;
//    • survives quitting: `import-queue.json` in Application Support. A
//      job interrupted by a quit simply runs again at next launch — the
//      session already exists and stays `.audioOnly` until then, so the
//      worst case reads as "imported, not yet transcribed", never as loss;
//    • "tonight at HH:MM" is a `notBefore` date on the job; the driver
//      is a poll (EndOfDaySummaries pattern), not a Timer aimed at 03:00 —
//      a Timer neither fires through sleep nor exists after a quit.
//

import CryptoKit
import Foundation
import Observation
import os

nonisolated struct ImportTranscriptionJob: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let sessionID: String
    /// Session directory path at enqueue time. The store is looked up by
    /// id first; the path is the fallback for a session the Library has
    /// not re-scanned yet, and the way to notice a deleted session.
    let directoryPath: String
    let title: String
    let modelID: String
    let language: String
    let diarize: Bool
    /// Earliest time the job may run; nil = as soon as the pipeline is free.
    var notBefore: Date?
    let createdAt: Date
    var attempts: Int
    var lastError: String?
    /// A recording whose final pass was cut short by the next recording
    /// (incident 23.09): it already has the live transcript, which this
    /// job REPLACES in place. Optional so older queue files still decode.
    var finishesLiveTranscript: Bool?
    /// «Process later, on a charger» (07.10.2026): the job waits while
    /// the Mac is on battery or in Low Power Mode. Cleared by «Process
    /// now». Optional so older queue files still decode.
    var waitsForPower: Bool?
    /// Hash of the draft transcript's BODY at enqueue (frontmatter left
    /// out: renaming, tagging, moving or naming speakers rewrites it, and
    /// the final pass keeps all of those). A different body at run time
    /// means the person edited the draft — their text wins.
    var draftBodyHash: String?

    nonisolated static let maxAttempts = 3

    var options: SessionRetranscriptionOptions {
        SessionRetranscriptionOptions(modelID: modelID, language: language, diarize: diarize)
    }
}

@Observable
@MainActor
final class ImportTranscriptionQueue {
    static let shared = ImportTranscriptionQueue()

    private(set) var jobs: [ImportTranscriptionJob] = []
    /// Job currently inside `retranscribe`, if any.
    private(set) var activeJobID: UUID?

    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "ImportQueue")
    @ObservationIgnored
    private var timer: Timer?
    @ObservationIgnored
    private var runTask: Task<Void, Never>?
    @ObservationIgnored
    private let fileURL: URL
    /// Set when the active job was cancelled because a recording
    /// started (keep the job) rather than by the user (job removed).
    @ObservationIgnored
    private var preempted = false

    private init() {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        fileURL = appSupport
            .appendingPathComponent("Daisy", isDirectory: true)
            .appendingPathComponent("import-queue.json")
        jobs = Self.load(from: fileURL)
        // A job that was mid-flight when the app quit is not "active"
        // any more; whatever it wrote is in a hidden staging dir that
        // retranscribe discards. Let it run again.
    }

    // MARK: - Wiring

    /// Start polling. Idempotent. The first tick runs immediately so a
    /// queue restored at launch doesn't wait a minute.
    func start() {
        guard timer == nil else { return }
        // A charger plugged in (or Low Power Mode off) is the moment the
        // waiting jobs may go — don't make them wait for the next poll.
        PowerState.shared.onChange = { [weak self] in self?.tick() }
        PowerState.shared.start()
        // One minute: a queue item is minutes-to-hours of work, and the
        // "tonight" trigger is an HH:MM boundary — finer polling buys
        // nothing.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        armPreemption()
        // Not immediately: launch already runs crash recovery and the
        // first Library scan; a restored job loading a Whisper model on
        // top of that would contend with both.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.tick()
        }
    }

    /// "The live recording always wins" — at job START the tick guard
    /// handles it; a job already inside Whisper is pre-empted here the
    /// moment a recording begins, and re-run later (an interrupted
    /// retranscribe discards its hidden staging, so nothing is lost).
    private func armPreemption() {
        withObservationTracking {
            _ = SessionAudioProcessing.shared.recordingOrFinalizeIsActive
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.activeJobID != nil, SessionAudioProcessing.shared.recordingOrFinalizeIsActive {
                    self.log.info("Import job pre-empted by a recording")
                    self.preempted = true
                    self.runTask?.cancel()
                }
                self.armPreemption()
            }
        }
    }

    /// Re-evaluate now (e.g. the import batch just finished copying).
    func kick() { tick() }

    // MARK: - Enqueue / inspect

    func enqueue(
        sessionID: String,
        directoryURL: URL,
        title: String,
        options: SessionRetranscriptionOptions,
        notBefore: Date?,
        finishesLiveTranscript: Bool = false,
        waitsForPower: Bool = false
    ) {
        // One job per session: a second drop of the same session (or a
        // re-run of "Transcribe now") replaces the old schedule.
        jobs.removeAll { $0.sessionID == sessionID && $0.id != activeJobID }
        jobs.append(ImportTranscriptionJob(
            id: UUID(),
            sessionID: sessionID,
            directoryPath: directoryURL.path,
            title: title,
            modelID: options.modelID,
            language: options.language,
            diarize: options.diarize,
            notBefore: notBefore,
            createdAt: Date(),
            attempts: 0,
            lastError: nil,
            finishesLiveTranscript: finishesLiveTranscript ? true : nil,
            waitsForPower: waitsForPower ? true : nil,
            draftBodyHash: finishesLiveTranscript ? Self.transcriptBodyHash(in: directoryURL) : nil
        ))
        persist()
        tick()
    }

    func job(forSession sessionID: String) -> ImportTranscriptionJob? {
        jobs.first { $0.sessionID == sessionID }
    }

    func cancel(sessionID: String) {
        guard let job = jobs.first(where: { $0.sessionID == sessionID }) else { return }
        if job.id == activeJobID {
            runTask?.cancel()
        }
        jobs.removeAll { $0.sessionID == sessionID }
        persist()
    }

    /// «Process now»: drop the power wait and any schedule, move the job
    /// to the front, and start it if the pipeline is free.
    func runNow(sessionID: String) {
        guard let index = jobs.firstIndex(where: { $0.sessionID == sessionID }),
              jobs[index].id != activeJobID else { return }
        var job = jobs.remove(at: index)
        job.waitsForPower = nil
        job.notBefore = nil
        jobs.insert(job, at: 0)
        persist()
        tick()
    }

    /// Whether a job may start now: its time has come and, if it waits
    /// for power, the Mac is on a charger without Low Power Mode.
    private func isReady(_ job: ImportTranscriptionJob, now: Date) -> Bool {
        guard (job.notBefore ?? .distantPast) <= now else { return false }
        return job.waitsForPower != true || !PowerState.shared.isConstrained
    }

    var pendingCount: Int { jobs.count }

    /// What the Library's status line should say, or nil when idle.
    var statusLine: String? {
        guard !jobs.isEmpty else { return nil }
        if let activeJobID, let job = jobs.first(where: { $0.id == activeJobID }) {
            let position = (jobs.firstIndex(where: { $0.id == activeJobID }) ?? 0) + 1
            let inner = SessionAudioProcessing.shared.statusText
            let head = String(localized: "Transcribing \(position) of \(jobs.count) · \(job.title)")
            // The percent first: the line is cut in the middle when the
            // column is narrow, and the number is what the person looks for.
            if let progress = SessionAudioProcessing.shared.progress {
                return "\(Int(progress * 100))% · \(head)"
            }
            return inner.isEmpty ? head : "\(head) — \(inner)"
        }
        if SessionAudioProcessing.shared.recordingOrFinalizeIsActive {
            return String(localized: "\(jobs.count) waiting for the recording to finish")
        }
        let now = Date()
        let ready = jobs.filter { isReady($0, now: now) }
        if ready.isEmpty, PowerState.shared.isConstrained, jobs.allSatisfy({ $0.waitsForPower == true }) {
            return String(localized: "\(jobs.count) waiting for a charger")
        }
        if ready.isEmpty, let next = jobs.compactMap(\.notBefore).min() {
            return String(localized: "\(jobs.count) scheduled for \(Self.timeFormatter.string(from: next))")
        }
        if SessionAudioProcessing.shared.isRunning {
            return String(localized: "\(jobs.count) waiting for the current transcription")
        }
        return String(localized: "\(jobs.count) queued for transcription")
    }

    /// Row-level label for one session, or nil when it isn't queued.
    func rowLabel(forSession sessionID: String) -> String? {
        guard let job = job(forSession: sessionID) else { return nil }
        if job.id == activeJobID {
            if let progress = SessionAudioProcessing.shared.progress {
                return String(localized: "Transcribing… \(Int(progress * 100))%")
            }
            return String(localized: "Transcribing…")
        }
        if let notBefore = job.notBefore, notBefore > Date() {
            return String(localized: "Transcribes at \(Self.timeFormatter.string(from: notBefore))")
        }
        if job.waitsForPower == true, PowerState.shared.isConstrained {
            return String(localized: "Processes when the Mac is on a charger")
        }
        return String(localized: "Queued for transcription")
    }

    /// Main-actor only: DateFormatter is not Sendable.
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// Next occurrence of `hour:minute` — today if still ahead, else
    /// tomorrow. Used by the import dialog's "tonight" option.
    nonisolated static func nextOccurrence(hour: Int, minute: Int, after now: Date = Date()) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        guard let today = cal.date(from: comps) else { return now }
        if today > now { return today }
        return cal.date(byAdding: .day, value: 1, to: today) ?? today
    }

    // MARK: - Driver

    private func tick() {
        guard runTask == nil else { return }
        let processor = SessionAudioProcessing.shared
        // Never while recording or finalising — the recorder owns the
        // machine. Never while a manual "Transcribe audio" runs — same
        // pipeline. And never while a batch is still copying files, so
        // the disk isn't shared between a copy and a decode.
        guard !processor.recordingOrFinalizeIsActive, !processor.isRunning,
              !AudioImportRunner.shared.isRunning else { return }
        let now = Date()
        guard let job = jobs.first(where: { isReady($0, now: now) }) else { return }

        activeJobID = job.id
        runTask = Task { [weak self] in
            await self?.run(job)
            self?.runTask = nil
            self?.activeJobID = nil
            // Chain straight into the next ready job rather than waiting
            // for the next poll.
            self?.tick()
        }
    }

    private func run(_ job: ImportTranscriptionJob) async {
        let session: StoredSession
        switch await resolveSession(job) {
        case .found(let hit):
            session = hit
        case .gone:
            // Session deleted outside the app (Finder, another Mac).
            log.info("Import job dropped: session \(job.sessionID, privacy: .private) no longer exists")
            jobs.removeAll { $0.id == job.id }
            persist()
            return
        case .notYetScanned:
            // Directory is there but the Library's scan hasn't caught
            // up (refresh coalesces with one in flight). Next tick.
            return
        }
        // Store may be one scan stale after a manual transcription or an
        // iCloud-synced one from another Mac — trust the disk.
        let transcriptOnDisk = FileManager.default.fileExists(
            atPath: session.directoryURL.appendingPathComponent("transcript.md").path
        )
        // 24.09: a rotated recording ALWAYS has its live transcript — so
        // this guard dropped every "finish the final pass" job, silently,
        // since the day the queue took them (Egor's 13:36 recording kept
        // its live text, no summary, and a stale .recording marker).
        let finishing = job.finishesLiveTranscript == true
        // A draft the person edited while the job waited (on a charger,
        // possibly for hours) is theirs: finishing replaces the transcript
        // in place, so the edit wins and only the rest of the finish runs.
        if finishing, let queued = job.draftBodyHash,
           let now = Self.transcriptBodyHash(in: session.directoryURL), now != queued {
            log.info("Finishing job: transcript was edited while queued — keeping the edit, skipping the final pass")
            jobs.removeAll { $0.id == job.id }
            persist()
            try? FileManager.default.removeItem(
                at: session.directoryURL.appendingPathComponent(SessionStore.recordingMarkerName))
            await completeFinish(sessionID: job.sessionID)
            return
        }
        guard finishing || (session.transcriptURL == nil && !transcriptOnDisk) else {
            log.info("Import job dropped: session already has a transcript")
            jobs.removeAll { $0.id == job.id }
            persist()
            return
        }
        do {
            _ = try await SessionAudioProcessing.shared.retranscribe(
                session, options: job.options, replaceLiveTranscript: finishing)
            jobs.removeAll { $0.id == job.id }
            persist()
            log.info("Import job done: \(job.title, privacy: .private)\(finishing ? " — final pass over a live transcript (see the processing log for whether it replaced it)" : "", privacy: .public)")
            if finishing { await completeFinish(sessionID: job.sessionID) }
        } catch is CancellationError {
            // Pre-empted by a recording → job stays for the next tick.
            // Removed by the user → cancel(sessionID:) already took it out.
            log.info("Import job stopped: \(self.preempted ? "pre-empted, will retry" : "removed", privacy: .public)")
            preempted = false
        } catch ProcessingError.busy, ProcessingError.recordingActive {
            // Lost the race with a recording that started between the
            // guard and the call. Not an attempt — try again next tick.
            log.info("Import job deferred: pipeline busy")
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // A transcript landed while we were decoding. Terminal, and
            // not a failure worth a toast.
            jobs.removeAll { $0.id == job.id }
            persist()
        } catch {
            guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
            jobs[index].attempts += 1
            jobs[index].lastError = error.localizedDescription
            if jobs[index].attempts >= ImportTranscriptionJob.maxAttempts {
                log.error("Import job gave up after \(ImportTranscriptionJob.maxAttempts) attempts: \(error.localizedDescription, privacy: .public)")
                let title = jobs[index].title
                jobs.remove(at: index)
                ToastCenter.shared.show(
                    String(localized: "Couldn't transcribe “\(title)”: \(error.localizedDescription). It stays in the Library as audio."),
                    style: .warning,
                    duration: .seconds(8)
                )
            } else {
                // Back off an hour so a transient failure (model download
                // hiccup, disk briefly full) doesn't burn all attempts in
                // three minutes.
                jobs[index].notBefore = Date().addingTimeInterval(3600)
                log.warning("Import job failed (attempt \(self.jobs[index].attempts)): \(error.localizedDescription, privacy: .public)")
            }
            persist()
        }
    }

    /// What finalize would have done after its final pass, for a meeting
    /// finished from the queue (a charger wait, or a rotation): the
    /// summary — only when summaries run after each meeting, as finalize
    /// decides — then auto-send, then the delete-after-transcription purge
    /// under finalize Stage 6's rules (review finds, 07.10.2026).
    private func completeFinish(sessionID: String) async {
        let settings = RecordingSession.current?.settings
        let summarize = settings?.autoSummarize ?? false
        if summarize { await summarizeFinished(sessionID: sessionID) }
        await SessionStore.shared.refresh()
        guard let session = SessionStore.shared.sessions.first(where: { $0.id == sessionID }) else { return }
        if let settings { await autoSendFinished(session, settings: settings) }

        let directory = session.directoryURL
        guard AppSettings.currentAudioRetentionDays == AppSettings.audioRetentionDeleteAfterTranscription else { return }
        let transcriptLanded = await Task.detached { RecordingSession.transcriptHasContent(in: directory) }.value
        let summaryLanded = FileManager.default.fileExists(atPath: directory.appendingPathComponent("summary.json").path)
        // A summary that should have come and didn't keeps the audio, so
        // Re-summarize still has something to work from; no transcript
        // keeps it always — it may be the only copy left.
        if transcriptLanded, !summarize || summaryLanded {
            AudioRetentionSweep.purgeOneSession(at: directory)
        }
    }

    /// Finalize Stage 5 for a stored session: Notion and the auto-on-save
    /// integrations, filtered by project exactly as finalize filters them.
    private func autoSendFinished(_ session: StoredSession, settings: AppSettings) async {
        guard !session.transcriptText.isEmpty else { return }
        if settings.autoSendNotion, settings.hasNotionCredentials,
           RecordingSession.folderAllowed(session.folderSlug, allowed: settings.autoSendNotionFolders) {
            let export = MeetingExportData(
                title: session.title,
                summary: session.summary,
                transcriptChunks: SessionDetailView.chunkTranscript(session.transcriptText),
                durationSeconds: session.durationSec,
                locale: session.locale,
                startedAt: session.startedAt
            )
            do {
                _ = try await NotionExporter.shared.createMeetingPage(export)
                ToastCenter.shared.show(String(localized: "Sent to Notion · \(session.title)"), style: .success)
            } catch {
                log.error("Auto-send to Notion failed: \(error.localizedDescription, privacy: .private)")
                ToastCenter.shared.show(String(localized: "Auto-send to Notion failed — retry from Library"), style: .warning)
            }
        }
        for integration in MCPIntegrationStore.shared.autoOnSaveIntegrations
        where RecordingSession.folderAllowed(session.folderSlug, allowed: integration.allowedFolders) {
            _ = await MCPDispatcher.send(integration, for: session)
        }
    }

    /// SHA-256 of transcript.md without its frontmatter, or nil when there
    /// is no readable transcript.
    nonisolated static func transcriptBodyHash(in directory: URL) -> String? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8) else {
            return nil
        }
        var body = Substring(text)
        if body.hasPrefix("---\n"), let end = body.dropFirst(4).range(of: "\n---\n") {
            body = body[end.upperBound...]
        }
        return SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The interrupted recording never got its summary; give it one now,
    /// the way Re-summarize does, unless one is already there.
    private func summarizeFinished(sessionID: String) async {
        await SessionStore.shared.refresh()
        guard let session = SessionStore.shared.sessions.first(where: { $0.id == sessionID }),
              !session.transcriptText.isEmpty,
              !FileManager.default.fileExists(atPath: session.directoryURL.appendingPathComponent("summary.json").path),
              Summarizer.shared.availability == .available else { return }
        let localeHint = RecordingSession.resolveSummaryLocaleHint(
            transcript: session.transcriptText,
            transcriptLocale: session.locale,
            summaryLanguageOverride: AppSettings.currentSummaryLanguage
        )
        guard let summary = await Summarizer.shared.summarize(
            transcript: session.transcriptText, title: session.title, localeHint: localeHint,
            projectContext: ProjectMemoryBridge.block(forSessionAt: session.directoryURL)
        ) else {
            log.warning("Finished recording \(sessionID, privacy: .public): summary failed — \(Summarizer.shared.lastError ?? "no summary", privacy: .public)")
            return
        }
        await SessionStore.shared.updateSummary(summary, for: session)
        log.notice("Finished recording \(sessionID, privacy: .public): summary written")
    }

    private enum Resolution {
        case found(StoredSession)
        case gone
        case notYetScanned
    }

    private func resolveSession(_ job: ImportTranscriptionJob) async -> Resolution {
        let store = SessionStore.shared
        if let hit = store.sessions.first(where: { $0.id == job.sessionID }) { return .found(hit) }
        guard FileManager.default.fileExists(atPath: job.directoryPath) else { return .gone }
        await store.refresh()
        if let hit = store.sessions.first(where: { $0.id == job.sessionID }) { return .found(hit) }
        return FileManager.default.fileExists(atPath: job.directoryPath) ? .notYetScanned : .gone
    }

    // MARK: - Persistence

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(jobs).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Import queue not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func load(from url: URL) -> [ImportTranscriptionJob] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ImportTranscriptionJob].self, from: data)) ?? []
    }
}
