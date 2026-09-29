//
//  NextMeetingTests.swift
//  DaisyCoreTests
//
//  The phone's next-meeting widget counts down like the Mac's menu bar:
//  a meeting at its start reads «now» for five minutes, then gives way.
//

import Foundation
import Testing
@testable import DaisyCore

@Suite("Next meeting (widget)")
struct NextMeetingTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func meeting(_ title: String, in seconds: TimeInterval) -> UpcomingMeetingsSnapshot.Meeting {
        .init(id: title, title: title, start: now.addingTimeInterval(seconds), end: now.addingTimeInterval(seconds + 1800))
    }

    @Test func theNearestAheadIsPickedAndAStartedOneStaysForFiveMinutes() {
        let list = [meeting("Review", in: 3600), meeting("Standup", in: -4 * 60), meeting("Old", in: -20 * 60)]
        #expect(NextMeeting.pick(list, now: now)?.title == "Standup")
        #expect(NextMeeting.pick(list, now: now.addingTimeInterval(60))?.title == "Review")
        #expect(NextMeeting.pick([meeting("Tomorrow+", in: 25 * 3600)], now: now) == nil)
    }

    @Test func theWidgetChangesAtEachStartAndAtTheEndOfItsGrace() {
        let list = [meeting("A", in: 600), meeting("B", in: 3600)]
        let changes = NextMeeting.changes(list, after: now)
        #expect(changes == [now.addingTimeInterval(600), now.addingTimeInterval(900),
                            now.addingTimeInterval(3600), now.addingTimeInterval(3900)])
    }

    @Test func theSameMeetingFromTwoCalendarsIsOne() {
        let apple = [meeting("Sync", in: 600)]
        let google = [meeting("sync", in: 600), meeting("Other", in: 1200)]
        #expect(NextMeeting.merged(apple, google).map(\.title) == ["Sync", "Other"])
    }

    @Test func theSnapshotRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = UpcomingMeetingsSnapshot(meetings: [meeting("Sync", in: 600)], writtenAt: now)
        UpcomingMeetingsSnapshotStore.write(snapshot, toContainer: dir)
        #expect(UpcomingMeetingsSnapshotStore.read(fromContainer: dir) == snapshot)
    }
}
