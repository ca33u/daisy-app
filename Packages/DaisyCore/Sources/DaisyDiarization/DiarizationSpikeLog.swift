//
//  DiarizationSpikeLog.swift
//  DaisyDiarization
//
//  Бэклог 18 Д-5: where the spike's answers go, and — more to the
//  point — where they do NOT go.
//
//  Not `daisy_speaker_map`, and not anywhere inside a session folder.
//  Today the Mac is the one that diarizes phone sessions; if the phone
//  started writing speakers too, two sets of labels would travel
//  through sync and argue, and the loser would be somebody's real
//  meeting. Who wins that argument is a decision for after the
//  numbers, not a side effect of measuring them.
//
//  So: one file, outside the sessions tree, excluded from backup, read
//  by a human and nothing else.
//

import DaisyCore
import Foundation

public enum DiarizationSpikeLog {
    public nonisolated static let fileName = "diarization-spike.json"

    public nonisolated struct Entry: Codable, Sendable {
        public var sessionID: String
        public var at: Date
        /// Whether Whisper was still in memory during this pass — the
        /// whole point of running it twice.
        public var whisperResident: Bool
        public var speakerCount: Int
        public var speakers: [String]
        public var audioSeconds: Double
        public var diarizationSeconds: Double
        public var modelLoadSeconds: Double
        public var peakMemoryMB: Int
        public var phases: [String]
        /// Kept so a later pass can ask whether the owner is among them
        /// — the profile itself does not exist on the phone yet (Д-4).
        public var centroidDimensions: [String: Int]
    }

    /// Beside the sessions folder, never inside one.
    public nonisolated static func url(in base: SessionsBase) -> URL {
        base.base.appendingPathComponent(fileName)
    }

    public nonisolated static func append(
        sessionID: String, whisperResident: Bool, outcome: DiarizationOutcome,
        seconds: Double, modelLoadSeconds: Double, phases: [String], peakMB: Int,
        in base: SessionsBase
    ) {
        let entry = Entry(
            sessionID: sessionID, at: Date(), whisperResident: whisperResident,
            speakerCount: outcome.speakerCount,
            speakers: Set(outcome.spans.map(\.speakerId)).sorted(),
            audioSeconds: outcome.seconds, diarizationSeconds: seconds,
            modelLoadSeconds: modelLoadSeconds, peakMemoryMB: peakMB, phases: phases,
            centroidDimensions: outcome.centroids.mapValues(\.count)
        )
        var all = read(in: base)
        all.append(entry)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(all) else { return }
        try? data.write(to: url(in: base), options: .atomic)
    }

    public nonisolated static func read(in base: SessionsBase) -> [Entry] {
        guard let data = try? Data(contentsOf: url(in: base)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }
}
