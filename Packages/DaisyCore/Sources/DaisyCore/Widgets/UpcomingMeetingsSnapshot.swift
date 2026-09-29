//
//  UpcomingMeetingsSnapshot.swift
//  DaisyCore
//
//  The phone's «next meeting» widget (Egor, 29.09 — the Mac's menu-bar
//  countdown, on the lock and home screens). The app writes the next day
//  of meetings — its calendar and Google, merged — into the App Group; the
//  widget counts down to the first of them. The rule is the Mac's: a
//  meeting that has started stays, reading «now», for its first five
//  minutes, then gives way to the next.
//

import Foundation

public nonisolated struct UpcomingMeetingsSnapshot: Codable, Sendable, Equatable {
    public struct Meeting: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var start: Date
        public var end: Date

        public init(id: String, title: String, start: Date, end: Date) {
            self.id = id
            self.title = title
            self.start = start
            self.end = end
        }
    }

    public var meetings: [Meeting]
    public var writtenAt: Date

    public init(meetings: [Meeting], writtenAt: Date = Date()) {
        self.meetings = meetings
        self.writtenAt = writtenAt
    }

    public static let empty = UpcomingMeetingsSnapshot(meetings: [], writtenAt: .distantPast)
}

public nonisolated enum NextMeeting {
    /// How long a started meeting keeps the countdown, reading «now».
    public static let nowGrace: TimeInterval = 5 * 60
    /// How far ahead the widget looks.
    public static let window: TimeInterval = 24 * 3600

    /// The meeting to count down to: the first, by start, that has not
    /// been running longer than the grace and starts within the window.
    public static func pick(_ meetings: [UpcomingMeetingsSnapshot.Meeting], now: Date) -> UpcomingMeetingsSnapshot.Meeting? {
        meetings
            .filter { $0.start > now.addingTimeInterval(-nowGrace) && $0.start <= now.addingTimeInterval(window) }
            .min { $0.start < $1.start }
    }

    /// The moments the widget has to change without being told: each
    /// meeting's start («now») and the end of its grace (the next one).
    public static func changes(_ meetings: [UpcomingMeetingsSnapshot.Meeting], after now: Date, limit: Int = 12) -> [Date] {
        let moments = meetings.flatMap { [$0.start, $0.start.addingTimeInterval(nowGrace)] }
            .filter { $0 > now }
        return Array(Set(moments)).sorted().prefix(limit).map { $0 }
    }

    /// Two lists of the same day, one meeting once: the same start minute
    /// and the same title are the same meeting (a calendar subscribed on
    /// the phone and the same event read by the app from Google).
    public static func merged(_ lists: [UpcomingMeetingsSnapshot.Meeting]...) -> [UpcomingMeetingsSnapshot.Meeting] {
        var seen = Set<String>()
        var out: [UpcomingMeetingsSnapshot.Meeting] = []
        for meeting in lists.flatMap({ $0 }).sorted(by: { $0.start < $1.start }) {
            let key = "\(meeting.title.lowercased())|\(Int(meeting.start.timeIntervalSince1970 / 60))"
            if seen.insert(key).inserted { out.append(meeting) }
        }
        return out
    }
}

public nonisolated enum UpcomingMeetingsSnapshotStore {
    private static let fileName = "upcoming-meetings.json"

    public static func url(inContainer container: URL) -> URL {
        container.appendingPathComponent(fileName)
    }

    public static func write(_ snapshot: UpcomingMeetingsSnapshot, toContainer container: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url(inContainer: container), options: .atomic)
    }

    public static func read(fromContainer container: URL) -> UpcomingMeetingsSnapshot {
        guard let data = try? Data(contentsOf: url(inContainer: container)) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(UpcomingMeetingsSnapshot.self, from: data)) ?? .empty
    }
}
