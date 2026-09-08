//
//  AudioImportSheet.swift
//  Daisy
//
//  The import dialog (design 2026-08-31 §2, phase Ф1) and the runner
//  that executes a batch behind it.
//
//  Egor's call: the dialog shows ALWAYS, not just for big batches — it
//  is where copy-vs-move and "transcribe now / later" are decided, and
//  those are not choices to guess. The dialog is modal; the work is not:
//  once "Import" is pressed the sheet closes and `AudioImportRunner`
//  copies + transcribes file by file, reporting through a status line
//  in the Library and a toast at the end (design §6.8: a report, never
//  a silent skip).
//
//  "Tonight at HH:MM" is deliberately absent until the persistent queue
//  (Ф2/Ф5) exists — a scheduled job that lives only in memory would be a
//  promise the app can't keep across a quit.
//

import SwiftUI

// MARK: - Batch handed from the drop target to the sheet

struct AudioImportBatch: Identifiable {
    let id = UUID()
    let urls: [URL]
    /// Project preselected from the active folder chip, if any.
    let folderSlug: String?
}

// MARK: - Runner

/// Executes one import batch sequentially: copy every file into a
/// session, then (when asked) transcribe each new session in turn via
/// `SessionAudioProcessing.retranscribe`. One batch at a time; a second
/// drop while running is refused with a toast rather than queued —
/// the persistent queue is Ф2.
@Observable
@MainActor
final class AudioImportRunner {
    static let shared = AudioImportRunner()

    enum Transcription: String, CaseIterable, Identifiable {
        case now, later
        var id: String { rawValue }
    }

    struct Plan {
        var urls: [URL]
        var folderSlug: String
        var mode: ImportMarker.Mode
        var transcription: Transcription
        var options: SessionRetranscriptionOptions
    }

    private(set) var isRunning = false
    /// "Importing 3 of 12 · acme.m4a" — shown above the Library list.
    private(set) var statusText = ""

    private init() {}

    func run(_ plan: Plan) {
        guard !isRunning else {
            ToastCenter.shared.show(
                String(localized: "An import is already running. Drop the files again when it finishes."),
                style: .warning
            )
            return
        }
        isRunning = true
        Task { [weak self] in
            await self?.execute(plan)
            self?.isRunning = false
            self?.statusText = ""
        }
    }

    private func execute(_ plan: Plan) async {
        let total = plan.urls.count
        var imported: [AudioImportResult] = []
        var importFailures: [(name: String, reason: String)] = []

        for (index, url) in plan.urls.enumerated() {
            statusText = String(localized: "Importing \(index + 1) of \(total) · \(url.lastPathComponent)")
            do {
                imported.append(try await AudioImporter.importFile(url, into: plan.folderSlug, mode: plan.mode))
            } catch {
                importFailures.append((url.lastPathComponent, error.localizedDescription))
            }
        }

        var transcribed = 0
        var transcribeFailure: String?
        if plan.transcription == .now, !imported.isEmpty {
            let processor = SessionAudioProcessing.shared
            if processor.isRunning || processor.recordingOrFinalizeIsActive {
                // One honest line instead of N identical throws. The
                // sessions are in the Library as audio; each has its own
                // "Transcribe audio" button.
                transcribeFailure = String(localized: "a recording is in progress — transcribe them from the Library later")
            } else {
                for (index, result) in imported.enumerated() {
                    statusText = String(localized: "Transcribing \(index + 1) of \(imported.count) · \(result.title)")
                    guard let session = await lookupSession(result.sessionID) else {
                        transcribeFailure = String(localized: "the Library hasn't picked up “\(result.title)” yet")
                        continue
                    }
                    do {
                        _ = try await processor.retranscribe(session, options: plan.options)
                        transcribed += 1
                    } catch {
                        if transcribeFailure == nil { transcribeFailure = error.localizedDescription }
                    }
                }
            }
        }

        report(
            imported: imported,
            importFailures: importFailures,
            transcribed: transcribed,
            transcribeFailure: transcribeFailure,
            wanted: plan.transcription
        )
        if imported.count == 1, let only = imported.first,
           AppNavigation.shared.section == .library {
            AppNavigation.shared.openInLibrary(only.sessionID)
        }
    }

    /// `SessionStore.refresh()` coalesces with a refresh already in
    /// flight (the folder watcher starts its own during a batch), so the
    /// list right after `importFile` can be one scan stale. Retry once.
    private func lookupSession(_ id: String) async -> StoredSession? {
        if let hit = SessionStore.shared.sessions.first(where: { $0.id == id }) { return hit }
        await SessionStore.shared.refresh()
        return SessionStore.shared.sessions.first(where: { $0.id == id })
    }

    private func report(
        imported: [AudioImportResult],
        importFailures: [(name: String, reason: String)],
        transcribed: Int,
        transcribeFailure: String?,
        wanted: Transcription
    ) {
        var parts: [String] = []
        if imported.count == 1 {
            parts.append(String(localized: "Imported “\(imported[0].title)”"))
        } else if !imported.isEmpty {
            parts.append(String(localized: "Imported \(imported.count) recordings"))
        }
        if wanted == .now, !imported.isEmpty {
            let leftAsAudio = imported.count - transcribed
            if leftAsAudio == 0 {
                parts.append(String(localized: "\(transcribed) transcribed"))
            } else if let transcribeFailure {
                parts.append(String(localized: "\(leftAsAudio) left as audio: \(transcribeFailure)"))
            } else {
                parts.append(String(localized: "\(leftAsAudio) left as audio"))
            }
        }
        if !importFailures.isEmpty {
            // The toast holds two lines — give the reason only when it
            // is the whole story.
            parts.append(imported.isEmpty
                ? importFailures[0].reason
                : String(localized: "\(importFailures.count) couldn't be imported"))
        }
        let ok = importFailures.isEmpty && !imported.isEmpty && transcribeFailure == nil
        ToastCenter.shared.show(parts.joined(separator: " · "), style: ok ? .success : .warning, duration: .seconds(ok ? 4 : 8))
    }
}

// MARK: - Sheet

struct AudioImportSheet: View {
    let batch: AudioImportBatch

    @Environment(\.dismiss) private var dismiss
    @Bindable private var folders = FolderStore.shared

    @State private var candidates: [AudioImporter.Candidate] = []
    @State private var inspecting = true
    @State private var folderSlug: String
    @State private var mode: ImportMarker.Mode = .copy
    @State private var transcription: AudioImportRunner.Transcription = .now
    @State private var modelID = WhisperEngine.defaultModelID
    @State private var language = "auto"
    @State private var diarize = true

    init(batch: AudioImportBatch) {
        self.batch = batch
        _folderSlug = State(initialValue: batch.folderSlug ?? SessionFolder.inbox.slug)
    }

    private var importable: [AudioImporter.Candidate] { candidates.filter { $0.problem == nil } }
    private var totalSeconds: Int { importable.compactMap(\.durationSec).reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(.title2.weight(.semibold))
                Text("Each file becomes its own recording in the Library. The date comes from the file, not from today.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)

            Divider()

            Form {
                Picker("Project", selection: $folderSlug) {
                    ForEach(projectRows, id: \.folder.slug) { row in
                        Text(row.isChild ? "    \(row.folder.name)" : row.folder.name)
                            .tag(row.folder.slug)
                    }
                }

                Picker("Files", selection: $mode) {
                    Text("Copy into Daisy's library").tag(ImportMarker.Mode.copy)
                    Text("Move (originals go to the Trash after import)").tag(ImportMarker.Mode.move)
                }
                .pickerStyle(.radioGroup)

                Picker("Transcribe", selection: $transcription) {
                    Text("Now").tag(AudioImportRunner.Transcription.now)
                    Text("Later — keep in the Library as audio").tag(AudioImportRunner.Transcription.later)
                }
                .pickerStyle(.radioGroup)

                if transcription == .now {
                    Picker("Model", selection: $modelID) {
                        ForEach(WhisperEngine.availableModels, id: \.id) { model in
                            Text(model.label).tag(model.id)
                        }
                    }
                    Picker("Language", selection: $language) {
                        ForEach(Transcriber.availableLocales, id: \.id) { locale in
                            Text(locale.label).tag(locale.id)
                        }
                    }
                    Toggle("Detect speakers", isOn: $diarize)
                }

                if !candidates.isEmpty {
                    Section("Files") {
                        ForEach(candidates) { candidate in
                            HStack {
                                Text(candidate.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if let problem = candidate.problem {
                                    Text(problem)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.trailing)
                                } else if let seconds = candidate.durationSec {
                                    Text(Self.duration(seconds))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 300, maxHeight: 520)

            Divider()

            HStack {
                if inspecting {
                    ProgressView().controlSize(.small)
                    Text("Reading files…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") { start() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.daisyAccent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(inspecting || importable.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 560)
        .task {
            modelID = WhisperEngine.shared.modelID
            candidates = await AudioImporter.inspect(batch.urls)
            inspecting = false
        }
    }

    private var headline: String {
        let count = inspecting ? batch.urls.count : importable.count
        let files = count == 1
            ? String(localized: "Import 1 file")
            : String(localized: "Import \(count) files")
        guard totalSeconds > 0 else { return files }
        return "\(files) · \(Self.duration(totalSeconds))"
    }

    /// Notes is a kind, not a destination for imported recordings —
    /// leave it out of the project list.
    private var projectRows: [(folder: SessionFolder, isChild: Bool)] {
        var rows: [(folder: SessionFolder, isChild: Bool)] = []
        for root in folders.rootFolders where root.slug != SessionFolder.notes.slug {
            rows.append((root, false))
            for child in folders.children(of: root.slug) {
                rows.append((child, true))
            }
        }
        return rows
    }

    private func start() {
        let plan = AudioImportRunner.Plan(
            urls: importable.map(\.url),
            folderSlug: folderSlug,
            mode: mode,
            transcription: transcription,
            options: SessionRetranscriptionOptions(modelID: modelID, language: language, diarize: diarize)
        )
        dismiss()
        AudioImportRunner.shared.run(plan)
    }

    nonisolated static func duration(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
    }
}
