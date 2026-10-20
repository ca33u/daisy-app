//
//  OllamaModelDownloader.swift
//  Daisy
//
//  Backlog 33 У-1 (Egor, 20.10.2026): a local model in one click from
//  Daisy. Until now local summaries took three steps outside the app —
//  install Ollama, `ollama pull …` in Terminal, come back — and most
//  people stayed on Apple Intelligence, which doesn't write Russian
//  (backlog 32, log A). Ollama's `POST /api/pull` streams progress, so
//  Settings → Summary → Ollama can offer each catalogue model with its
//  size, download it with a progress bar and a Cancel, mark what is
//  installed, and pick the model once it lands.
//
//  Rules: a download starts only on a click that names the size; models
//  Ollama serves from the cloud (`:cloud`) are not in the catalogue —
//  they are not local; below 8 GB of memory a local model is not offered.
//  The downloader is a singleton with its own task, so closing the
//  Settings window doesn't stop it. Quitting Daisy does: Ollama keeps
//  the blobs it already has, and the next Download resumes from there,
//  never a half-written model — Ollama lists a model only after its
//  manifest is written.
//

import Foundation
import Observation
import os

/// One entry of the download catalogue.
nonisolated struct OllamaCatalogModel: Identifiable, Sendable, Equatable {
    let id: String
    /// Family and size, e.g. "Qwen 3.5 4B".
    let name: String
    /// Default-quant download size from ollama.com/library.
    let sizeGB: Double
    /// Memory the model needs to be worth using for a meeting summary.
    let minMemoryGB: Int
    /// A word about where it sits, for the picker label; nil for the
    /// current recommendation (which the memory hint names instead).
    let note: String?
}

/// The catalogue and the hardware hint. Pure — the view reads it, the
/// tests check it.
nonisolated enum OllamaModelCatalog {
    /// Refreshed 2026-10-08; sizes are the default-quant download sizes
    /// from ollama.com/library. Gemma 4 e2b / e4b / 12b fit a 16 GB Mac;
    /// Qwen 3.6 and 3.8 come only at 27B and up, so Qwen 3.5 stays the
    /// small default. Gemma 3, GPT-OSS and Llama haven't been updated in
    /// a year or more — kept for anyone who already has them.
    static let models: [OllamaCatalogModel] = [
        OllamaCatalogModel(id: "qwen3.5:4b", name: "Qwen 3.5 4B", sizeGB: 3.3, minMemoryGB: 8, note: nil),
        OllamaCatalogModel(id: "gemma4:e4b", name: "Gemma 4 E4B", sizeGB: 6.6, minMemoryGB: 16, note: "multilingual"),
        OllamaCatalogModel(id: "gemma4:12b", name: "Gemma 4 12B", sizeGB: 8.0, minMemoryGB: 32, note: "more capable"),
        OllamaCatalogModel(id: "qwen3.5:9b", name: "Qwen 3.5 9B", sizeGB: 6.6, minMemoryGB: 16, note: "more capable"),
        OllamaCatalogModel(id: "gemma4:e2b", name: "Gemma 4 E2B", sizeGB: 4.6, minMemoryGB: 8, note: "smallest Gemma 4"),
        OllamaCatalogModel(id: "qwen3.5:27b", name: "Qwen 3.5 27B", sizeGB: 17.0, minMemoryGB: 32, note: "needs a 32 GB Mac"),
        OllamaCatalogModel(id: "gemma3:4b", name: "Gemma 3 4B", sizeGB: 3.3, minMemoryGB: 8, note: "older"),
        OllamaCatalogModel(id: "gemma3:12b", name: "Gemma 3 12B", sizeGB: 8.1, minMemoryGB: 32, note: "older"),
        OllamaCatalogModel(id: "gpt-oss:20b", name: "GPT-OSS 20B", sizeGB: 13.0, minMemoryGB: 32, note: nil),
        OllamaCatalogModel(id: "llama3.1:8b", name: "Llama 3.1 8B", sizeGB: 4.7, minMemoryGB: 16, note: "older, widely installed"),
        OllamaCatalogModel(id: "llama3.2:latest", name: "Llama 3.2 3B", sizeGB: 2.0, minMemoryGB: 8, note: "older, smallest"),
    ]

    /// Below this a local model is not offered: it would be slow and may
    /// not fit next to the meeting's own transcription.
    static let minimumMemoryGB = 8

    static func physicalMemoryGB(bytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        Int((Double(bytes) / 1_073_741_824).rounded())
    }

    /// Egor's table (20.10): 8 GB → Qwen 3.5 4B, 16 GB → Gemma 4 E4B,
    /// 32 GB and up → Gemma 4 12B; under 8 GB nothing.
    static func recommendedModelID(memoryGB: Int) -> String? {
        switch memoryGB {
        case ..<8: return nil
        case 8..<16: return "qwen3.5:4b"
        case 16..<32: return "gemma4:e4b"
        default: return "gemma4:12b"
        }
    }

    static func fits(_ model: OllamaCatalogModel, memoryGB: Int) -> Bool {
        memoryGB >= model.minMemoryGB
    }

    static func model(id: String) -> OllamaCatalogModel? {
        models.first { $0.id == id }
    }

    /// "3.3 GB" / «3,3 ГБ», by the user's locale.
    static func sizeLabel(gb: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB]
        formatter.countStyle = .decimal
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: Int64(gb * 1_000_000_000))
    }

    /// The picker's label for a catalogue id: "Qwen 3.5 4B (~3.3 GB) — more capable".
    static func pickerLabel(_ model: OllamaCatalogModel) -> String {
        let base = "\(model.name) (~\(sizeLabel(gb: model.sizeGB)))"
        guard let note = model.note else { return base }
        return "\(base) — \(String(localized: String.LocalizationValue(note)))"
    }
}

/// One line of Ollama's `/api/pull` stream. Ollama sends NDJSON:
/// `{"status":"pulling manifest"}`, then per layer
/// `{"status":"pulling <digest>","digest":…,"total":N,"completed":M}`,
/// then `verifying sha256 digest`, `writing manifest`, `success`; an
/// `{"error":"…"}` line on failure.
nonisolated struct OllamaPullEvent: Decodable, Sendable, Equatable {
    var status: String?
    var digest: String?
    var total: Int64?
    var completed: Int64?
    var error: String?

    static func parse(_ line: String) -> OllamaPullEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(OllamaPullEvent.self, from: Data(trimmed.utf8))
    }

    var isSuccess: Bool { status == "success" }
}

/// What the row shows while a pull runs. Progress is per layer — the
/// weights blob is the one that takes minutes, the others are seconds —
/// so the bar follows the layer being pulled; the status names the rest.
nonisolated struct OllamaPullProgress: Sendable, Equatable {
    var status: String = ""
    var completed: Int64 = 0
    var total: Int64 = 0

    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }

    mutating func apply(_ event: OllamaPullEvent) {
        if let status = event.status { self.status = status }
        if let total = event.total, total > 0 {
            self.total = total
            self.completed = event.completed ?? 0
        } else if event.digest == nil, event.status != nil {
            // A step without a size (manifest, verify, write): the bar
            // would lie if it kept the last layer's numbers.
            self.total = 0
            self.completed = 0
        }
    }
}

@MainActor
@Observable
final class OllamaModelDownloader {
    static let shared = OllamaModelDownloader()

    /// Live pulls by model id.
    private(set) var progress: [String: OllamaPullProgress] = [:]
    /// The last failure by model id, cleared by the next attempt.
    private(set) var errors: [String: String] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "app.essazanov.Daisy", category: "OllamaPull")

    private init() {}

    var isDownloading: Bool { !progress.isEmpty }

    func isDownloading(_ modelID: String) -> Bool { progress[modelID] != nil }

    /// Start a pull. `onInstalled` runs on the main actor once Ollama
    /// reports success — the caller selects the model and refreshes.
    func download(model modelID: String, baseURL: URL, onInstalled: @escaping @MainActor (String) -> Void) {
        guard tasks[modelID] == nil else { return }
        guard !OllamaAPISummarizer.isCloudModel(modelID) else {
            errors[modelID] = String(localized: "This is an Ollama cloud model — it runs on ollama.com, not on this Mac.")
            return
        }
        errors[modelID] = nil
        progress[modelID] = OllamaPullProgress(status: "starting")
        log.notice("Pulling \(modelID, privacy: .public) from Ollama at \(baseURL.absoluteString, privacy: .public)")
        tasks[modelID] = Task { [weak self] in
            defer {
                self?.tasks[modelID] = nil
                self?.progress[modelID] = nil
            }
            do {
                try await Self.pull(model: modelID, baseURL: baseURL) { [weak self] event in
                    guard let self else { return }
                    var current = self.progress[modelID] ?? OllamaPullProgress()
                    current.apply(event)
                    self.progress[modelID] = current
                }
                guard !Task.isCancelled else { return }
                self?.log.notice("Pulled \(modelID, privacy: .public)")
                ToastCenter.shared.show(String(localized: "“\(modelID)” is downloaded and selected for summaries."), style: .success)
                onInstalled(modelID)
            } catch where Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                // Cancel cancels the task; URLSession reports that as its
                // own `.cancelled`, not as CancellationError (review 20.10).
                // Ollama keeps the blobs it has; the next Download resumes.
                self?.log.notice("Pull of \(modelID, privacy: .public) cancelled — Ollama keeps the part it has, the next download resumes")
            } catch {
                self?.log.error("Pull of \(modelID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                self?.errors[modelID] = error.localizedDescription
                ToastCenter.shared.show(String(localized: "Couldn't download “\(modelID)”: \(error.localizedDescription)"), style: .warning, duration: .seconds(8))
            }
        }
    }

    func cancel(model modelID: String) {
        tasks[modelID]?.cancel()
    }

    /// The HTTP side: `POST /api/pull` with `stream: true`, one JSON per
    /// line, `onEvent` for each on the main actor. Throws on an `error`
    /// line, a non-2xx reply, or a stream that ends without `success`.
    nonisolated static func pull(
        model modelID: String,
        baseURL: URL,
        session: URLSession = .shared,
        onEvent: @escaping @MainActor (OllamaPullEvent) -> Void
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": modelID, "stream": true])
        // A pull is minutes of streaming; the default 60 s is per byte
        // gap, which a stalled mirror can exceed.
        request.timeoutInterval = 300
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OllamaPullError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count > 4096 { break } }
            throw OllamaPullError.http(status: http.statusCode, body: String(decoding: body, as: UTF8.self))
        }
        var succeeded = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = OllamaPullEvent.parse(line) else { continue }
            if let error = event.error { throw OllamaPullError.server(error) }
            await onEvent(event)
            if event.isSuccess { succeeded = true }
        }
        guard succeeded else { throw OllamaPullError.endedEarly }
    }
}

nonisolated enum OllamaPullError: LocalizedError {
    case badResponse
    case http(status: Int, body: String)
    case server(String)
    case endedEarly

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return String(localized: "Ollama gave an unexpected reply.")
        case .http(let status, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(detail.prefix(200))"
        case .server(let message):
            return message
        case .endedEarly:
            return String(localized: "The download stopped before Ollama confirmed the model.")
        }
    }
}
