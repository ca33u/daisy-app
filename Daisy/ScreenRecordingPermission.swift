//
//  ScreenRecordingPermission.swift
//  Daisy
//
//  Thin wrapper around macOS Screen Recording (TCC) permission for
//  ScreenCaptureKit. Daisy needs this granted to capture the "other
//  side" of meetings — the system audio stream coming out of Zoom /
//  Meet / Teams. Without it, SCStream.startCapture() throws and the
//  user silently gets a mic-only recording.
//
//  CGPreflightScreenCaptureAccess() does NOT trigger a system prompt
//  — that only fires on the first SCStream.startCapture() call. We
//  call it BEFORE starting capture so we can show a clear toast +
//  Settings deeplink instead of letting the user start a 60-minute
//  meeting that quietly records only their voice.
//

import Foundation
import CoreGraphics
import AppKit

@MainActor
enum ScreenRecordingPermission {
    /// True if Screen Recording access has already been granted via
    /// the TCC database. No system prompt is shown — this is a pure
    /// inspection call.
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Open System Settings → Privacy & Security → Screen Recording.
    /// The URL is documented as the canonical anchor; on macOS 14+
    /// it lands on the exact pane, on older versions it falls back
    /// to the general Privacy & Security tab.
    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Diagnostics

    // A revoked Screen Recording grant is invisible after the fact. The
    // macOS 27.0 beta (26A5406e) reset Daisy's TCC entry without a
    // re-prompt, and two meetings recorded mic-only before anyone
    // noticed; the log report of the day showed `screenRec=denied` and
    // nothing else — indistinguishable from a user who never granted it
    // and from one who turned it off on purpose. What was missing was
    // HISTORY: we had seen it granted before, and we degraded specific
    // sessions because of it.
    //
    // So two facts are persisted, both tiny and both derived from things
    // we already knew at the time:
    //   • the last moment the capture path observed the grant, which
    //     turns "denied" into "denied, and it was granted until Tuesday"
    //     — the signature of a reset;
    //   • how many sessions degraded to mic-only, and why the last one
    //     did, which is the user-visible damage the reset caused.
    //
    // UserDefaults rather than an os_log line on purpose: `log show
    // --last 24h` cannot reach back to the grant that was true last
    // week, and that is exactly the span this question needs.

    private static let lastGrantedKey = "daisy.screenRecording.lastGrantedAt"
    private static let lastMicOnlyKey = "daisy.screenRecording.lastMicOnlyAt"
    private static let lastMicOnlyCauseKey = "daisy.screenRecording.lastMicOnlyCause"
    private static let micOnlyCountKey = "daisy.screenRecording.micOnlyCount"

    /// The verdict the capture path acts on, plus a note of when we last
    /// saw the grant in place. Same answer as `isGranted` — call this one
    /// from anywhere that is ABOUT to record, and `isGranted` from
    /// anywhere merely rendering permission state (a settings row that
    /// re-evaluates on every layout pass must not keep re-stamping the
    /// timestamp; the stamp is meant to mark real capture attempts).
    static func preflight() -> Bool {
        let granted = isGranted
        if granted {
            UserDefaults.standard.set(
                Date().timeIntervalSinceReferenceDate,
                forKey: lastGrantedKey
            )
        }
        return granted
    }

    /// Record that a meeting fell back to microphone-only. Counts are
    /// cumulative and never reset — the number is only ever read by the
    /// log report, where "3 sessions, last one yesterday" is the whole
    /// point.
    static func noteMicOnlySession(cause: MicOnlyCause) {
        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSinceReferenceDate, forKey: lastMicOnlyKey)
        defaults.set(cause.rawValue, forKey: lastMicOnlyCauseKey)
        defaults.set(defaults.integer(forKey: micOnlyCountKey) + 1, forKey: micOnlyCountKey)
    }

    /// One line for the log-report header, as space-separated
    /// `key=value` tokens.
    ///
    /// Ages, not dates, and three reasons for it. A formatted date is
    /// LOCALIZED — on a Russian interface it comes out as
    /// `21 авг. 2026 г., 14:30`, which defeats the point of a line meant
    /// to be grepped in a maintainer's inbox. It also contains spaces
    /// and a comma, which would break the `key=value` shape. And the
    /// report header promises "no transcript content, no titles": an
    /// absolute timestamp of the user's last meeting is activity
    /// metadata that promise did not previously carry, while "granted
    /// 6 d ago" answers the actual diagnostic question — was the grant
    /// there recently, and did it disappear since?
    static func diagnosticsLine() -> String {
        let defaults = UserDefaults.standard
        let granted = isGranted
        var parts: [String] = [granted ? "granted" : "denied"]

        switch (granted, age(since: lastGrantedKey)) {
        case (true, let seen?):
            parts.append("lastSeenGranted=\(seen)")
        case (true, nil):
            // Granted, but no meeting has run through the preflight yet.
            parts.append("lastSeenGranted=noCaptureYet")
        case (false, let seen?):
            // The signature of a TCC reset: we watched a capture start
            // with this grant in place, and now it isn't. A manual
            // revoke looks the same, which is fine — both are answers.
            parts.append("lastSeenGranted=\(seen)-WAS-GRANTED")
        case (false, nil):
            parts.append("lastSeenGranted=never")
        }

        let degraded = defaults.integer(forKey: micOnlyCountKey)
        if degraded > 0, let at = age(since: lastMicOnlyKey) {
            let cause = defaults.string(forKey: lastMicOnlyCauseKey) ?? "unknown"
            parts.append("micOnlySessions=\(degraded) lastMicOnly=\(at) cause=\(cause)")
        } else {
            parts.append("micOnlySessions=0")
        }
        return parts.joined(separator: " ")
    }

    /// How long ago the timestamp at `key` was written, as a compact
    /// ASCII token (`3m`, `5h`, `12d`). Nil when nothing was ever
    /// written: an absent key reads back as 0.0, which is a real date
    /// (2001-01-01), so the epoch must be rejected rather than reported
    /// as a 25-year-old grant.
    private static func age(since key: String) -> String? {
        let raw = UserDefaults.standard.double(forKey: key)
        guard raw > 0 else { return nil }
        let seconds = Date().timeIntervalSinceReferenceDate - raw
        // A clock change (or a defaults file copied from another Mac)
        // can put the stamp in the future. Report it rather than
        // rendering a negative age.
        guard seconds >= 0 else { return "future" }
        switch seconds {
        case ..<3600:    return "\(Int(seconds / 60))m"
        case ..<86_400:  return "\(Int(seconds / 3600))h"
        default:         return "\(Int(seconds / 86_400))d"
        }
    }
}
