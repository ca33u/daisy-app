// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  MeetingsHeatmap.swift
//  Daisy
//
//  Activity heatmap of recording days, built entirely from the local session
//  corpus (each `StoredSession.startedAt`). Calendar weeks flow left-to-right
//  and wrap according to the selected dashboard period. Cell intensity
//  encodes how many recordings happened that day. Purely local, purely
//  derived — no new data, no network.
//

import SwiftUI

struct MeetingsHeatmap: View {
    /// Activity count per local start-of-day (dictations + recordings).
    let dayCounts: [Date: Int]
    /// Exact rolling dashboard period. The grid still aligns to calendar
    /// weeks, but days before the range are blank and never enter totals.
    var dayCount: Int = 26 * 7
    /// The same render boundary used by the rest of Home's dashboard.
    /// Injected from Home so a midnight activation cannot make the grid and
    /// the numeric cards disagree by one day.
    var now: Date = Date()

    private var layout: Layout { Self.layout(dayCount: dayCount) }
    private var gap: CGFloat { layout.gap }
    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 1), spacing: gap),
            count: layout.columnsPerRow
        )
    }

    /// Stable analytics-rail content width retained across periods. HomeView
    /// adds card padding; each adaptive layout stays within this width.
    nonisolated static let defaultGridWidth: CGFloat =
        26 * 11 + 25 * 3

    var body: some View {
        let model = Self.build(dayCounts: dayCounts, dayCount: dayCount, now: now)
        let days = displayDays(for: model)
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: gap) {
                ForEach(days) { day in
                    cellView(day)
                }
            }
            legend(model: model)
        }
    }

    @ViewBuilder
    private func cellView(_ day: DayCell) -> some View {
        RoundedRectangle(cornerRadius: Self.cellCornerRadius, style: .continuous)
            .fill(color(for: day))
            .aspectRatio(1, contentMode: .fit)
            .help(day.outsideWindow ? "" : "\(Self.tooltip(day))")
    }

    private func color(for day: DayCell) -> Color {
        if day.outsideWindow { return .clear }
        switch day.count {
        case 0:      return Color.gray.opacity(0.12)
        case 1:      return Color.daisyHomeAccent.opacity(0.30)
        case 2:      return Color.daisyHomeAccent.opacity(0.50)
        case 3:      return Color.daisyHomeAccent.opacity(0.72)
        default:     return Color.daisyHomeAccent
        }
    }

    private func legend(model: Model) -> some View {
        HStack(spacing: 6) {
            Text("Less")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(0..<5) { level in
                RoundedRectangle(cornerRadius: Self.cellCornerRadius, style: .continuous)
                    .fill(legendColor(level))
                    .frame(width: Self.legendCellSize, height: Self.legendCellSize)
            }
            // Keyed separately from the generic "More" (the ⋯ menu label,
            // RU «Ещё») — as a heatmap-legend pair with "Less" it must
            // read «Меньше/Больше», not «Меньше/Ещё».
            Text(String(localized: "heatmap.legend.more", defaultValue: "More"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(summaryLabel(activeDays: model.activeDayCount))
                .daisyStatLabel()
        }
    }

    private func legendColor(_ level: Int) -> Color {
        switch level {
        case 0: return Color.gray.opacity(0.12)
        case 1: return Color.daisyHomeAccent.opacity(0.30)
        case 2: return Color.daisyHomeAccent.opacity(0.50)
        case 3: return Color.daisyHomeAccent.opacity(0.72)
        default: return Color.daisyHomeAccent
        }
    }

    private func summaryLabel(activeDays: Int) -> String {
        if activeDays == 1 { return String(localized: "1 active day") }
        return String(localized: "\(activeDays) active days")
    }

    // MARK: - Tooltip

    private static func tooltip(_ day: DayCell) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        let date = df.string(from: day.date)
        switch day.count {
        case 0: return String(localized: "No recordings · \(date)")
        case 1: return String(localized: "1 recording · \(date)")
        default: return String(localized: "\(day.count) recordings · \(date)")
        }
    }

    // MARK: - Model (pure, nonisolated)

    struct DayCell: Identifiable {
        var id: Date { date }
        let date: Date
        let count: Int
        let outsideWindow: Bool
    }

    struct Column: Identifiable {
        let id: Int
        let days: [DayCell]
    }

    struct Model {
        let columns: [Column]
        let maxCount: Int
        /// Days with at least one recording or dictation inside the exact
        /// selected window rendered by the grid. This intentionally replaces
        /// the old all-time "sessions" total, which looked like a duplicate
        /// of the recordings-only Calls metric on the card below.
        let activeDayCount: Int
    }

    /// A readable row-major layout for the fixed-width Home rail. Calendar
    /// weeks always stay intact and flow left-to-right; longer ranges place
    /// more whole weeks on each row rather than shrinking 53 columns into
    /// indistinguishable pixels. Month labels are deliberately omitted.
    struct Layout: Equatable, Sendable {
        let weeksPerRow: Int
        let columnsPerRow: Int
        let gap: CGFloat
        let alignsToCalendarWeeks: Bool
    }

    nonisolated static func layout(dayCount: Int) -> Layout {
        switch max(dayCount, 1) {
        case ...7:
            return Layout(
                weeksPerRow: 1,
                columnsPerRow: 7,
                gap: 5,
                alignsToCalendarWeeks: false
            )
        case ...31:
            return Layout(
                weeksPerRow: 2,
                columnsPerRow: 14,
                gap: 4,
                alignsToCalendarWeeks: true
            )
        case ...100:
            return Layout(
                weeksPerRow: 2,
                columnsPerRow: 14,
                gap: 3,
                alignsToCalendarWeeks: true
            )
        default:
            return Layout(
                weeksPerRow: 4,
                columnsPerRow: 28,
                gap: 2,
                alignsToCalendarWeeks: true
            )
        }
    }

    private func displayDays(for model: Model) -> [DayCell] {
        let calendarOrdered = model.columns.flatMap(\.days)
        return layout.alignsToCalendarWeeks
            ? calendarOrdered
            : calendarOrdered.filter { !$0.outsideWindow }
    }

    /// Build a Sunday-aligned grid while counting only the exact rolling
    /// window. This matters most for 7 days, which can span two partial
    /// calendar weeks but must still mean seven days rather than fourteen.
    nonisolated static func build(dayCounts: [Date: Int], dayCount: Int, now: Date) -> Model {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1  // Sunday
        cal.timeZone = .current

        let todayStart = cal.startOfDay(for: now)
        guard let rangeStart = cal.date(byAdding: .day, value: -(max(dayCount, 1) - 1), to: todayStart) else {
            return Model(columns: [], maxCount: 0, activeDayCount: 0)
        }
        let startWeekdayIndex = (cal.component(.weekday, from: rangeStart) - cal.firstWeekday + 7) % 7
        let endWeekdayIndex = (cal.component(.weekday, from: todayStart) - cal.firstWeekday + 7) % 7
        guard let gridStart = cal.date(byAdding: .day, value: -startWeekdayIndex, to: rangeStart),
              let thisWeekStart = cal.date(byAdding: .day, value: -endWeekdayIndex, to: todayStart)
        else { return Model(columns: [], maxCount: 0, activeDayCount: 0) }
        let weeks = max(1, (cal.dateComponents([.day], from: gridStart, to: thisWeekStart).day ?? 0) / 7 + 1)

        var columns: [Column] = []
        var maxCount = 0
        var activeDayCount = 0
        for col in 0..<weeks {
            var days: [DayCell] = []
            for row in 0..<7 {
                let offset = col * 7 + row
                guard let date = cal.date(byAdding: .day, value: offset, to: gridStart) else { continue }
                let outsideWindow = date < rangeStart || date > todayStart
                // `date` is midnight; dayCounts is keyed by start-of-day.
                let count = dayCounts[date] ?? 0
                if !outsideWindow {
                    maxCount = Swift.max(maxCount, count)
                    if count > 0 { activeDayCount += 1 }
                }
                days.append(DayCell(date: date, count: count, outsideWindow: outsideWindow))
            }
            columns.append(Column(id: col, days: days))
        }
        return Model(columns: columns, maxCount: maxCount, activeDayCount: activeDayCount)
    }

    /// Compatibility helper for pure-model tests and older callers.
    nonisolated static func build(dayCounts: [Date: Int], weeks: Int, now: Date) -> Model {
        build(dayCounts: dayCounts, dayCount: max(1, weeks) * 7, now: now)
    }

    private static let legendCellSize: CGFloat = 11
    /// Shared by both the grid and its legend so every heatmap cell has the
    /// requested subtle 2 pt rounding at every dashboard density.
    private static let cellCornerRadius: CGFloat = 2
}
