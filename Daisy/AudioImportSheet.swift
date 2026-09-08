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
//  Transcription itself is never run here: "now" and "tonight" both
//  become jobs in `ImportTranscriptionQueue`, which is persistent, waits
//  for a live recording to finish, and survives a quit (Ф2).
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
/// session, then hand the new sessions to `ImportTranscriptionQueue`
/// (unless "later"). One batch at a time; a second drop while copying
/// is refused with a toast.
@Observable
@MainActor
final class AudioImportRunner {
    static let shared = AudioImportRunner()

    enum Transcription: String, CaseIterable, Identifiable {
        case now, later, tonight
        var id: String { rawValue }
    }

    struct Item {
        var url: URL
        var folderSlug: String
        /// Set when two files in the batch share a name (design §6.7):
        /// "Interviews — recording" instead of two "recording" rows.
        var title: String?
    }

    struct Plan {
        var items: [Item]
        var mode: ImportMarker.Mode
        var transcription: Transcription
        /// For `.tonight`: the next occurrence of the chosen HH:MM.
        var notBefore: Date?
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
            // The queue refuses to start while a batch is copying; now
            // that it's done, don't make it wait for the next poll.
            ImportTranscriptionQueue.shared.kick()
        }
    }

    private func execute(_ plan: Plan) async {
        let total = plan.items.count
        var imported: [AudioImportResult] = []
        var importFailures: [(name: String, reason: String)] = []

        for (index, item) in plan.items.enumerated() {
            let url = item.url
            statusText = String(localized: "Importing \(index + 1) of \(total) · \(url.lastPathComponent)")
            do {
                imported.append(try await AudioImporter.importFile(
                    url, into: item.folderSlug, mode: plan.mode, title: item.title
                ))
            } catch {
                importFailures.append((url.lastPathComponent, error.localizedDescription))
            }
        }

        if plan.transcription != .later {
            let queue = ImportTranscriptionQueue.shared
            for result in imported {
                queue.enqueue(
                    sessionID: result.sessionID,
                    directoryURL: result.directoryURL,
                    title: result.title,
                    options: plan.options,
                    notBefore: plan.transcription == .tonight ? plan.notBefore : nil
                )
            }
        }

        report(imported: imported, importFailures: importFailures, plan: plan)
        if imported.count == 1, let only = imported.first,
           AppNavigation.shared.section == .library {
            AppNavigation.shared.openInLibrary(only.sessionID)
        }
    }

    private func report(
        imported: [AudioImportResult],
        importFailures: [(name: String, reason: String)],
        plan: Plan
    ) {
        var parts: [String] = []
        if imported.count == 1 {
            parts.append(String(localized: "Imported “\(imported[0].title)”"))
        } else if !imported.isEmpty {
            parts.append(String(localized: "Imported \(imported.count) recordings"))
        }
        if !imported.isEmpty {
            switch plan.transcription {
            case .now:
                parts.append(String(localized: "transcription queued"))
            case .tonight:
                if let at = plan.notBefore {
                    parts.append(String(localized: "transcribes at \(ImportTranscriptionQueue.timeFormatter.string(from: at))"))
                }
            case .later:
                break
            }
        }
        if !importFailures.isEmpty {
            // The toast holds two lines — give the reason only when it
            // is the whole story.
            parts.append(imported.isEmpty
                ? importFailures[0].reason
                : String(localized: "\(importFailures.count) couldn't be imported"))
        }
        let ok = importFailures.isEmpty && !imported.isEmpty
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
    /// Only the HH:MM matters; the date part is replaced by the next
    /// occurrence at import time.
    @State private var tonightTime: Date = Calendar.current.date(bySettingHour: 3, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var modelID = WhisperEngine.defaultModelID
    @State private var language = "auto"
    @State private var diarize = true

    /// Sentinel in the project picker: every dropped folder becomes (or
    /// reuses) a project of its own name.
    private static let byFolderTag = "\u{0}by-folder"

    init(batch: AudioImportBatch) {
        self.batch = batch
        _folderSlug = State(initialValue: batch.folderSlug ?? SessionFolder.inbox.slug)
    }

    private var importable: [AudioImporter.Candidate] { candidates.filter { $0.problem == nil } }
    private var droppedFolderNames: [String] {
        var seen: [String] = []
        for c in candidates {
            if let f = c.folderName, !seen.contains(f) { seen.append(f) }
        }
        return seen
    }
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
                    if !droppedFolderNames.isEmpty {
                        Text(droppedFolderNames.count == 1
                             ? String(localized: "“\(droppedFolderNames[0])” (from the folder name)")
                             : String(localized: "By folder name (\(droppedFolderNames.count) projects)"))
                            .tag(Self.byFolderTag)
                        Divider()
                    }
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
                    Text("Tonight").tag(AudioImportRunner.Transcription.tonight)
                    Text("Later — keep in the Library as audio").tag(AudioImportRunner.Transcription.later)
                }
                .pickerStyle(.radioGroup)

                if transcription == .tonight {
                    LabeledContent("Start at") {
                        HStack(spacing: 8) {
                            DatePicker("", selection: $tonightTime, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            Text(Self.relativeDay(for: tonightSchedule))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Daisy keeps the queue on disk and waits for any recording to finish first. If the Mac is asleep at that time, the job runs when it wakes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if transcription != .later {
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
                                Text(rowName(for: candidate))
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
            // Folder drop → its name is the project unless the person
            // had a project chip active (then that wins).
            if batch.folderSlug == nil, !droppedFolderNames.isEmpty,
               folderSlug == SessionFolder.inbox.slug {
                folderSlug = Self.byFolderTag
            }
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

    /// "Interviews / acme.m4a" when several folders were dropped, so
    /// same-named files from different folders stay tellable apart.
    private func rowName(for candidate: AudioImporter.Candidate) -> String {
        if droppedFolderNames.count > 1, let folder = candidate.folderName {
            return "\(folder) / \(candidate.name)"
        }
        return candidate.name
    }

    private var tonightSchedule: Date {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: tonightTime)
        return ImportTranscriptionQueue.nextOccurrence(hour: comps.hour ?? 3, minute: comps.minute ?? 0)
    }

    nonisolated static func relativeDay(for date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? String(localized: "today")
            : String(localized: "tomorrow")
    }

    private func start() {
        // Chronological: the Library sorts by date, and a batch that
        // lands in file order can be a day's interviews shuffled.
        let ordered = importable.sorted {
            ($0.startedAt ?? .distantFuture) < ($1.startedAt ?? .distantFuture)
        }
        // Duplicate names inside the batch → prefix with the folder
        // (design §6.7: distinguish by parent, not by a counter).
        var nameCounts: [String: Int] = [:]
        for c in ordered { nameCounts[c.name.lowercased(), default: 0] += 1 }
        let byFolder = folderSlug == Self.byFolderTag
        var slugCache: [String: String] = [:]
        let items: [AudioImportRunner.Item] = ordered.map { c in
            let slug: String
            if byFolder, let folder = c.folderName {
                if let cached = slugCache[folder] {
                    slug = cached
                } else {
                    // "Notes" is a kind, not a project; a folder by that
                    // name lands in Inbox rather than among the notes.
                    let created = FolderStore.shared.addFolder(named: folder)
                    slug = created.slug == SessionFolder.notes.slug ? SessionFolder.inbox.slug : created.slug
                    slugCache[folder] = slug
                }
            } else {
                // A loose file next to dropped folders: the active chip
                // if there was one, else Inbox.
                slug = byFolder ? (batch.folderSlug ?? SessionFolder.inbox.slug) : folderSlug
            }
            var title: String?
            if nameCounts[c.name.lowercased(), default: 0] > 1 {
                let parent = c.url.deletingLastPathComponent().lastPathComponent
                title = "\(parent) — \(AudioImporter.title(fromFileName: c.name))"
            }
            return AudioImportRunner.Item(url: c.url, folderSlug: slug, title: title)
        }
        let plan = AudioImportRunner.Plan(
            items: items,
            mode: mode,
            transcription: transcription,
            notBefore: transcription == .tonight ? tonightSchedule : nil,
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
