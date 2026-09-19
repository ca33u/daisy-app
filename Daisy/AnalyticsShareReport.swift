//
//  AnalyticsShareReport.swift
//  Daisy
//
//  A deliberately public-safe view of Home analytics. The share snapshot
//  contains aggregate counts only: no meeting titles, attendees, projects,
//  transcript text, token usage or AI cost. It is rendered locally to PNG
//  for both the system share picker and Save panel.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AnalyticsShareSnapshot: Sendable {
    let period: DashboardPeriod
    let generatedAt: Date
    let displayName: String
    let dayCounts: [Date: Int]
    let meetingCount: Int
    let totalMeetingSeconds: Double
    let activeDays: Int
    let currentStreak: Int

    var normalizedDisplayName: String? {
        let value = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct AnalyticsShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: AnalyticsShareSnapshot

    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Share analytics")
                    .font(.title2.weight(.semibold))
                Text("A public-safe card with aggregate activity only. Meeting names, people, projects and AI usage are not included.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 18)

            ScrollView([.horizontal, .vertical]) {
                AnalyticsShareCard(snapshot: snapshot)
                    .frame(width: AnalyticsShareCard.canvasWidth)
                    .shadow(color: .black.opacity(0.10), radius: 24, y: 12)
                    .padding(30)
            }
            .background(Color.primary.opacity(0.025))

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 10)
            }

            HStack(spacing: 10) {
                Button("Close") { dismiss() }
                    .buttonStyle(.daisyQuiet)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    saveCard()
                } label: {
                    Label("Save PNG", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.daisySecondary)

                Button {
                    shareCard()
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.daisyPrimary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .frame(minWidth: 780, minHeight: 650)
    }

    private func saveCard() {
        do {
            try AnalyticsShareExporter.save(snapshot: snapshot)
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Couldn’t save the analytics card.")
        }
    }

    private func shareCard() {
        do {
            try AnalyticsShareExporter.share(snapshot: snapshot)
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Couldn’t prepare the analytics card for sharing.")
        }
    }
}

struct AnalyticsShareCard: View {
    static let canvasWidth: CGFloat = 720

    let snapshot: AnalyticsShareSnapshot

    private var heatmapModel: MeetingsHeatmap.Model {
        MeetingsHeatmap.build(
            dayCounts: snapshot.dayCounts,
            dayCount: snapshot.period.dayCount,
            now: snapshot.generatedAt
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            header

            ShareHeatmap(
                model: heatmapModel,
                period: snapshot.period
            )

            // No divider lines anywhere on the card (Egor, 2026-08-21) —
            // whitespace alone separates the heatmap from the metrics.
            HStack(spacing: 0) {
                metric(snapshot.meetingCount.formatted(.number), "Meetings")
                metric(duration(snapshot.totalMeetingSeconds), "Meeting time")
                metric(snapshot.activeDays.formatted(.number), "Active days")
                metric(snapshot.currentStreak.formatted(.number), "Current streak")
            }
        }
        .padding(34)
        .background(Color(hex: 0xFBF9F5))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.black.opacity(0.07), lineWidth: 1)
        }
        .environment(\.colorScheme, .light)
    }

    // No avatar circle and no flower marks (Egor, 2026-08-21): just the
    // name/period on the left and the word "Daisy" on the right.
    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.normalizedDisplayName ?? String(localized: "My activity"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(hex: 0x242422))
                    .lineLimit(1)
                Text(periodCaption)
                    .font(.callout)
                    .foregroundStyle(Color(hex: 0x77746F))
            }

            Spacer()

            Text("Daisy")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(hex: 0x77746F))
        }
    }

    private var periodCaption: String {
        let start = Calendar.current.date(
            byAdding: .day,
            value: -(snapshot.period.dayCount - 1),
            to: snapshot.generatedAt
        ) ?? snapshot.generatedAt
        let range = "\(start.formatted(date: .abbreviated, time: .omitted)) – \(snapshot.generatedAt.formatted(date: .abbreviated, time: .omitted))"
        return "\(snapshot.period.shareTitle) · \(range)"
    }

    private func metric(
        _ value: String,
        _ label: LocalizedStringKey
    ) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color(hex: 0x242422))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(.callout)
                .foregroundStyle(Color(hex: 0x77746F))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private func duration(_ seconds: Double) -> String {
        guard seconds >= 60 else { return seconds > 0 ? String(localized: "<1m") : "—" }
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0, remainder > 0 { return String(localized: "\(hours)h \(remainder)m") }
        if hours > 0 { return String(localized: "\(hours)h") }
        return String(localized: "\(minutes)m")
    }
}

private struct ShareHeatmap: View {
    let model: MeetingsHeatmap.Model
    let period: DashboardPeriod

    private var layout: MeetingsHeatmap.Layout {
        MeetingsHeatmap.layout(dayCount: period.dayCount)
    }

    private var days: [MeetingsHeatmap.DayCell] {
        let values = model.columns.flatMap(\.days)
        return layout.alignsToCalendarWeeks ? values : values.filter { !$0.outsideWindow }
    }

    var body: some View {
        GeometryReader { proxy in
            let columns = max(layout.columnsPerRow, 1)
            let gap = layout.gap
            let width = max(
                2,
                (proxy.size.width - (CGFloat(columns - 1) * gap)) / CGFloat(columns)
            )
            let grid = Array(
                repeating: GridItem(.fixed(width), spacing: gap),
                count: columns
            )

            LazyVGrid(columns: grid, alignment: .leading, spacing: gap) {
                ForEach(days) { day in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(for: day))
                        .frame(width: width, height: width)
                }
            }
        }
        .frame(height: gridHeight)
    }

    private var gridHeight: CGFloat {
        let rowCount = Int(ceil(Double(days.count) / Double(max(layout.columnsPerRow, 1))))
        let availableWidth = AnalyticsShareCard.canvasWidth - 68
        let cell = max(
            2,
            (availableWidth - CGFloat(layout.columnsPerRow - 1) * layout.gap)
                / CGFloat(max(layout.columnsPerRow, 1))
        )
        return CGFloat(rowCount) * cell + CGFloat(max(rowCount - 1, 0)) * layout.gap
    }

    private func color(for day: MeetingsHeatmap.DayCell) -> Color {
        if day.outsideWindow { return .clear }
        switch day.count {
        case 0: return Color(hex: 0xE9E7E3)
        case 1: return Color(hex: 0xF9D9B7)
        case 2: return Color(hex: 0xF7BC7C)
        case 3: return Color(hex: 0xF39B42)
        default: return Color(hex: 0xE77720)
        }
    }
}

@MainActor
private enum AnalyticsShareExporter {
    private static var sharingPicker: NSSharingServicePicker?

    static func save(snapshot: AnalyticsShareSnapshot) throws {
        let data = try pngData(snapshot: snapshot)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileName(snapshot: snapshot)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
        ToastCenter.shared.show(String(localized: "Analytics card saved"), style: .success)
    }

    static func share(snapshot: AnalyticsShareSnapshot) throws {
        let data = try pngData(snapshot: snapshot)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName(snapshot: snapshot))
        try data.write(to: url, options: .atomic)

        guard let view = NSApp.keyWindow?.contentView else {
            throw CocoaError(.fileNoSuchFile)
        }
        let picker = NSSharingServicePicker(items: [url])
        sharingPicker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    private static func pngData(snapshot: AnalyticsShareSnapshot) throws -> Data {
        let renderer = ImageRenderer(
            content: AnalyticsShareCard(snapshot: snapshot)
                .frame(width: AnalyticsShareCard.canvasWidth)
        )
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            throw CocoaError(.fileWriteUnknown)
        }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private static func fileName(snapshot: AnalyticsShareSnapshot) -> String {
        "Daisy-Analytics-\(UsageStats.dayKey(for: snapshot.generatedAt)).png"
    }
}

private extension DashboardPeriod {
    var shareTitle: String {
        switch self {
        case .sevenDays: String(localized: "7 days")
        case .thirtyDays: String(localized: "30 days")
        case .ninetyDays: String(localized: "90 days")
        case .year: String(localized: "1 year")
        }
    }
}
