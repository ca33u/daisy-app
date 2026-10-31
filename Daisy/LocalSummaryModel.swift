//
//  LocalSummaryModel.swift
//  Daisy
//
//  The files of «Локальная модель Daisy» (plan 2026-10-28, Л-2): Qwen 3.5 4B
//  in MLX 4-bit, mlx-community's build at a pinned commit — the one the
//  spike and Л-1 measured. They come like every other model (MacModelHosting:
//  our mirror first, then Hugging Face at the pinned commit, each file
//  checked against the bundled manifest's SHA-256 before it's put in
//  place), but only when the person chooses the local model, never at
//  launch, and there is no library download behind them.
//
//  They live in Application Support, not in a cache: macOS may empty caches,
//  and 3 GB fetched again unasked would break the «качается только по
//  выбору» rule. Deleting them is the person's call (Л-4's «Удалить»).
//

import DaisyLLMKit
import Foundation

nonisolated enum LocalSummaryModel {
    static let repo = "mlx-community/Qwen3.5-4B-MLX-4bit"
    /// What the helper loads; the vision files and vocab.json stay behind.
    static let files = [
        "config.json", "model.safetensors", "model.safetensors.index.json",
        "tokenizer.json", "tokenizer_config.json", "chat_template.jinja",
    ]
    static let displayName = "Qwen 3.5 4B"

    /// `~/Library/Application Support/Daisy/Models/llm/<owner>/<repo>`.
    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Daisy/Models/llm/\(repo)", isDirectory: true)
    }

    enum State: Equatable, Sendable {
        case notInstalled
        /// Some files there (an interrupted download): `bytes` of `total`.
        case partial(bytes: Int64, total: Int64)
        case installed
    }

    enum Failure: Error, Equatable, LocalizedError {
        case notEnoughSpace(required: Int64, available: Int64)
        case noFolder
        /// MLX needs Apple silicon: no 3 GB for a Mac that can't run it.
        case unsupportedMac
        /// A download into this folder is running (or still stopping), or
        /// the model is being deleted.
        case busy

        var errorDescription: String? {
            switch self {
            case .notEnoughSpace(let required, let available):
                ModelPreparationPolicy.diskMessage(required: required, available: available)
            case .noFolder:
                String(localized: "Daisy couldn’t find a folder for the local model.")
            case .unsupportedMac:
                DaisyLLMFailure.unsupportedHardware.errorDescription
            case .busy:
                String(localized: "The local model is already downloading, or being deleted.")
            }
        }
    }

    /// One download per folder. A second one is refused, not joined: the
    /// download belongs to whoever started it — their cancel, their
    /// progress. An entry goes only once its task has fully stopped, and a
    /// delete holds new downloads off until it is done.
    private actor Downloads {
        private var running: [String: Task<Void, any Error>] = [:]
        private var deleting: Set<String> = []

        func start(_ key: String, _ make: @Sendable () -> Task<Void, any Error>) throws -> Task<Void, any Error> {
            guard running[key] == nil, !deleting.contains(key) else { throw Failure.busy }
            let task = make()
            running[key] = task
            return task
        }

        func finished(_ key: String, _ task: Task<Void, any Error>) {
            if running[key] == task { running[key] = nil }
        }

        func beginDelete(_ key: String) async throws {
            guard !deleting.contains(key) else { throw Failure.busy }
            deleting.insert(key)
            if let task = running[key] {
                task.cancel()
                _ = try? await task.value
                running[key] = nil
            }
        }

        func endDelete(_ key: String) {
            deleting.remove(key)
        }
    }

    private static let downloads = Downloads()

    static func entries(catalog: [MacModelHosting.File]? = nil) throws -> [MacModelHosting.Entry] {
        try MacModelHosting.entries(for: .summaryLLM, in: catalog ?? MacModelHosting.catalog())
    }

    /// The download's size, for «Скачать · 3,1 ГБ».
    static func downloadBytes(catalog: [MacModelHosting.File]? = nil) -> Int64? {
        (try? entries(catalog: catalog))?.reduce(0) { $0 + $1.file.size }
    }

    /// Free space a download asks for: the files still missing, their
    /// temporary copies while each is checked, and a margin — the rule
    /// speech models follow. Without a folder, the whole model.
    static func requiredFreeBytes(in folder: URL? = nil, catalog: [MacModelHosting.File]? = nil) -> Int64 {
        guard let entries = try? entries(catalog: catalog) else { return 0 }
        let missing = entries.filter { entry in
            guard let folder else { return true }
            let size = try? folder.appendingPathComponent(entry.localPath).resourceValues(forKeys: [.fileSizeKey]).fileSize
            return size.map(Int64.init) != entry.file.size
        }
        let bytes = missing.reduce(Int64(0)) { $0 + $1.file.size }
        return ModelPreparationPolicy.requiredFreeBytes(downloadMB: Int((bytes + 999_999) / 1_000_000))
    }

    /// By sizes alone — cheap enough for every summary. The SHA-256 of each
    /// file was checked when it was put in place.
    static func state(in folder: URL? = directory, catalog: [MacModelHosting.File]? = nil) -> State {
        guard let folder, let entries = try? entries(catalog: catalog) else { return .notInstalled }
        var present: Int64 = 0
        var complete = true
        for entry in entries {
            let url = folder.appendingPathComponent(entry.localPath)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            if size == entry.file.size { present += size } else { complete = false }
        }
        if complete { return .installed }
        return present == 0 ? .notInstalled : .partial(bytes: present, total: entries.reduce(0) { $0 + $1.file.size })
    }

    static var isInstalled: Bool { state() == .installed }

    /// Fetches what's missing or wrong into `folder`. Files already there
    /// and intact are kept, so a download stopped part-way keeps the files
    /// it finished — but a file cut off part-way starts over, and the
    /// weights are 99 % of the bytes. Hashing runs off the main actor.
    /// `progress` is 0…1. A second call while one runs throws `.busy`.
    static func download(
        into folder: URL? = directory,
        freeBytes: Int64? = DiskSpace.freeBytes(at: FileManager.default.homeDirectoryForCurrentUser),
        catalog: [MacModelHosting.File]? = nil,
        fetch: MacModelHosting.Fetch? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard DaisyLLMClient.runsOnThisMac else { throw Failure.unsupportedMac }
        guard let folder else { throw Failure.noFolder }
        let files = try catalog ?? MacModelHosting.catalog()
        let key = folder.standardizedFileURL.path
        let work = try await downloads.start(key) {
            Task.detached(priority: .userInitiated) {
                // Checked here, once this download is the folder's only one.
                let required = requiredFreeBytes(in: folder, catalog: files)
                if let freeBytes, freeBytes < required {
                    throw Failure.notEnoughSpace(required: required, available: freeBytes)
                }
                try await MacModelHosting.prefetch(.summaryLLM, into: folder, progress: progress, fetch: fetch, catalog: files)
            }
        }
        do {
            // `value` returns once the task has fully stopped, cancelled or not.
            try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        } catch {
            await downloads.finished(key, work)
            throw error
        }
        await downloads.finished(key, work)
    }

    /// Stops a download into the folder, then removes the model. The helper,
    /// if it has it loaded, keeps its copy until it exits on idle.
    static func delete(at folder: URL? = directory) async throws {
        guard let folder else { return }
        let key = folder.standardizedFileURL.path
        try await downloads.beginDelete(key)
        do {
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder)
            }
        } catch {
            await downloads.endDelete(key)
            throw error
        }
        await downloads.endDelete(key)
    }
}
