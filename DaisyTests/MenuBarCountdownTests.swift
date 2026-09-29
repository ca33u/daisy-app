//
//  MenuBarCountdownTests.swift
//  DaisyTests
//
//  The menu-bar label counts down to the next meeting («in 3h 5m»)
//  instead of naming its clock time (Egor, 29.09).
//

import Foundation
import Testing
@testable import Daisy

@Suite("Menu bar countdown")
struct MenuBarCountdownTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// The phrase in the language the app runs in — the tests run in the
    /// Mac's own UI language, which is Russian on Egor's.
    private func phrase(_ english: String, _ russian: String) -> String {
        Bundle.main.preferredLocalizations.first == "ru" ? russian : english
    }

    @Test func hoursAndMinutes() {
        let start = now.addingTimeInterval(3 * 3600 + 5 * 60)
        #expect(CalendarService.countdownPhrase(until: start, now: now) == phrase("in 3h 5m", "через 3 ч 5 мин"))
    }

    @Test func wholeHoursDropTheMinutes() {
        #expect(CalendarService.countdownPhrase(until: now.addingTimeInterval(2 * 3600), now: now) == phrase("in 2h", "через 2 ч"))
    }

    @Test func underAnHourIsMinutesOnly() {
        #expect(CalendarService.countdownPhrase(until: now.addingTimeInterval(42 * 60), now: now) == phrase("in 42m", "через 42 мин"))
    }

    @Test func secondsRoundUpSoOneMinuteNeverReadsAsNow() {
        #expect(CalendarService.countdownPhrase(until: now.addingTimeInterval(20), now: now) == phrase("in 1m", "через 1 мин"))
        #expect(CalendarService.countdownPhrase(until: now.addingTimeInterval(61), now: now) == phrase("in 2m", "через 2 мин"))
    }

    private func meeting(_ title: String, startsIn seconds: TimeInterval) -> DaisyMeeting {
        DaisyMeeting(externalID: nil, localID: title, title: title, startDate: now.addingTimeInterval(seconds),
                     endDate: now.addingTimeInterval(seconds + 3600), location: nil, notes: nil, meetingURL: nil,
                     meetingPlatform: nil, calendarColorHex: nil, attendees: [], attendeeEmails: [])
    }

    /// The tick lands exactly on the start: the meeting stays, reading «now»,
    /// for its first minutes — before, it dropped out at that very tick.
    @MainActor
    @Test func aMeetingAtItsStartStaysAsNowThenGivesWay() {
        let events = [meeting("Standup", startsIn: 0), meeting("Review", startsIn: 3600)]
        #expect(CalendarService.countdownEvent(in: events, now: now)?.title == "Standup")
        let fourMinutesIn = now.addingTimeInterval(4 * 60)
        #expect(CalendarService.countdownEvent(in: events, now: fourMinutesIn)?.title == "Standup")
        let fiveMinutesIn = now.addingTimeInterval(5 * 60)
        #expect(CalendarService.countdownEvent(in: events, now: fiveMinutesIn)?.title == "Review")
        #expect(CalendarService.countdownEvent(in: [meeting("Far", startsIn: 9 * 3600)], now: now) == nil)
    }

    @Test func theClockTicksAtTheStartOfTheNextMinute() {
        let minute: TimeInterval = 799_999_980   // a whole minute since the reference date
        #expect(MinuteClock.nextMinute(after: Date(timeIntervalSinceReferenceDate: minute + 37.4)).timeIntervalSinceReferenceDate == minute + 60)
        #expect(MinuteClock.nextMinute(after: Date(timeIntervalSinceReferenceDate: minute)).timeIntervalSinceReferenceDate == minute + 60)
    }

    @Test func startedOrStartingIsNow() {
        #expect(CalendarService.countdownPhrase(until: now, now: now) == phrase("now", "сейчас"))
        #expect(CalendarService.countdownPhrase(until: now.addingTimeInterval(-30), now: now) == phrase("now", "сейчас"))
    }
}
