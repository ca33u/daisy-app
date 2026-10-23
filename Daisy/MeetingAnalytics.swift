//
//  MeetingAnalytics.swift
//  Daisy
//
//  Pure, local calculations for the Home meeting widgets. The inputs are
//  metadata Daisy already stores (start, duration, folder); transcript text,
//  attendee identities and audio never enter this layer.
//

import Foundation

/// One rolling window shared by every local analytics card on Home.
/// The raw value for 30 days deliberately stays `month` so existing
/// AppStorage selections migrate without a reset.
nonisolated enum DashboardPeriod: String, CaseIterable, Identifiable, Sendable {
    case sevenDays
    case thirtyDays = "month"
    case ninetyDays
    case year

    var id: Self { self }

    var dayCount: Int {
        switch self {
        case .sevenDays: 7
        case .thirtyDays: 30
        case .ninetyDays: 90
        case .year: 365
        }
    }

    /// Calendar-aware resolution for the token chart. Totals still use
    /// every individual day; this controls only how adjacent values are
    /// grouped for display.
    var tokenChartInterval: TokenChartInterval {
        switch self {
        case .sevenDays, .thirtyDays: .day
        case .ninetyDays: .week
        case .year: .month
        }
    }

    func dayKeys(endingAt end: Date, calendar: Calendar = .current) -> [String] {
        var calendar = calendar
        calendar.timeZone = .current
        return (0..<dayCount).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: end)
                .map { UsageStats.dayKey(for: $0) }
        }
    }
}

nonisolated enum TokenChartInterval: String, Sendable, Equatable {
    case day
    case week
    case month
}

nonisolated enum MeetingAnalytics {
    static let loadWindowDays = 7
    static let backToBackGapSeconds: TimeInterval = 15 * 60

    typealias SummaryRange = DashboardPeriod

    struct Recording: Sendable {
        let startedAt: Date
        let durationSec: Int
        let folderSlug: String

        var endedAt: Date { startedAt.addingTimeInterval(TimeInterval(max(0, durationSec))) }
    }

    struct Workday: Sendable, Equatable {
        let startMinutes: Int
        let endMinutes: Int

        var durationSeconds: Double {
            Double(max(0, endMinutes - startMinutes) * 60)
        }
    }

    struct DayLoad: Identifiable, Sendable {
        var id: Date { date }
        let date: Date
        let meetingSeconds: Double
        /// Private-folder time. Every other recording is rendered as work
        /// in the two-colour daily bar so no load disappears as unclassified.
        let personalSeconds: Double
        let workSeconds: Double
        let meetingCount: Int
        let capacitySeconds: Double
        /// More than one sample means this row is an average weekday for
        /// a 30/90/365-day window rather than one specific calendar date.
        let sampleDayCount: Int
        let totalMeetingSeconds: Double

        var utilization: Double {
            guard capacitySeconds > 0 else { return 0 }
            return meetingSeconds / capacitySeconds
        }

        var isAverage: Bool { sampleDayCount > 1 }
    }

    struct Snapshot: Sendable {
        let totalMeetings: Int
        let personalMeetings: Int
        let workMeetings: Int
        let totalSeconds: Double
        let averageSeconds: Double
        let maximumSeconds: Double
        let personalSeconds: Double
        let workSeconds: Double
        let afterHoursSeconds: Double?
        let longestBackToBackRun: Int
        let overloadedDays: Int
        let dayLoads: [DayLoad]

        var classifiedSeconds: Double { personalSeconds + workSeconds }
    }

    static func snapshot(
        sessions: [StoredSession],
        personalFolderSlugs: Set<String>,
        workFolderSlugs: Set<String>,
        workday: Workday?,
        summaryRange: SummaryRange = .year,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Snapshot {
        let recordings = sessions
            .filter { $0.kind == .recording && $0.durationSec > 0 && !$0.isDemo }
            .map {
                Recording(
                    startedAt: $0.startedAt,
                    durationSec: $0.durationSec,
                    folderSlug: $0.folderSlug.lowercased()
                )
            }
        return snapshot(
            recordings: recordings,
            personalFolderSlugs: personalFolderSlugs,
            workFolderSlugs: workFolderSlugs,
            workday: workday,
            summaryRange: summaryRange,
            now: now,
            calendar: calendar
        )
    }

    /// Input-only overload used by tests and future API surfaces. Keeping
    /// the calculation independent of SessionStore makes its classification
    /// and calendar edges deterministic.
    static func snapshot(
        recordings: [Recording],
        personalFolderSlugs: Set<String>,
        workFolderSlugs: Set<String>,
        workday: Workday?,
        summaryRange: SummaryRange = .year,
        now: Date,
        calendar: Calendar
    ) -> Snapshot {
        let valid = recordings.filter { $0.durationSec > 0 }
        var cal = calendar
        cal.timeZone = calendar.timeZone
        let today = cal.startOfDay(for: now)
        let summaryStart = cal.date(
            byAdding: .day,
            value: -(summaryRange.dayCount - 1),
            to: today
        ) ?? today
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? now
        // A meeting belongs to the period by its start. Its duration is
        // clipped at the exact interval end so a call crossing midnight
        // cannot leak time into the next dashboard period.
        let summaryRecordings = valid.compactMap { recording -> Recording? in
            guard recording.startedAt >= summaryStart, recording.startedAt < tomorrow else {
                return nil
            }
            let clippedEnd = min(recording.endedAt, tomorrow)
            let duration = Int(max(0, clippedEnd.timeIntervalSince(recording.startedAt)))
            guard duration > 0 else { return nil }
            return Recording(
                startedAt: recording.startedAt,
                durationSec: duration,
                folderSlug: recording.folderSlug
            )
        }

        let total = summaryRecordings.reduce(0.0) { $0 + Double($1.durationSec) }
        let personalCount = summaryRecordings.filter {
            personalFolderSlugs.contains($0.folderSlug.lowercased())
        }.count
        let personal = summaryRecordings
            .filter { personalFolderSlugs.contains($0.folderSlug.lowercased()) }
            .reduce(0.0) { $0 + Double($1.durationSec) }
        // The product has two visible classes: Private is personal and
        // everything else is work. This keeps time and counts additive.
        let work = max(0, total - personal)
        _ = workFolderSlugs

        let periodRecordings = valid.compactMap {
            clipped($0, start: summaryStart, end: tomorrow)
        }

        let loads: [DayLoad]
        if let workday, workday.durationSeconds > 0 {
            let dates = (0..<summaryRange.dayCount).compactMap { offset in
                cal.date(
                    byAdding: .day,
                    value: offset - (summaryRange.dayCount - 1),
                    to: today
                )
            }
            let daily = dates.map { date -> DayLoad in
                load(
                    on: date,
                    recordings: periodRecordings,
                    personalFolderSlugs: personalFolderSlugs,
                    workday: workday,
                    calendar: cal
                )
            }
            if summaryRange == .sevenDays {
                loads = daily
            } else {
                // One stable Sunday–Saturday row set. Every zero day is a
                // real sample, so averages are not inflated by considering
                // only weekdays that happened to contain meetings.
                loads = (1...7).compactMap { weekday -> DayLoad? in
                    let samples = daily.filter {
                        cal.component(.weekday, from: $0.date) == weekday
                    }
                    guard let representative = samples.last, !samples.isEmpty else { return nil }
                    let count = Double(samples.count)
                    let totalSeconds = samples.reduce(0) { $0 + $1.meetingSeconds }
                    let totalPersonal = samples.reduce(0) { $0 + $1.personalSeconds }
                    return DayLoad(
                        date: representative.date,
                        meetingSeconds: totalSeconds / count,
                        personalSeconds: totalPersonal / count,
                        workSeconds: max(0, totalSeconds - totalPersonal) / count,
                        meetingCount: samples.reduce(0) { $0 + $1.meetingCount },
                        capacitySeconds: workday.durationSeconds,
                        sampleDayCount: samples.count,
                        totalMeetingSeconds: totalSeconds
                    )
                }
            }
        } else {
            loads = []
        }

        // The summary card's period selector owns every number on that card.
        // Using the fixed 28-day load window here made "After work" disagree
        // with Calls / Total time when Month or Year was selected.
        let afterHours: Double? = workday.map { hours in
            summaryRecordings.reduce(0.0) { partial, recording in
                partial + afterHoursSeconds(of: recording, workday: hours, calendar: cal)
            }
        }
        let overloaded: Int
        if let workday, workday.durationSeconds > 0 {
            overloaded = (0..<summaryRange.dayCount).compactMap { offset in
                cal.date(byAdding: .day, value: offset - (summaryRange.dayCount - 1), to: today)
            }.filter { date in
                periodRecordings.reduce(0.0) { $0 + seconds(of: $1, on: date, calendar: cal) }
                    / workday.durationSeconds >= 0.5
            }.count
        } else {
            overloaded = 0
        }

        return Snapshot(
            totalMeetings: summaryRecordings.count,
            personalMeetings: personalCount,
            // Match the two-colour load graph: Private is personal and
            // everything else is work, so the two counts always add to total.
            workMeetings: summaryRecordings.count - personalCount,
            totalSeconds: total,
            averageSeconds: summaryRecordings.isEmpty ? 0 : total / Double(summaryRecordings.count),
            maximumSeconds: Double(summaryRecordings.map(\.durationSec).max() ?? 0),
            personalSeconds: personal,
            workSeconds: work,
            afterHoursSeconds: afterHours,
            longestBackToBackRun: longestBackToBackRun(in: summaryRecordings, calendar: cal),
            overloadedDays: overloaded,
            dayLoads: loads
        )
    }

    private static func clipped(_ recording: Recording, start: Date, end: Date) -> Recording? {
        let clippedStart = max(recording.startedAt, start)
        let clippedEnd = min(recording.endedAt, end)
        let duration = Int(max(0, clippedEnd.timeIntervalSince(clippedStart)))
        guard duration > 0 else { return nil }
        return Recording(
            startedAt: clippedStart,
            durationSec: duration,
            folderSlug: recording.folderSlug
        )
    }

    private static func load(
        on date: Date,
        recordings: [Recording],
        personalFolderSlugs: Set<String>,
        workday: Workday,
        calendar: Calendar
    ) -> DayLoad {
        let total = recordings.reduce(0.0) {
            $0 + seconds(of: $1, on: date, calendar: calendar)
        }
        let personal = recordings
            .filter { personalFolderSlugs.contains($0.folderSlug.lowercased()) }
            .reduce(0.0) { $0 + seconds(of: $1, on: date, calendar: calendar) }
        return DayLoad(
            date: date,
            meetingSeconds: total,
            personalSeconds: personal,
            workSeconds: max(0, total - personal),
            meetingCount: recordings.filter { calendar.isDate($0.startedAt, inSameDayAs: date) }.count,
            capacitySeconds: workday.durationSeconds,
            sampleDayCount: 1,
            totalMeetingSeconds: total
        )
    }

    /// Portion of a recording that lands on one local calendar day.
    private static func seconds(
        of recording: Recording,
        on day: Date,
        calendar: Calendar
    ) -> Double {
        let startOfDay = calendar.startOfDay(for: day)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return 0
        }
        let start = max(recording.startedAt, startOfDay)
        let end = min(recording.endedAt, endOfDay)
        return max(0, end.timeIntervalSince(start))
    }

    /// Exact outside-workday overlap, including recordings that cross
    /// midnight or either workday boundary.
    private static func afterHoursSeconds(
        of recording: Recording,
        workday: Workday,
        calendar: Calendar
    ) -> Double {
        guard workday.durationSeconds > 0 else { return Double(recording.durationSec) }
        var outside = 0.0
        var day = calendar.startOfDay(for: recording.startedAt)
        let lastDay = calendar.startOfDay(for: recording.endedAt)

        while day <= lastDay {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
                  let workStart = calendar.date(byAdding: .minute, value: workday.startMinutes, to: day),
                  let workEnd = calendar.date(byAdding: .minute, value: workday.endMinutes, to: day)
            else { break }

            let sliceStart = max(recording.startedAt, day)
            let sliceEnd = min(recording.endedAt, nextDay)
            let slice = max(0, sliceEnd.timeIntervalSince(sliceStart))
            let insideStart = max(sliceStart, workStart)
            let insideEnd = min(sliceEnd, workEnd)
            let inside = max(0, insideEnd.timeIntervalSince(insideStart))
            outside += max(0, slice - inside)
            day = nextDay
        }
        return outside
    }

    /// Longest same-day chain where the next meeting starts within 15
    /// minutes of the previous one ending. Overlaps count as one chain.
    private static func longestBackToBackRun(
        in recordings: [Recording],
        calendar: Calendar
    ) -> Int {
        let grouped = Dictionary(grouping: recordings) {
            calendar.startOfDay(for: $0.startedAt)
        }
        var longest = 0
        for day in grouped.values {
            let sorted = day.sorted { $0.startedAt < $1.startedAt }
            guard var previousEnd = sorted.first?.endedAt else { continue }
            var run = 1
            longest = max(longest, run)
            for recording in sorted.dropFirst() {
                if recording.startedAt.timeIntervalSince(previousEnd) <= backToBackGapSeconds {
                    run += 1
                } else {
                    run = 1
                }
                previousEnd = max(previousEnd, recording.endedAt)
                longest = max(longest, run)
            }
        }
        return longest
    }
}
