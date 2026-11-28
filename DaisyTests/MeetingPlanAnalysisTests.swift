// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  MeetingPlanAnalysisTests.swift
//  DaisyTests
//

import Foundation
import Testing
@testable import Daisy

@Suite("Meeting plan analysis")
struct MeetingPlanAnalysisTests {
    actor FakeProvider: MeetingPlanAnalysisProviding {
        var response: Data
        var error: Error?
        private(set) var calls = 0

        init(response: Data, error: Error? = nil) {
            self.response = response
            self.error = error
        }

        func generate(
            developerInstructions: String,
            userPrompt: String,
            schema: Data
        ) async throws -> Data {
            calls += 1
            if let error { throw error }
            return response
        }

        func callCount() -> Int { calls }
    }

    enum FakeError: Error { case failed }

    @Test("Validator accepts exact timestamped transcript evidence")
    func validEvidence() throws {
        let index = TranscriptEvidenceIndex(markdown: transcript, fallbackDuration: 40)
        try MeetingPlanAnalysisValidator.validate(
            items: [completedItem],
            planItems: preparation().planItems,
            evidenceIndex: index
        )
    }

    @Test("Validator rejects hallucinated quotes, invalid times, duplicates and extras")
    func invalidEvidenceAndIDs() throws {
        let index = TranscriptEvidenceIndex(markdown: transcript, fallbackDuration: 40)
        let hallucinated = MeetingPlanItemAnalysis(
            itemID: "p1",
            status: .completed,
            rationale: "Done",
            evidence: [.init(
                quote: "A quote nobody said",
                startSeconds: 5,
                endSeconds: 10,
                speaker: "Maria"
            )],
            confidence: 0.8,
            recommendations: []
        )
        #expect(throws: MeetingPlanAnalysisValidationError.invalidEvidence(itemID: "p1")) {
            try MeetingPlanAnalysisValidator.validate(
                items: [hallucinated],
                planItems: preparation().planItems,
                evidenceIndex: index
            )
        }

        #expect(throws: MeetingPlanAnalysisValidationError.itemIDs) {
            try MeetingPlanAnalysisValidator.validate(
                items: [completedItem, completedItem],
                planItems: preparation().planItems,
                evidenceIndex: index
            )
        }

        let outOfBounds = MeetingPlanItemAnalysis(
            itemID: "p1",
            status: .completed,
            rationale: "Done",
            evidence: [.init(
                quote: "We confirmed the budget.",
                startSeconds: 5,
                endSeconds: 90,
                speaker: "Maria"
            )],
            confidence: 0.8,
            recommendations: []
        )
        #expect(throws: MeetingPlanAnalysisValidationError.invalidEvidence(itemID: "p1")) {
            try MeetingPlanAnalysisValidator.validate(
                items: [outOfBounds],
                planItems: preparation().planItems,
                evidenceIndex: index
            )
        }

        let invalidConfidence = MeetingPlanItemAnalysis(
            itemID: "p1",
            status: .skipped,
            rationale: "Not covered",
            evidence: [],
            confidence: 1.5,
            recommendations: []
        )
        #expect(throws: MeetingPlanAnalysisValidationError.invalidConfidence(itemID: "p1")) {
            try MeetingPlanAnalysisValidator.validate(
                items: [invalidConfidence],
                planItems: preparation().planItems,
                evidenceIndex: index
            )
        }
    }

    @Test("Pipeline persists, skips identical inputs and regenerates stale analysis")
    func persistenceIdempotencyAndStaleness() async throws {
        try await withDirectory { directory in
            try transcript.write(
                to: directory.appendingPathComponent("transcript.md"),
                atomically: true,
                encoding: .utf8
            )
            let provider = FakeProvider(response: responseData(for: completedItem))
            let pipeline = MeetingPlanAnalysisPipeline(provider: provider)
            let input = MeetingPlanAnalysisPipeline.Input(
                directory: directory,
                title: "Renewal",
                localeHint: "en",
                preparation: preparation(),
                durationSeconds: 40
            )

            _ = try await pipeline.run(input)
            #expect(await provider.callCount() == 1)
            #expect(MeetingPlanAnalysis.load(from: directory) != nil)

            let second = try await pipeline.run(input)
            if case .unchanged = second {} else { Issue.record("Expected unchanged result") }
            #expect(await provider.callCount() == 1)

            let changed = transcript.replacingOccurrences(
                of: "We confirmed the budget.",
                with: "We confirmed the budget and the renewal date."
            )
            try changed.write(
                to: directory.appendingPathComponent("transcript.md"),
                atomically: true,
                encoding: .utf8
            )
            _ = try await pipeline.run(input)
            #expect(await provider.callCount() == 2)
        }
    }

    @Test("Analysis failure leaves an existing summary untouched")
    func failureIsolation() async throws {
        try await withDirectory { directory in
            try transcript.write(
                to: directory.appendingPathComponent("transcript.md"),
                atomically: true,
                encoding: .utf8
            )
            let summaryURL = directory.appendingPathComponent("summary.json")
            let summaryBytes = Data("{\"summary\":\"kept\"}".utf8)
            try summaryBytes.write(to: summaryURL)
            let provider = FakeProvider(response: Data(), error: FakeError.failed)
            let pipeline = MeetingPlanAnalysisPipeline(provider: provider)

            await #expect(throws: (any Error).self) {
                try await pipeline.run(.init(
                    directory: directory,
                    title: "Renewal",
                    localeHint: "en",
                    preparation: preparation(),
                    durationSeconds: 40
                ))
            }
            #expect(try Data(contentsOf: summaryURL) == summaryBytes)
            #expect(MeetingPlanAnalysis.load(from: directory) == nil)
        }
    }

    @Test("Error sidecar persists independently from summary")
    func errorPersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaisyPlanAnalysisError-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = MeetingPlanAnalysisErrorRecord(
            schemaVersion: MeetingPlanAnalysis.currentSchemaVersion,
            promptVersion: MeetingPlanAnalysis.currentPromptVersion,
            planHash: "plan",
            transcriptHash: "transcript",
            failedAt: Date(timeIntervalSince1970: 1_787_000_000),
            message: "Provider unavailable"
        )
        try record.write(to: directory)
        #expect(MeetingPlanAnalysisErrorRecord.load(from: directory) == record)
    }

    @Test("Legacy recording without a saved plan never calls a provider")
    func legacyNoPlan() async throws {
        try await withDirectory { directory in
            try transcript.write(
                to: directory.appendingPathComponent("transcript.md"),
                atomically: true,
                encoding: .utf8
            )
            let provider = FakeProvider(response: Data())
            await #expect(throws: (any Error).self) {
                try await MeetingPlanAnalysisPipeline(provider: provider).run(.init(
                    directory: directory,
                    title: "Legacy",
                    localeHint: "en",
                    preparation: preparation(plan: ""),
                    durationSeconds: 40
                ))
            }
            #expect(await provider.callCount() == 0)
        }
    }

    private var transcript: String {
        """
        ---
        duration_sec: 40
        ---
        # Renewal

        ## Transcript

        **[0:05 · Maria]** We confirmed the budget.

        **[0:20 · Me]** I will send the renewal draft tomorrow.

        ## Shared on screen

        SECRET OCR TEXT
        """
    }

    private var completedItem: MeetingPlanItemAnalysis {
        MeetingPlanItemAnalysis(
            itemID: "p1",
            status: .completed,
            rationale: "Budget was confirmed.",
            evidence: [.init(
                quote: "We confirmed the budget.",
                startSeconds: 5,
                endSeconds: 10,
                speaker: "Maria"
            )],
            confidence: 0.93,
            recommendations: ["Record the exact amount next time."]
        )
    }

    private func responseData(for item: MeetingPlanItemAnalysis) -> Data {
        let object: [String: Any] = ["items": [
            [
                "itemID": item.itemID,
                "status": item.status.rawValue,
                "rationale": item.rationale,
                "evidence": item.evidence.map {
                    [
                        "quote": $0.quote,
                        "startSeconds": $0.startSeconds,
                        "endSeconds": $0.endSeconds,
                        "speaker": $0.speaker.map { $0 as Any } ?? NSNull()
                    ]
                },
                "confidence": item.confidence,
                "recommendations": item.recommendations
            ]
        ]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func preparation(plan: String = "Confirm budget") -> MeetingPreparationSnapshot {
        let meeting = DaisyMeeting(
            externalID: "event-1",
            localID: "local-1",
            title: "Renewal",
            startDate: Date(timeIntervalSince1970: 1_787_000_000),
            endDate: Date(timeIntervalSince1970: 1_787_003_600),
            location: nil,
            notes: nil,
            meetingURL: nil,
            meetingPlatform: nil,
            calendarColorHex: nil,
            attendees: [],
            attendeeEmails: []
        )
        var draft = MeetingPreparation(meeting: meeting, projectSlug: "sales")
        draft.planText = plan
        return MeetingPreparationSnapshot(preparation: draft)
    }

    private func withDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaisyPlanAnalysisTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}
