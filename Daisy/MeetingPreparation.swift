// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  MeetingPreparation.swift
//  Daisy
//
//  Local preparation attached to a stable calendar-event identity. The
//  editable draft lives in UserDefaults; when recording begins an immutable
//  snapshot is copied into the session directory so later edits never rewrite
//  the historical context used by that recording.
//

import Foundation
import Observation

nonisolated struct MeetingPlanSource: Codable, Equatable, Sendable {
    let fileName: String
    /// Uniform Type Identifier captured at import time. Metadata only — no
    /// bookmark or source path is retained.
    let typeIdentifier: String
    let importedAt: Date
    let extractedCharacterCount: Int
}

nonisolated struct MeetingPreparation: Codable, Equatable, Sendable, Identifiable {
    let eventID: String
    var eventExternalID: String?
    var eventLocalID: String
    var eventTitle: String
    var eventStart: Date
    var planText: String
    var planSource: MeetingPlanSource?
    var projectSlug: String
    var tag: String
    var linkedTaskIDs: [String]
    var createdAt: Date
    var updatedAt: Date

    var id: String { eventID }

    init(
        meeting: DaisyMeeting,
        projectSlug: String,
        tag: String = "",
        now: Date = Date()
    ) {
        eventID = PreMeetingBriefStore.key(for: meeting)
        eventExternalID = meeting.externalID
        eventLocalID = meeting.localID
        eventTitle = meeting.title
        eventStart = meeting.startDate
        planText = ""
        planSource = nil
        self.projectSlug = projectSlug
        self.tag = tag
        linkedTaskIDs = []
        createdAt = now
        updatedAt = now
    }
}

/// Immutable preparation captured for one recording. This is deliberately a
/// separate type from the editable draft: changing tomorrow's plan must never
/// change what was supplied to a meeting that has already been recorded.
nonisolated struct MeetingPreparationSnapshot: Codable, Equatable, Sendable {
    struct PlanItem: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let text: String
    }

    static let sidecarFilename = "meeting-preparation.json"
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let eventID: String
    let eventExternalID: String?
    let eventLocalID: String
    let eventTitle: String
    let eventStart: Date
    let planText: String
    let planSource: MeetingPlanSource?
    /// Stable, deterministic line items reserved for the post-MVP plan
    /// analysis. The analysis can cite `p1`, `p2`, … without changing the
    /// ordinary summary schema.
    let planItems: [PlanItem]
    let projectSlug: String
    let tag: String
    let briefSourceSessionIDs: [String]
    let linkedTaskIDs: [String]
    let capturedAt: Date

    init(
        preparation: MeetingPreparation,
        briefSourceSessionIDs: [String] = [],
        capturedAt: Date = Date()
    ) {
        schemaVersion = Self.currentSchemaVersion
        eventID = preparation.eventID
        eventExternalID = preparation.eventExternalID
        eventLocalID = preparation.eventLocalID
        eventTitle = preparation.eventTitle
        eventStart = preparation.eventStart
        let normalizedPlan = preparation.planText.trimmingCharacters(in: .whitespacesAndNewlines)
        planText = normalizedPlan
        planSource = preparation.planSource
        planItems = normalizedPlan
            .split(separator: "\n")
            .map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(
                        of: #"^\s*(?:[-*•]|\d+[.)])\s*"#,
                        with: "",
                        options: .regularExpression
                    )
            }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { PlanItem(id: "p\($0.offset + 1)", text: $0.element) }
        projectSlug = preparation.projectSlug
        tag = preparation.tag.trimmingCharacters(in: .whitespacesAndNewlines)
        self.briefSourceSessionIDs = briefSourceSessionIDs
        linkedTaskIDs = preparation.linkedTaskIDs
        self.capturedAt = capturedAt
    }

    func write(to sessionDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(
            to: sessionDirectory.appendingPathComponent(Self.sidecarFilename),
            options: [.atomic]
        )
    }

    static func load(from sessionDirectory: URL) -> Self? {
        let url = sessionDirectory.appendingPathComponent(Self.sidecarFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: data)
    }
}

@MainActor
@Observable
final class MeetingPreparationStore {
    static let shared = MeetingPreparationStore()

    private struct PersistedPayload: Codable {
        var version: Int
        var preparations: [MeetingPreparation]
    }

    private(set) var preparations: [String: MeetingPreparation]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "daisy.meetingPreparations.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let payload = try? JSONDecoder().decode(PersistedPayload.self, from: data) {
            preparations = Dictionary(
                payload.preparations.map { ($0.eventID, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
        } else {
            preparations = [:]
        }
    }

    func preparation(
        for meeting: DaisyMeeting,
        defaultProjectSlug: String,
        suggestedTag: String = ""
    ) -> MeetingPreparation {
        let key = PreMeetingBriefStore.key(for: meeting)
        if var saved = preparations[key] {
            // Calendar providers may update mutable display metadata while
            // retaining the stable event identity. Keep the draft current.
            saved.eventExternalID = meeting.externalID
            saved.eventLocalID = meeting.localID
            saved.eventTitle = meeting.title
            saved.eventStart = meeting.startDate
            return saved
        }
        return MeetingPreparation(
            meeting: meeting,
            projectSlug: defaultProjectSlug,
            tag: suggestedTag
        )
    }

    func save(_ preparation: MeetingPreparation, now: Date = Date()) {
        var value = preparation
        value.updatedAt = now
        preparations[value.eventID] = value
        persist()
    }

    func remove(for meeting: DaisyMeeting) {
        preparations.removeValue(forKey: PreMeetingBriefStore.key(for: meeting))
        persist()
    }

    private func persist() {
        let values = preparations.values.sorted { $0.updatedAt > $1.updatedAt }
        let payload = PersistedPayload(version: 1, preparations: values)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
