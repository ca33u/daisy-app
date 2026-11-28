// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  MeetingPlanAnalysisView.swift
//  Daisy
//

import SwiftUI

struct MeetingPlanAnalysisView: View {
    let session: StoredSession
    @Bindable private var store = MeetingPlanAnalysisStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Plan review")
                    .font(.headline)
                    .foregroundStyle(Color.daisyTextPrimary)
                Spacer()
                if case .failed = store.state(for: session) {
                    Button("Retry") { store.retry(for: session) }
                        .controlSize(.small)
                }
            }

            switch store.state(for: session) {
            case .idle:
                HStack(spacing: 10) {
                    Text("The plan will be reviewed after a summary is generated.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Analyze plan") { store.retry(for: session) }
                        .controlSize(.small)
                }
            case .analyzing:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Analyzing the meeting against the saved plan…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .ready(let analysis):
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(analysis.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.vertical, 14) }
                        itemView(item)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.daisyBgSidebar)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
        )
    }

    private func itemView(_ item: MeetingPlanItemAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: statusIcon(item.status))
                    .foregroundStyle(statusColor(item.status))
                Text(planText(for: item.itemID))
                    .font(.body.weight(.semibold))
                Spacer()
                Text(statusLabel(item.status))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor(item.status))
                Text(verbatim: "\(Int((item.confidence * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(item.rationale)
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, evidence in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(timeRange(evidence))
                            .font(.caption.monospacedDigit().weight(.medium))
                        if let speaker = evidence.speaker, !speaker.isEmpty {
                            Text(verbatim: "· \(speaker)").font(.caption)
                        }
                    }
                    .foregroundStyle(Color.daisyHomeAccent)
                    Text("“\(evidence.quote)”")
                        .font(.callout)
                        .foregroundStyle(Color.daisyTextPrimary)
                }
                .padding(.leading, 24)
            }
            ForEach(item.recommendations, id: \.self) { recommendation in
                Label(recommendation, systemImage: "arrow.right")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func planText(for itemID: String) -> String {
        session.meetingPreparation?.planItems.first(where: { $0.id == itemID })?.text ?? itemID
    }

    private func statusLabel(_ status: MeetingPlanItemStatus) -> String {
        switch status {
        case .completed: return String(localized: "Completed")
        case .partial: return String(localized: "Partially covered")
        case .skipped: return String(localized: "Skipped")
        case .notApplicable: return String(localized: "Not applicable")
        }
    }

    private func statusIcon(_ status: MeetingPlanItemStatus) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .partial: return "circle.lefthalf.filled"
        case .skipped: return "minus.circle"
        case .notApplicable: return "slash.circle"
        }
    }

    private func statusColor(_ status: MeetingPlanItemStatus) -> Color {
        switch status {
        case .completed: return .green
        case .partial: return Color.daisyHomeAccent
        case .skipped, .notApplicable: return Color.daisyTextSecondary
        }
    }

    private func timeRange(_ evidence: MeetingPlanEvidence) -> String {
        let start = Self.timecode(evidence.startSeconds)
        let end = Self.timecode(evidence.endSeconds)
        return start == end ? start : "\(start)–\(end)"
    }

    private static func timecode(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainder) }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
