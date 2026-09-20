//
//  RecordingActivityAttributes.swift
//  DaisyCore
//
//  The Live Activity's data contract (backlog B-3). Lives here, not in
//  the app target, for the same reason the intents do: the widget
//  extension renders the activity and needs the SAME type the app uses
//  to start/update/end it, and an extension can't import its host app's
//  module.
//
//  `title` is fixed for the activity's lifetime (its static
//  attributes); everything that changes while recording — paused,
//  elapsed time, mic level — is `ContentState`, updated at most once a
//  second per backlog B-3 (ActivityKit's own budget for how often a
//  non-critical push may update).
//

import Foundation
#if os(iOS)
@preconcurrency import ActivityKit

public nonisolated struct RecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var isPaused: Bool
        /// Media time already recorded when this state was pushed —
        /// the widget adds its own ticking `Text(timerInterval:)`
        /// anchored to `referenceDate` for a smooth on-screen clock
        /// between pushes, rather than us pushing every second.
        public var accumulated: TimeInterval
        public var referenceDate: Date
        /// 0...1, smoothed. Not pushed more than once a second.
        public var micLevel: Double
        /// backlog 4 B-1: the recording started from the background on a
        /// mixable audio session, and another app's audio is still
        /// playing — it will be in the recording. The widget shows a
        /// warning line that opens the app to take the strict session.
        public var otherAudioPlaying: Bool

        public init(isPaused: Bool, accumulated: TimeInterval, referenceDate: Date, micLevel: Double, otherAudioPlaying: Bool = false) {
            self.isPaused = isPaused
            self.accumulated = accumulated
            self.referenceDate = referenceDate
            self.micLevel = micLevel
            self.otherAudioPlaying = otherAudioPlaying
        }
    }

    public var title: String

    public init(title: String) {
        self.title = title
    }
}
#endif
