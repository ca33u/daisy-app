// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  MeetingsHeatmapTests.swift
//  DaisyTests
//


import Foundation
import Testing
@testable import Daisy

@Suite("Meetings heatmap")
struct MeetingsHeatmapTests {
    @Test("Active-day summary only counts visible non-future days")
    func activeDaysUseVisibleWindow() {
        var calendar = Calendar(identifier: .gregorian)
        // Production buckets are local calendar days; mirror that here so
        // dictionary keys have the same midnight normalization as the view.
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 14,
            hour: 12
        ))!
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let outsideWindow = calendar.date(byAdding: .day, value: -30, to: today)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let model = MeetingsHeatmap.build(
            dayCounts: [
                today: 2,
                yesterday: 1,
                outsideWindow: 5,
                tomorrow: 3,
            ],
            weeks: 2,
            now: now
        )

        #expect(model.activeDayCount == 2)
        #expect(model.maxCount == 2)
    }


    @Test("Seven-day mode counts exactly seven rolling days")
    func exactRollingWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: 12))!
        let today = calendar.startOfDay(for: now)
        let sixDaysAgo = calendar.date(byAdding: .day, value: -6, to: today)!
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: today)!

        let model = MeetingsHeatmap.build(
            dayCounts: [today: 1, sixDaysAgo: 1, sevenDaysAgo: 1],
            dayCount: 7,
            now: now
        )

        #expect(model.activeDayCount == 2)
    }

    @Test("Heatmap density grows by whole weeks without month labels")
    func adaptiveLayouts() {
        let week = MeetingsHeatmap.layout(dayCount: 7)
        #expect(week.columnsPerRow == 7)
        #expect(week.weeksPerRow == 1)
        #expect(!week.alignsToCalendarWeeks)

        let month = MeetingsHeatmap.layout(dayCount: 30)
        #expect(month.columnsPerRow == 14)
        #expect(month.weeksPerRow == 2)
        #expect(month.alignsToCalendarWeeks)

        let quarter = MeetingsHeatmap.layout(dayCount: 90)
        #expect(quarter.columnsPerRow == 14)
        #expect(quarter.weeksPerRow == 2)

        let year = MeetingsHeatmap.layout(dayCount: 365)
        #expect(year.columnsPerRow == 28)
        #expect(year.weeksPerRow == 4)
    }
}
