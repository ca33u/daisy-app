//
//  WatchMessage.swift
//  DaisyLink
//
//  What travels between the wrist and the pocket. `WCSession` carries
//  `[String: Any]`, so the payload is a small dictionary with one
//  JSON-encoded value — not a bag of loose keys, because a bag drifts
//  the moment one side learns a field the other has not.
//

import Foundation

public enum WatchMessage {
    public static let kindKey = "daisy.kind"
    public static let bodyKey = "daisy.body"

    public enum Kind: String, Sendable {
        /// Watch → phone: "are you there, and what are you doing?"
        case askState
        /// Watch → phone: start recording. The phone owns the session.
        case startRecording
        /// Watch → phone: stop.
        case stopRecording
        /// Phone → watch: this is what I am doing. The only answer that
        /// makes the watch a remote control rather than a recorder.
        case state
        /// Phone → watch: I have the file, it is written, you may let
        /// go of your copy. Sent over `transferUserInfo`, never
        /// `sendMessage`: the confirmation has to survive the phone
        /// being out of reach at the moment it is produced, and a lost
        /// confirmation means a recording the watch keeps forever.
        case fileReceived
    }

    /// Metadata that rides along with `transferFile`, so the phone can
    /// build the session without opening the audio first.
    public enum FileKey {
        public static let id = "daisy.recording.id"
        public static let startedAt = "daisy.recording.startedAt"
        public static let seconds = "daisy.recording.seconds"
    }

    public static func fileMetadata(_ recording: PendingRecording) -> [String: Any] {
        [
            FileKey.id: recording.id.uuidString,
            FileKey.startedAt: recording.startedAt.timeIntervalSince1970,
            FileKey.seconds: recording.seconds,
        ]
    }

    public static func confirmation(for id: UUID) -> [String: Any] {
        [kindKey: Kind.fileReceived.rawValue, FileKey.id: id.uuidString]
    }

    /// The id inside a confirmation, or nil when this is not one.
    public static func confirmedID(in message: [String: Any]) -> UUID? {
        guard kind(of: message) == .fileReceived,
              let raw = message[FileKey.id] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    public static func request(_ kind: Kind) -> [String: Any] {
        [kindKey: kind.rawValue]
    }

    public static func reply(_ state: PhoneState) -> [String: Any] {
        var message: [String: Any] = [kindKey: Kind.state.rawValue]
        if let data = try? JSONEncoder().encode(state) { message[bodyKey] = data }
        return message
    }

    public static func kind(of message: [String: Any]) -> Kind? {
        (message[kindKey] as? String).flatMap(Kind.init(rawValue:))
    }

    /// The phone's state out of a reply. Nil means "this was not an
    /// answer about state" — and the caller must treat that exactly
    /// like silence, never like "the phone is idle". Deciding the
    /// phone is idle on a malformed reply is how a watch starts a
    /// second recording of the same meeting.
    public static func state(in message: [String: Any]) -> PhoneState? {
        guard kind(of: message) == .state, let data = message[bodyKey] as? Data else { return nil }
        return try? JSONDecoder().decode(PhoneState.self, from: data)
    }
}
