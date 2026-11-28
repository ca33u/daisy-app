// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  MeetingAnalyticsTests.swift
//  DaisyTests
//

import Foundation
import Testing
@testable import Daisy

@Suite("Meeting analytics")
struct MeetingAnalyticsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func recording(
        day: Int,
        hour: Int,
        minute: Int = 0,
        durationMinutes: Int,
        folder: String = "work"
    ) -> MeetingAnalytics.Recording {
        MeetingAnalytics.Recording(
            startedAt: date(day, hour, minute),
            durationSec: durationMinutes * 60,
            folderSlug: folder
        )
    }

    @Test("Totals, average, maximum and folder split use recordings only")
    func totalsAndClassification() {
        let snapshot = MeetingAnalytics.snapshot(
            recordings: [
                recording(day: 14, hour: 9, durationMinutes: 30, folder: "private"),
                recording(day: 14, hour: 10, durationMinutes: 60, folder: "work"),
                recording(day: 14, hour: 12, durationMinutes: 90, folder: "inbox"),
            ],
            personalFolderSlugs: ["private"],
            workFolderSlugs: ["work"],
            workday: nil,
            now: date(14, 18),
            calendar: calendar
        )

        #expect(snapshot.totalMeetings == 3)
        #expect(snapshot.personalMeetings == 1)
        // Inbox follows the graph's rule: anything outside Private is work.
        #expect(snapshot.workMeetings == 2)
        #expect(snapshot.totalSeconds == 180 * 60)
        #expect(snapshot.averageSeconds == 60 * 60)
        #expect(snapshot.maximumSeconds == 90 * 60)
        #expect(snapshot.personalSeconds == 30 * 60)
        #expect(snapshot.workSeconds == 150 * 60)
        #expect(snapshot.afterHoursSeconds == nil)
    }

    @Test("After-hours time clips both sides of the configured workday")
    func afterHoursClipping() {
        let snapshot = MeetingAnalytics.snapshot(
            recordings: [
                // One hour before 09:00, one hour inside.
                recording(day: 14, hour: 8, durationMinutes: 120),
                // Half an hour inside, ninety minutes after 17:00.
                recording(day: 14, hour: 16, minute: 30, durationMinutes: 120),
            ],
            personalFolderSlugs: ["private"],
            workFolderSlugs: ["work"],
            workday: .init(startMinutes: 9 * 60, endMinutes: 17 * 60),
            now: date(14, 20),
            calendar: calendar
        )

        #expect(snapshot.afterHoursSeconds == 9_000.0)
    }

    @Test("Daily batteries and back-to-back chains use local calendar days")
    func dailyLoadAndChains() {
        let snapshot = MeetingAnalytics.snapshot(
            recordings: [
                recording(day: 13, hour: 9, durationMinutes: 120, folder: "private"),
                recording(day: 13, hour: 11, minute: 10, durationMinutes: 60),
                recording(day: 13, hour: 12, minute: 20, durationMinutes: 60, folder: "inbox"),
                recording(day: 14, hour: 10, durationMinutes: 30),
            ],
            personalFolderSlugs: ["private"],
            workFolderSlugs: ["work"],
            workday: .init(startMinutes: 9 * 60, endMinutes: 17 * 60),
            summaryRange: .sevenDays,
            now: date(14, 18),
            calendar: calendar
        )

        #expect(snapshot.dayLoads.count == MeetingAnalytics.loadWindowDays)
        #expect(snapshot.dayLoads.suffix(2).first?.meetingSeconds == 14_400.0)
        #expect(snapshot.dayLoads.suffix(2).first?.personalSeconds == 7_200.0)
        // Anything outside Private is work in the two-colour load bar.
        #expect(snapshot.dayLoads.suffix(2).first?.workSeconds == 7_200.0)
        #expect(snapshot.dayLoads.last?.meetingSeconds == 1_800.0)
        #expect(snapshot.longestBackToBackRun == 3)
        // Four meeting-hours consume half of an eight-hour day.
        #expect(snapshot.overloadedDays == 1)
    }

    @Test("Summary range filters calls and duration metrics")
    func summaryRange() {
        let snapshot = MeetingAnalytics.snapshot(
            recordings: [
                recording(day: 7, hour: 9, durationMinutes: 90),
                recording(day: 8, hour: 9, durationMinutes: 30),
                recording(day: 14, hour: 9, durationMinutes: 60),
            ],
            personalFolderSlugs: ["private"],
            workFolderSlugs: ["work"],
            workday: nil,
            summaryRange: .sevenDays,
            now: date(14, 18),
            calendar: calendar
        )

        #expect(snapshot.totalMeetings == 2)
        #expect(snapshot.personalMeetings == 0)
        #expect(snapshot.workMeetings == 2)
        #expect(snapshot.totalSeconds == 5_400.0)
        #expect(snapshot.averageSeconds == 2_700.0)
        #expect(snapshot.maximumSeconds == 3_600.0)
    }

    @Test("After-work time follows the selected summary range")
    func afterWorkUsesSummaryRange() {
        let snapshot = MeetingAnalytics.snapshot(
            recordings: [
                // Outside the seven-day window and therefore excluded.
                recording(day: 7, hour: 18, durationMinutes: 60),
                recording(day: 14, hour: 18, durationMinutes: 30),
            ],
            personalFolderSlugs: ["private"],
            workFolderSlugs: ["work"],
            workday: .init(startMinutes: 9 * 60, endMinutes: 17 * 60),
            summaryRange: .sevenDays,
            now: date(14, 20),
            calendar: calendar
        )

        #expect(snapshot.afterHoursSeconds == 1_800.0)
    }

    @Test("Long periods average load by weekday including quiet days")
    func longPeriodWeekdayAverages() {
        let snapshot = MeetingAnalytics.snapshot(
            recordings: [
                recording(day: 3, hour: 9, durationMinutes: 60),
                recording(day: 10, hour: 9, durationMinutes: 120),
            ],
            personalFolderSlugs: ["private"],
            workFolderSlugs: ["work"],
            workday: .init(startMinutes: 9 * 60, endMinutes: 17 * 60),
            summaryRange: .thirtyDays,
            now: date(14, 18),
            calendar: calendar
        )

        #expect(snapshot.dayLoads.count == 7)
        let monday = snapshot.dayLoads.first {
            calendar.component(.weekday, from: $0.date) == 2
        }
        #expect(monday?.sampleDayCount == 4)
        #expect(monday?.meetingSeconds == 2_700.0)
        #expect(monday?.totalMeetingSeconds == 10_800.0)
    }

    @Test("A meeting crossing the period end is clipped")
    func clipsAtPeriodEnd() {
        let snapshot = MeetingAnalytics.snapshot(
            recordings: [recording(day: 14, hour: 23, durationMinutes: 120)],
            personalFolderSlugs: ["private"],
            workFolderSlugs: ["work"],
            workday: nil,
            summaryRange: .sevenDays,
            now: date(14, 23, 30),
            calendar: calendar
        )

        #expect(snapshot.totalMeetings == 1)
        #expect(snapshot.totalSeconds == 3_600.0)
    }
}
