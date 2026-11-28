// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  TranscriptEvidenceIndex.swift
//  Daisy
//
//  Builds a quote/timecode index from the final, timestamped transcript
//  section only. Summary and screen-OCR sections are never indexed.
//

import Foundation

nonisolated struct TranscriptEvidenceIndex: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let startSeconds: Double
        let endSeconds: Double
        let speaker: String
        let text: String
        fileprivate let normalizedText: String
    }

    let transcript: String
    let durationSeconds: Double
    let segments: [Segment]

    static func load(from directory: URL, fallbackDuration: Double) throws -> Self {
        let url = directory.appendingPathComponent("transcript.md")
        let markdown = try String(contentsOf: url, encoding: .utf8)
        return Self(markdown: markdown, fallbackDuration: fallbackDuration)
    }

    init(markdown: String, fallbackDuration: Double) {
        let body = Self.transcriptSection(in: markdown)
        let pattern = #"^\*\*\[([0-9]+(?::[0-9]{2}){1,2})\s+·\s+([^\]]+)\]\*\*\s+(.+)$"#
        let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let nsBody = body as NSString
        let matches = expression?.matches(
            in: body,
            range: NSRange(location: 0, length: nsBody.length)
        ) ?? []
        let raw: [(Double, String, String)] = matches.compactMap { match in
            guard match.numberOfRanges == 4 else { return nil }
            let stamp = nsBody.substring(with: match.range(at: 1))
            guard let seconds = Self.seconds(from: stamp) else { return nil }
            return (
                seconds,
                nsBody.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces),
                nsBody.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let lastStart = raw.last?.0 ?? 0
        let boundedDuration = max(fallbackDuration, lastStart)
        var parsed: [Segment] = []
        for (index, value) in raw.enumerated() {
            let nextStart = index + 1 < raw.count ? raw[index + 1].0 : boundedDuration
            parsed.append(Segment(
                startSeconds: value.0,
                endSeconds: max(value.0, nextStart),
                speaker: value.1,
                text: value.2,
                normalizedText: Self.normalize(value.2)
            ))
        }
        transcript = body.trimmingCharacters(in: .whitespacesAndNewlines)
        durationSeconds = boundedDuration
        segments = parsed
    }

    func contains(_ evidence: MeetingPlanEvidence) -> Bool {
        guard evidence.startSeconds.isFinite,
              evidence.endSeconds.isFinite,
              evidence.startSeconds >= 0,
              evidence.endSeconds >= evidence.startSeconds,
              evidence.endSeconds <= durationSeconds,
              !evidence.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }

        let quote = Self.normalize(evidence.quote)
        guard !quote.isEmpty else { return false }
        return segments.contains { segment in
            let timestampMatches = evidence.startSeconds >= segment.startSeconds - 1
                && evidence.endSeconds <= segment.endSeconds + 1
            let quoteMatches = segment.normalizedText.contains(quote)
            let speakerMatches = evidence.speaker.map {
                Self.normalize($0) == Self.normalize(segment.speaker)
            } ?? true
            return timestampMatches && quoteMatches && speakerMatches
        }
    }

    static func normalize(_ value: String) -> String {
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
        return folded
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
    }

    private static func transcriptSection(in markdown: String) -> String {
        guard let heading = markdown.range(of: "\n## Transcript\n")
            ?? markdown.range(of: "## Transcript\n") else { return "" }
        let tail = String(markdown[heading.upperBound...])
        if let screen = tail.range(of: "\n## Shared on screen\n") {
            return String(tail[..<screen.lowerBound])
        }
        return tail
    }

    private static func seconds(from stamp: String) -> Double? {
        let parts = stamp.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}

nonisolated enum MeetingPlanAnalysisValidationError: LocalizedError, Equatable {
    case invalidJSON
    case itemIDs
    case invalidConfidence(itemID: String)
    case missingEvidence(itemID: String)
    case invalidEvidence(itemID: String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return String(localized: "The model returned an invalid plan analysis.")
        case .itemIDs:
            return String(localized: "The plan analysis did not match the saved plan items.")
        case .invalidConfidence(let id):
            return String(localized: "The confidence value for \(id) was invalid.")
        case .missingEvidence(let id):
            return String(localized: "The model marked \(id) complete without transcript evidence.")
        case .invalidEvidence(let id):
            return String(localized: "The transcript evidence for \(id) could not be verified.")
        }
    }
}

nonisolated enum MeetingPlanAnalysisValidator {
    static func validate(
        items: [MeetingPlanItemAnalysis],
        planItems: [MeetingPreparationSnapshot.PlanItem],
        evidenceIndex: TranscriptEvidenceIndex
    ) throws {
        let expected = planItems.map(\.id)
        let actual = items.map(\.itemID)
        guard actual.count == Set(actual).count,
              Set(actual) == Set(expected),
              actual.count == expected.count else {
            throw MeetingPlanAnalysisValidationError.itemIDs
        }
        for item in items {
            guard item.confidence.isFinite, (0...1).contains(item.confidence) else {
                throw MeetingPlanAnalysisValidationError.invalidConfidence(itemID: item.itemID)
            }
            if item.status == .completed || item.status == .partial, item.evidence.isEmpty {
                throw MeetingPlanAnalysisValidationError.missingEvidence(itemID: item.itemID)
            }
            guard item.evidence.allSatisfy(evidenceIndex.contains) else {
                throw MeetingPlanAnalysisValidationError.invalidEvidence(itemID: item.itemID)
            }
        }
    }
}
