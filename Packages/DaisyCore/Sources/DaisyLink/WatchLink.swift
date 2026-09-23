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
    /// Set only in the reply to a Record command the phone could not
    /// carry out — a locked phone may not start its microphone from the
    /// background (Egor's phone, 2026-09-23: `kAUStartIO` refused five
    /// times while the wrist waited on "Ready"). Absent from every
    /// other answer, so an old failure never blocks the next attempt.
    public var startFailure: String?

    public init(isRecording: Bool = false, startedAt: Date? = nil, title: String? = nil, startFailure: String? = nil) {
        self.isRecording = isRecording
        self.startedAt = startedAt
        self.title = title
        self.startFailure = startFailure
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
        /// The phone answered and said it could not start — usually
        /// locked, where iOS will not open the microphone for an app in
        /// the background.
        case phoneCouldNotStart

        /// The glance version, and it is deliberately about what WILL
        /// happen, not what is happening. This line is shown while
        /// nothing is being recorded yet; a watch that says "recording
        /// here" before anyone pressed anything is the same kind of
        /// lie as a silent fallback, just pointing the other way.
        public var short: String {
            switch self {
            case .phoneNotReachable: return "Phone not in reach — Record will use the watch"
            case .phoneDidNotAnswer: return "Phone didn't answer — Record will use the watch"
            case .phoneCouldNotStart: return "Phone couldn't start — recording on the watch"
            }
        }

        /// What the watch screen says. Never a bare "offline": the
        /// person has to understand that the audio will be worse and
        /// why, or they will think the app is broken.
        public var explanation: String {
            switch self {
            case .phoneNotReachable:
                return "Your phone isn't in reach — recording here, on the watch. The sound will be worse, and it moves over when the phone is back."
            case .phoneDidNotAnswer:
                return "Your phone didn't answer — recording here, on the watch. The sound will be worse, and it moves over when the phone is back."
            case .phoneCouldNotStart:
                return "Your phone couldn't start recording — it may be locked. Recording here, on the watch; it moves over to the phone afterwards."
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
    /// How long a watch that has just woken may see "not reachable"
    /// before believing it. After a tap on the complication the radio
    /// needs a few seconds to find a phone lying on the table, and
    /// taking that moment for "no phone" recorded on the wrist every
    /// time (Egor, 2026-09-23). An unreachable phone costs these
    /// seconds of the opening; the wrong device costs the meeting.
    public static let reachabilityGrace: TimeInterval = 5

    /// How long an answer stays true.
    ///
    /// Found the hard way (2026-09-23, paired simulators): the phone
    /// app was killed and the watch went on showing "Ready — your
    /// phone records", because nothing had invalidated an answer from
    /// two minutes earlier. An answer is a fact about a moment, not a
    /// standing claim; past this window it counts as silence, and
    /// silence has its own honest handling.
    public static let freshness: TimeInterval = 10

    /// - Parameters:
    ///   - reachable: `WCSession.isReachable` at the moment of asking.
    ///   - phone: the last state the phone sent, if it answered.
    ///   - answeredAt: when that answer arrived. Nil with a non-nil
    ///     `phone` would be a caller bug; it is treated as stale.
    ///   - askedAt: when the watch sent its request.
    ///   - now: the clock.
    ///   - commandInFlight: a start/stop was sent while reachable and
    ///     has had no reply and no error yet.
    public static func role(
        reachable: Bool,
        phone: PhoneState?,
        answeredAt: Date? = nil,
        askedAt: Date,
        now: Date,
        grace: TimeInterval = WatchLink.grace,
        freshness: TimeInterval = WatchLink.freshness,
        commandInFlight: Bool = false,
        reachabilityGrace: TimeInterval = WatchLink.reachabilityGrace
    ) -> WatchRole {
        // An answer settles it, whatever `isReachable` claims — the
        // flag is a hint about the radio, the answer is a fact about
        // the app. But only while it is still recent.
        if let phone, let answeredAt, now.timeIntervalSince(answeredAt) < freshness {
            if phone.startFailure != nil, !phone.isRecording {
                return .standalone(reason: .phoneCouldNotStart)
            }
            return .remoteControl(phone)
        }
        // A Record command is on its way to the phone and has neither
        // been answered nor failed. The phone may already be recording;
        // recording here as well is how one tap made two recordings a
        // second apart (Egor's watch, 2026-09-23, 12:23:42 and :43).
        // Wait for the reply or the delivery error, whichever comes.
        if commandInFlight { return .reaching }
        if !reachable {
            return now.timeIntervalSince(askedAt) >= reachabilityGrace
                ? .standalone(reason: .phoneNotReachable)
                : .reaching
        }
        if now.timeIntervalSince(askedAt) >= grace { return .standalone(reason: .phoneDidNotAnswer) }
        return .reaching
    }
}
