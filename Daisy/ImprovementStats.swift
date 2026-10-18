//
//  ImprovementStats.swift
//  Daisy
//
//  "Help make Daisy better" (Egor, 2026-10-18). With the person's yes, once
//  a day Daisy sends the developer how many times its features ran and where
//  they failed — numbers only. No text, titles, names, paths, device names
//  and no identifier: two reports from one Mac cannot be told apart from two
//  reports from two Macs. Off until the person agrees; asked once, after
//  first run, and switchable in Settings → About.
//
//  Every event Daisy can count is in `Event` below — the whole list, here
//  and in Docs/usage-statistics.md. daisy-api (src/usage.ts) accepts only
//  these names, adds them into daily totals and keeps no report, and does
//  not record the address a report came from.
//
//  Not the same as `UsageStats`: that one feeds the Home widgets and never
//  leaves the Mac.
//

import AppKit
import Foundation
import os

nonisolated enum ImprovementStats {
    enum Mode: String, Sendable {
        /// Not asked yet: nothing is counted.
        case unasked
        case on
        case off
    }

    static let modeKey = "daisy.improvementStats.mode"
    static let endpoint = URL(string: "https://api.mydaisy.io/api/usage")!

    static var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .unasked }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
            // Turned off: what was counted and not yet sent goes too.
            if newValue != .on { store.clear() }
        }
    }

    // MARK: - Events

    /// Everything that can be counted. A name never carries content; it
    /// says which feature ran.
    enum Event: Sendable, Hashable {
        case recordingStarted(fromCalendar: Bool)
        case recordingSaved(seconds: Int)
        case recordingFailed
        case recordingMicOnly
        case voiceNoteSaved
        case transcriptionFailed
        case summary(SummaryProviderKind, viaAccount: Bool)
        case summaryFailed(SummaryProviderKind, viaAccount: Bool)
        case dictation(engine: String)
        case dictationRepaste
        case importFile
        case importArchive
        case iPhoneAudioReceived
        case syncPulled
        case exportMarkdown, exportArchive, exportNotion, exportClaude, exportAudio
        case mcpToolCall(failed: Bool)
        case screenshotNote
        case momentMarked
        case layoutFixed
        case layoutUndo
        case voiceProfileGenerated
        case catchUpUsed
        case speakersNamed
        case speakersMatched

        /// The counter names an occurrence adds to.
        var names: [String] {
            switch self {
            case .recordingStarted(let fromCalendar):
                return fromCalendar ? ["recording.started", "recording.started.calendar"] : ["recording.started"]
            case .recordingSaved(let seconds):
                let length = seconds < 15 * 60 ? "under15m" : seconds <= 60 * 60 ? "15to60m" : "over60m"
                return ["recording.saved", "recording.length." + length]
            case .recordingFailed: return ["recording.failed"]
            case .recordingMicOnly: return ["recording.mic_only"]
            case .voiceNoteSaved: return ["voice_note.saved"]
            case .transcriptionFailed: return ["transcription.failed"]
            case .summary(let kind, let account): return ["summary." + Self.provider(kind, account)]
            case .summaryFailed(let kind, let account): return ["summary.failed." + Self.provider(kind, account)]
            case .dictation(let engine):
                let known = ["whisper", "parakeet", "apple_speech"].contains(engine)
                return known ? ["dictation.done", "dictation.engine." + engine] : ["dictation.done"]
            case .dictationRepaste: return ["dictation.repaste"]
            case .importFile: return ["import.file"]
            case .importArchive: return ["import.archive"]
            case .iPhoneAudioReceived: return ["iphone.audio_received"]
            case .syncPulled: return ["sync.pulled"]
            case .exportMarkdown: return ["export.markdown"]
            case .exportArchive: return ["export.archive"]
            case .exportNotion: return ["export.notion"]
            case .exportClaude: return ["export.claude"]
            case .exportAudio: return ["export.audio"]
            case .mcpToolCall(let failed): return failed ? ["mcp.tool_call", "mcp.tool_error"] : ["mcp.tool_call"]
            case .screenshotNote: return ["screenshot.note"]
            case .momentMarked: return ["moment.marked"]
            case .layoutFixed: return ["layout.fixed"]
            case .layoutUndo: return ["layout.undo"]
            case .voiceProfileGenerated: return ["voice_profile.generated"]
            case .catchUpUsed: return ["catch_up.used"]
            case .speakersNamed: return ["speakers.named"]
            case .speakersMatched: return ["speakers.matched"]
            }
        }

        static func provider(_ kind: SummaryProviderKind, _ account: Bool) -> String {
            switch kind {
            case .appleIntelligence: return "apple"
            case .anthropic: return "anthropic"
            case .openai: return account ? "openai_account" : "openai"
            case .gemini: return "gemini"
            case .cursor: return "cursor"
            case .kimi: return "kimi"
            case .ollama: return "ollama"
            case .lmStudio: return "lmstudio"
            case .mcp: return "mcp"
            case .agentCLI: return "agent_cli"
            }
        }
    }

    /// Every counter name, as daisy-api's src/usage.ts lists them and
    /// Docs/usage-statistics.md publishes them. A test keeps `Event` to it.
    static let publishedNames: Set<String> = {
        let providers = ["apple", "anthropic", "openai", "openai_account", "gemini", "cursor", "kimi",
                         "ollama", "lmstudio", "mcp", "agent_cli"]
        return Set([
            "recording.started", "recording.started.calendar", "recording.saved",
            "recording.length.under15m", "recording.length.15to60m", "recording.length.over60m",
            "recording.failed", "recording.mic_only", "voice_note.saved",
            "transcription.failed",
            "dictation.done", "dictation.engine.whisper", "dictation.engine.parakeet", "dictation.engine.apple_speech",
            "dictation.repaste",
            "import.file", "import.archive", "iphone.audio_received", "sync.pulled",
            "export.markdown", "export.archive", "export.notion", "export.claude", "export.audio",
            "mcp.tool_call", "mcp.tool_error",
            "screenshot.note", "moment.marked",
            "layout.fixed", "layout.undo",
            "voice_profile.generated", "catch_up.used",
            "speakers.named", "speakers.matched",
        ] + providers.map { "summary." + $0 } + providers.map { "summary.failed." + $0 })
    }()

    /// Counts one occurrence, when the person agreed. Cheap; any thread.
    static func record(_ event: Event, count: Int = 1) {
        guard mode == .on, count > 0 else { return }
        store.add(event.names, count: count, day: day(Date()))
    }

    // MARK: - Reports

    struct Report: Codable, Equatable, Sendable {
        var schema = 1
        var day: String
        var app = "mac"
        var version: String
        var build: Int
        var channel: String
        var os: String
        var language: String
        var sync: Bool
        var counts: [String: Int]
    }

    /// A day's report as it would go out, with this Mac's version, macOS,
    /// language and channel — what "See what's sent" shows.
    static func report(day: String, counts: [String: Int]) -> Report {
        let info = Bundle.main.infoDictionary
        let language = Bundle.main.preferredLocalizations.first.map { String($0.prefix(2)).lowercased() } ?? "en"
        return Report(day: day,
                      version: info?["CFBundleShortVersionString"] as? String ?? "0.0",
                      build: Int(info?["CFBundleVersion"] as? String ?? "") ?? 1,
                      channel: UserDefaults.standard.bool(forKey: "daisy.updates.betaChannel") ? "beta" : "stable",
                      os: String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
                      language: language,
                      sync: UserDefaults.standard.bool(forKey: "daisy.sync.enabled"),
                      counts: counts)
    }

    /// The example shown before the person decides, and the report being
    /// gathered today once they have.
    static func preview() -> String {
        let today = day(Date())
        let counted = store.days()[today] ?? [:]
        let counts = counted.isEmpty ? ["recording.saved": 2, "recording.length.15to60m": 2,
                                        "summary.anthropic": 2, "dictation.done": 14, "dictation.engine.whisper": 14] : counted
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(report(day: today, counts: counts))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Sends every finished day still waiting (today is still being
    /// counted). A day the server took, or refused as malformed, is
    /// dropped; one that did not get through waits for the next try. Days
    /// older than two weeks are dropped unsent.
    static func sendDue(now: Date = Date(), session: URLSession = .shared) async {
        guard mode == .on else { return }
        let today = day(now)
        let oldest = day(now.addingTimeInterval(-14 * 86_400))
        for (day, counts) in store.days().sorted(by: { $0.key < $1.key }) where day < today {
            guard day >= oldest, !counts.isEmpty else { store.remove(day: day); continue }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30
            request.httpBody = try? JSONEncoder().encode(report(day: day, counts: counts))
            guard let (_, response) = try? await session.data(for: request),
                  let status = (response as? HTTPURLResponse)?.statusCode else { return }
            if (200..<300).contains(status) || status == 400 || status == 413 {
                store.remove(day: day)
                log.info("Improvement stats for \(day, privacy: .public): \(status, privacy: .public)")
            } else {
                return
            }
        }
    }

    // MARK: - Asking

    /// Once, after first run, when nothing is going on. The answer is kept;
    /// Settings → About changes it.
    @MainActor
    static func askIfNeeded() {
        guard mode == .unasked else { return }
        while true {
            let alert = NSAlert()
            alert.messageText = String(localized: "Help make Daisy better")
            alert.informativeText = String(localized: "We'd like to know which features people use, and what breaks or goes unnoticed — so we fix and improve what matters to you.\n\nOnce a day, Daisy can send us a short summary: how often recording, dictation and summaries ran, and where something went wrong. No text, titles, names or identifier — we won't know who you are.")
            alert.addButton(withTitle: String(localized: "Help"))
            alert.addButton(withTitle: String(localized: "Not Now"))
            alert.addButton(withTitle: String(localized: "See What's Sent"))
            NSApp.activate()
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                mode = .on
                return
            case .alertSecondButtonReturn:
                mode = .off
                return
            default:
                showPreview()
            }
        }
    }

    /// The report as it goes out, word for word.
    @MainActor
    static func showPreview() {
        let alert = NSAlert()
        alert.messageText = String(localized: "What Daisy sends")
        alert.informativeText = String(localized: "Once a day, one report like this — counts for the day before, the app and macOS versions, the interface language, the update channel and whether sync is on. Nothing else.")
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
        text.string = preview()
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    // MARK: - Storage

    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "ImprovementStats")

    /// UTC days, so a report's day is the same one the server files it under.
    static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static let store = Store(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Daisy/improvement-stats.json"))

    /// Day → counter → count, in one small JSON file.
    final class Store: @unchecked Sendable {
        private let url: URL?
        private let lock = OSAllocatedUnfairLock<[String: [String: Int]]?>(initialState: nil)

        init(url: URL?) { self.url = url }

        func add(_ names: [String], count: Int, day: String) {
            lock.withLock { cached in
                var all = cached ?? load()
                for name in names { all[day, default: [:]][name, default: 0] += count }
                cached = all
                save(all)
            }
        }

        func days() -> [String: [String: Int]] {
            lock.withLock { cached in
                let all = cached ?? load()
                cached = all
                return all
            }
        }

        func remove(day: String) {
            lock.withLock { cached in
                var all = cached ?? load()
                all[day] = nil
                cached = all
                save(all)
            }
        }

        func clear() {
            lock.withLock { cached in
                cached = [:]
                if let url { try? FileManager.default.removeItem(at: url) }
            }
        }

        private func load() -> [String: [String: Int]] {
            guard let url, let data = try? Data(contentsOf: url) else { return [:] }
            return (try? JSONDecoder().decode([String: [String: Int]].self, from: data)) ?? [:]
        }

        private func save(_ all: [String: [String: Int]]) {
            guard let url, let data = try? JSONEncoder().encode(all) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
