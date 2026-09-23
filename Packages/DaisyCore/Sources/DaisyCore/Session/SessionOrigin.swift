//
//  SessionOrigin.swift
//  DaisyCore
//
//  §3.6: which stream is the owner, and which is the room.
//
//  A Mac session's microphone IS the owner (§2.1). Everything else —
//  a phone, a watch, a file someone imported — records a room with one
//  microphone and everyone in it. The contract says the values of
//  `daisy_origin` grow, and that a reader which does not recognise a
//  value must treat the session as a room recording. This file is the
//  one place that answers both questions, so a new recorder is one
//  value here and nothing else anywhere.
//

import Foundation

public nonisolated enum SessionOrigin {
    /// Daisy for iPhone, recording with the phone's microphone.
    public nonisolated static let iphone = "iphone"
    /// Daisy for Apple Watch, recording on its own because the phone
    /// was out of reach (backlog 14 Н-2).
    public nonisolated static let watch = "watch"
    /// A file the user brought in (§7.5). Whatever recorded it is
    /// unknown, which is exactly why §2.1 must not be applied to it.
    public nonisolated static let importedFile = "import"

    /// True when the microphone track is the room, not the owner —
    /// i.e. when §2.1 does NOT apply and a diarizer must cluster the
    /// whole track (§3.6).
    ///
    /// An absent value means a Mac session, the only case where the
    /// microphone is the owner by definition. Any other value, known
    /// or not, is a room: an old reader meeting a future recorder must
    /// fail towards "we don't know who spoke", never towards stamping
    /// the owner's name on a stranger's words.
    public nonisolated static func isRoomMicrophone(_ origin: String?) -> Bool {
        guard let origin, !origin.isEmpty else { return false }
        return origin != "mac"
    }

    /// True when THIS family of devices made the recording itself, as
    /// opposed to reading a file someone brought in.
    ///
    /// Used for the audio that has to travel: a recording this device
    /// made is the only copy until the Mac takes it (Ф3-B), while an
    /// imported file still exists wherever the user imported it from,
    /// so nothing is lost by not shipping its audio anywhere. An
    /// unrecognised value answers `false` — a reader does not send
    /// gigabytes across the network on a guess.
    public nonisolated static func isOwnRecording(_ origin: String?) -> Bool {
        origin == iphone || origin == watch
    }
}
