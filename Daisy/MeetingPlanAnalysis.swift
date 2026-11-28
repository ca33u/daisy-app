// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  MeetingPlanAnalysis.swift
//  Daisy
//
//  Independent, evidence-backed analysis of a captured meeting plan.
//  This deliberately does not extend MeetingSummary: a summary can be
//  complete even when this optional second pass fails.
//

import CryptoKit
import Foundation

nonisolated enum MeetingPlanItemStatus: String, Codable, CaseIterable, Sendable {
    case completed
    case partial
    case skipped
    case notApplicable
}

nonisolated struct MeetingPlanEvidence: Codable, Equatable, Sendable {
    let quote: String
    let startSeconds: Double
    let endSeconds: Double
    let speaker: String?
}

nonisolated struct MeetingPlanItemAnalysis: Codable, Equatable, Sendable, Identifiable {
    let itemID: String
    let status: MeetingPlanItemStatus
    let rationale: String
    let evidence: [MeetingPlanEvidence]
    let confidence: Double
    let recommendations: [String]

    var id: String { itemID }
}

nonisolated struct MeetingPlanAnalysis: Codable, Equatable, Sendable {
    static let sidecarFilename = "plan-analysis.json"
    static let currentSchemaVersion = 1
    static let currentPromptVersion = "plan-analysis-v1"

    let schemaVersion: Int
    let promptVersion: String
    let planHash: String
    let transcriptHash: String
    let generatedAt: Date
    let items: [MeetingPlanItemAnalysis]

    func matches(planHash: String, transcriptHash: String) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && promptVersion == Self.currentPromptVersion
            && self.planHash == planHash
            && self.transcriptHash == transcriptHash
    }

    static func load(from directory: URL) -> MeetingPlanAnalysis? {
        let url = directory.appendingPathComponent(sidecarFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Self.self, from: data)
    }

    func write(to directory: URL) throws {
        let url = directory.appendingPathComponent(Self.sidecarFilename)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

nonisolated struct MeetingPlanAnalysisErrorRecord: Codable, Equatable, Sendable {
    static let sidecarFilename = "plan-analysis-error.json"

    let schemaVersion: Int
    let promptVersion: String
    let planHash: String
    let transcriptHash: String
    let failedAt: Date
    let message: String

    static func load(from directory: URL) -> Self? {
        let url = directory.appendingPathComponent(sidecarFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: data)
    }

    func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(
            to: directory.appendingPathComponent(Self.sidecarFilename),
            options: .atomic
        )
    }
}
