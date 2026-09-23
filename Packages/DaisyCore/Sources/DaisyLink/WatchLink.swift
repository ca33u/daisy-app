//
//  WatchLink.swift
//  DaisyLink
//
//  Бэклог 14 Н-2. The watch has two roles and must never confuse them:
//  a remote control while the phone is in reach, and a poor-but-real
//  recorder when it is not. This file is the rule that decides which
//  one is in force, with no WatchConnectivity, no audio and no UI in
//  it — so the decision can be tested without a watch on a wrist.
//
//  Two things the backlog insists on, and both are rules, not screens:
//
//  1. While the phone is reachable it is the only source of truth. The
//     watch does not keep a recording state of its own, because two
//     states drift and the drift shows up as a lost meeting.
//  2. Standalone recording starts ONLY when the phone could not be
//     reached, and the person is told exactly that. A silent fallback
//     leaves someone wondering why the audio is worse.
//

import Foundation

/// What the phone last told us about itself. The watch stores this and
/// nothing else about recording.
public struct PhoneState: Sendable, Equatable, Codable {
    public var isRecording: Bool
    /// When the phone's recording started — the watch renders its clock
    /// from this, so the two never drift apart by construction.
    public var startedAt: Date?
    /// The phone's own title for what it is recording, if any.
    public var title: String?

    public init(isRecording: Bool = false, startedAt: Date? = nil, title: String? = nil) {
        self.isRecording = isRecording
        self.startedAt = startedAt
        self.title = title
    }

    public static let idle = PhoneState()
}

/// Which role the watch is in right now.
public enum WatchRole: Sendable, Equatable {
    /// The phone answered. It records; the watch shows and commands.
    case remoteControl(PhoneState)
    /// The phone did not answer within the grace period. The watch
    /// records by itself, and says why.
    case standalone(reason: StandaloneReason)
    /// Asked, no answer yet, grace period not over. Nothing is claimed
    /// in either direction — the one state where the watch says
    /// "reaching your phone…" and means it.
    case reaching

    public enum StandaloneReason: Sendable, Equatable {
        /// `WCSession` says the counterpart is not reachable at all.
        case phoneNotReachable
        /// Reachable, but the request went unanswered past the grace
        /// period — asleep, busy, or the app was killed.
        case phoneDidNotAnswer

        /// What the watch screen says. Never a bare "offline": the
        /// person has to understand that the audio will be worse and
        /// why, or they will think the app is broken.
        public var explanation: String {
            switch self {
            case .phoneNotReachable:
                return "Your phone isn't in reach — recording here, on the watch. The sound will be worse, and it moves over when the phone is back."
            case .phoneDidNotAnswer:
                return "Your phone didn't answer — recording here, on the watch. The sound will be worse, and it moves over when the phone is back."
            }
        }
    }
}

/// The decision, made from what is known and when.
public enum WatchLink {
    /// How long the watch waits for the phone before recording itself.
    ///
    /// Short on purpose. The scene is a conference: somebody just
    /// started talking, and a watch that thinks about it for five
    /// seconds has already lost the sentence that mattered. Two
    /// seconds is long enough for a phone in a pocket to answer and
    /// short enough that the opening words survive.
    public static let grace: TimeInterval = 2

    /// - Parameters:
    ///   - reachable: `WCSession.isReachable` at the moment of asking.
    ///   - phone: the last state the phone sent, if it answered.
    ///   - askedAt: when the watch sent its request.
    ///   - now: the clock.
    public static func role(
        reachable: Bool,
        phone: PhoneState?,
        askedAt: Date,
        now: Date,
        grace: TimeInterval = WatchLink.grace
    ) -> WatchRole {
        // An answer settles it, whatever `isReachable` claims — the
        // flag is a hint about the radio, the answer is a fact about
        // the app.
        if let phone { return .remoteControl(phone) }
        if !reachable { return .standalone(reason: .phoneNotReachable) }
        if now.timeIntervalSince(askedAt) >= grace { return .standalone(reason: .phoneDidNotAnswer) }
        return .reaching
    }
}
