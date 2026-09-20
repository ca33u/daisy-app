//
//  SessionAudioFiles.swift
//  DaisyCore
//
//  Copied from daisy-app/Daisy/SessionAudioProcessing.swift
//  (`SessionAudioFiles`, macOS Daisy 1.0.7.72, 2026-09-19). Verbatim
//  apart from `public`. Which files in a session folder are audio, and
//  in what order (session-format.md §2: `microphone.caf`,
//  `microphone.part2.caf`, …; `system_audio.<ext>`).
//

import Foundation

public nonisolated struct SessionAudioFiles: Sendable, Equatable {
    public let microphone: [URL]
    public let system: [URL]

    public var all: [URL] { microphone + system }
    public var hasAny: Bool { !all.isEmpty }

    public static func discover(in directory: URL) -> SessionAudioFiles {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return SessionAudioFiles(
            microphone: parts(in: entries, prefix: "microphone"),
            system: parts(in: entries, prefix: "system_audio")
        )
    }

    /// Container formats a session folder may hold under the
    /// `microphone` / `system_audio` name (§2).
    public nonisolated static let audioExtensions: Set<String> = [
        "caf", "m4a", "mp3", "wav", "aiff", "aif", "aac", "flac",
    ]

    private static func parts(in entries: [URL], prefix: String) -> [URL] {
        entries
            .filter { url in
                let ext = url.pathExtension.lowercased()
                guard audioExtensions.contains(ext) else { return false }
                let stem = url.deletingPathExtension().lastPathComponent
                if stem == prefix { return true }
                let marker = "\(prefix).part"
                guard stem.hasPrefix(marker) else { return false }
                return Int(stem.dropFirst(marker.count)) != nil
            }
            .sorted { partNumber($0, prefix: prefix) < partNumber($1, prefix: prefix) }
    }

    private static func partNumber(_ url: URL, prefix: String) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
        if name == prefix { return 1 }
        let marker = "\(prefix).part"
        guard name.hasPrefix(marker), let value = Int(name.dropFirst(marker.count)) else {
            return Int.max
        }
        return value
    }
}
