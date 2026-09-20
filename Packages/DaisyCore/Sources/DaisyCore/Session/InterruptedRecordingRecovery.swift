//
//  InterruptedRecordingRecovery.swift
//  DaisyCore
//
//  Copied from daisy-app/Daisy/InterruptedRecordingRecovery.swift (macOS
//  Daisy 1.0.7.72, 2026-09-19). The logic — ordered `.caf` parts, start
//  date from the marker, the §3.5 "recovered recording" profile — is
//  verbatim. The seven `SessionStore` touches and the `WhisperEngine`
//  call are replaced by the `SessionWriting` / `Transcribing` protocols;
//  `ToastCenter`, `SessionsFolder` (security scope) and the UserDefaults
//  locale are gone. The decode-to-16k step is injected too (`decoder`),
//  because it is AVFoundation and the phone's `Resampler` owns it.
//
//  Best-effort BY DESIGN: on ANY failure the folder and its `.recording`
//  marker are left untouched and recovery is retried on the next scan.
//  Nothing is ever deleted here.
//
//  One contract fix on the way through: `duration_sec` is TRUNCATED
//  (§3.1); the Mac rounds here, which §3.5 documents as its bug.
//

import Foundation
import os

@MainActor
public final class InterruptedRecordingRecovery {
    private let log = Logger(subsystem: DaisyCore.logSubsystem, category: "Recovery")
    /// Folders already picked up this launch — keeps repeated scans
    /// from double-processing while a recovery is in flight.
    private var seen: Set<String> = []

    private let engine: any Transcribing
    private let writer: any SessionWriting
    private let decoder: @Sendable ([URL]) async -> [Float]?
    /// Written into the recovered file's body. Localized by the caller,
    /// never keyed on (§3.5).
    public var yourSideHeading = "Your side"
    public var otherSideHeading = "Other side"
    public var markedMomentsHeading = "Marked moments"
    public var explanation = "Recovered after an interrupted session (crash or power loss). Basic transcript — no speaker labels or summary. The audio is in this folder if you want to re-process it."
    public var noSpeech = "No speech detected in the recovered audio."
    /// `daisy_folder` is written only when a default meeting project is
    /// configured (§3.5); nil → absent → inbox.
    public var defaultFolderSlug: String?

    public init(
        engine: any Transcribing,
        writer: any SessionWriting = DiskSessionWriter(),
        decoder: @escaping @Sendable ([URL]) async -> [Float]?
    ) {
        self.engine = engine
        self.writer = writer
        self.decoder = decoder
    }

    /// Kick off best-effort recovery for each interrupted folder. Idempotent.
    public func recover(_ folders: [URL]) {
        for folder in folders {
            let key = folder.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            Task { @MainActor in await self.recoverOne(folder) }
        }
    }

    /// Recover one folder now; returns whether a transcript was written.
    @discardableResult
    public func recoverOne(_ folder: URL) async -> Bool {
        let started = Date()
        let micCafs = Self.cafParts(in: folder, prefix: "microphone")
        let systemCafs = Self.cafParts(in: folder, prefix: "system_audio")
        guard !micCafs.isEmpty || !systemCafs.isEmpty else {
            log.warning("Recovery: no .caf in \(folder.lastPathComponent, privacy: .public) — skipping")
            seen.remove(folder.path)
            return false
        }
        guard engine.isReady else {
            log.notice("Recovery: engine not ready — \(folder.lastPathComponent, privacy: .public) waits")
            seen.remove(folder.path)
            return false
        }

        let mic = await transcribeChannel(micCafs)
        let system = await transcribeChannel(systemCafs)

        guard mic != nil || system != nil else {
            log.error("Recovery: decode/transcribe failed for \(folder.lastPathComponent, privacy: .public) — left intact")
            seen.remove(folder.path)
            return false
        }

        let startDate = Self.startDate(for: folder)
        let durationSec = max(mic?.durationSec ?? 0, system?.durationSec ?? 0)
        let markdown = renderMarkdown(
            startDate: startDate,
            durationSec: durationSec,
            mic: mic?.text,
            system: system?.text,
            markers: MomentMarkerStore.markdownSection(for: folder, heading: markedMomentsHeading)
        )

        do {
            try writer.finish(directory: folder, transcript: markdown)
            log.info("Recovered \(folder.lastPathComponent, privacy: .public) in \(Date().timeIntervalSince(started), privacy: .public)s")
            return true
        } catch {
            log.error("Recovery: writing transcript.md failed for \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public) — audio preserved")
            seen.remove(folder.path)
            return false
        }
    }

    // MARK: - Per-channel decode + transcribe

    private struct ChannelResult { let text: String; let durationSec: Double }

    private func transcribeChannel(_ urls: [URL]) async -> ChannelResult? {
        guard !urls.isEmpty else { return nil }
        guard let samples = await decoder(urls), !samples.isEmpty else { return nil }
        do {
            let segments = try await engine.transcribe(samples: samples)
            let text = segments
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return ChannelResult(text: text, durationSec: Double(samples.count) / 16_000.0)
        } catch {
            log.error("Recovery: transcription failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Pure helpers

    /// Ordered `.caf` parts for a channel (`microphone`, `system_audio`).
    public nonisolated static func cafParts(in folder: URL, prefix: String) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "caf" && $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Start date from the `.recording` marker, falling back to the
    /// folder name, then the folder's creation/modification date.
    public nonisolated static func startDate(for folder: URL) -> Date {
        let marker = folder.appendingPathComponent(SessionWriter.recordingMarkerName)
        if let s = try? String(contentsOf: marker, encoding: .utf8),
           let d = ISO8601DateFormatter().date(from: s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return d
        }
        if let d = SessionID.parse(folder.lastPathComponent) { return d }
        let vals = try? folder.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return vals?.creationDate ?? vals?.contentModificationDate ?? Date()
    }

    /// §3.5 profile: exactly `title`, `started`, `daisy_recovered`,
    /// `daisy_kind: recording`, `duration_sec`, and `daisy_folder` only
    /// when a default project is configured.
    public func renderMarkdown(
        startDate: Date,
        durationSec: Double,
        mic: String?,
        system: String?,
        markers: String = ""
    ) -> String {
        let iso = ISO8601DateFormatter()
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let titleDate = df.string(from: startDate)

        var lines: [String] = []
        lines.append("---")
        lines.append("title: \"Recovered recording — \(titleDate)\"")
        lines.append("started: \(iso.string(from: startDate))")
        lines.append("daisy_recovered: true")
        lines.append("daisy_kind: \(SessionKind.recording.rawValue)")
        lines.append("duration_sec: \(Int(durationSec))")   // truncated (§3.1), not rounded
        if let slug = defaultFolderSlug, !slug.isEmpty {
            lines.append("daisy_folder: \(slug)")
        }
        lines.append("---")
        lines.append("")
        lines.append("# Recovered recording — \(titleDate)")
        lines.append("")
        lines.append("> " + explanation)
        lines.append("")
        if !markers.isEmpty {
            lines.append(markers)
        }

        let micText = mic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sysText = system?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !micText.isEmpty {
            lines.append("## " + yourSideHeading)
            lines.append("")
            lines.append(micText)
            lines.append("")
        }
        if !sysText.isEmpty {
            lines.append("## " + otherSideHeading)
            lines.append("")
            lines.append(sysText)
            lines.append("")
        }
        if micText.isEmpty, sysText.isEmpty {
            lines.append("_" + noSpeech + "_")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
