//
//  MomentMarkers.swift
//  DaisyCore
//
//  Copied from daisy-app/Daisy/MomentMarkers.swift (macOS Daisy 1.0.7.72,
//  2026-09-19). Kept byte-for-byte where possible; changes are limited to
//  `public` access and the removal of Mac-only references, each marked
//  with `// DaisyLite:`. The Mac copy is the reference — fix there first.
//
//
//  "This bit matters" — one keypress during a recording.
//
//  WHY THIS EXISTS AND WHY IT IS NOT A SCREENSHOT FEATURE. Daisy already
//  photographs the screen every 15 seconds and OCRs it, so during a
//  meeting one more picture is worth very little. What we have never had
//  is the user's own judgement, live: which of those sixty minutes they
//  would want back. Everything else Daisy knows about importance is
//  inferred from the transcript after the fact. A marker is stated, at
//  the moment, by the person who was there — the highest-quality signal
//  in the session, and it costs them one key.
//
//  So the marker is the feature and the frame is evidence. A marker with
//  no frame (screen capture off, Screen Recording not granted, capture
//  failed) is still worth recording: the timestamp is the point.
//
//  Stored at SESSION level, not inside `screenshots/`, for exactly that
//  reason — markers outlive the folder they'd otherwise depend on, and a
//  session with screen capture switched off must still be able to hold
//  them.
//
//  The clock is the recording's own media time — `RecordingSession
//  .elapsed`, what the transcript's `[mm:ss]` markers and the screenshot
//  index already use. A `Date` delta would drift past every pause by
//  exactly the paused duration. See the ScreenshotCapture header.
//

import Foundation

/// One user-marked moment.
public struct MomentMarker: Codable, Sendable, Hashable, Identifiable {
    /// Media time of the recording when the user pressed the key.
    public let offsetSec: Double
    /// Frame captured for this marker, filename only, relative to the
    /// session's `screenshots/` folder. `nil` when no frame could be
    /// taken — the marker still stands.
    public let screenshot: String?
    /// Wall clock, for a future "marked at 14:32" affordance and for
    /// ordering markers made during a pause, when `offsetSec` is frozen.
    public let createdAt: Date

    // DaisyLite: memberwise init made public.
    public init(offsetSec: Double, screenshot: String?, createdAt: Date) {
        self.offsetSec = offsetSec
        self.screenshot = screenshot
        self.createdAt = createdAt
    }

    /// Keyed on the wall clock, not the offset: `elapsed` freezes while
    /// paused and is quantised to the recorder's half-second tick, so two
    /// presses can share an `offsetSec` — and a `ForEach` over colliding
    /// ids drops rows.
    public var id: Date { createdAt }

    /// `mm:ss` / `h:mm:ss`, same shape as `ScreenshotIndex.timecode`.
    /// `nonisolated`: pure arithmetic on a value, read from the
    /// nonisolated `markdownSection` and the recovery renderers.
    public nonisolated var timecode: String {
        let total = Int(offsetSec.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// `markers.json` in the session folder. Written on every mark rather
/// than at finalize: the whole point is a signal captured mid-session,
/// and a crash forty minutes in must not take the four moments the user
/// flagged along with it.
public nonisolated enum MomentMarkerStore {
    public static let filename = "markers.json"

    public static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(filename)
    }

    public static func load(from directory: URL) -> [MomentMarker] {
        guard let data = try? Data(contentsOf: url(in: directory)),
              let decoded = try? JSONDecoder().decode([MomentMarker].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.offsetSec < $1.offsetSec }
    }

    public static func write(_ markers: [MomentMarker], to directory: URL) {
        guard let data = try? JSONEncoder().encode(markers.sorted { $0.offsetSec < $1.offsetSec }) else { return }
        try? data.write(to: url(in: directory), options: .atomic)
    }

    /// The `## Marked moments` section for a session folder, or `""`
    /// when it has none. Used by the crash-recovery renderers, which
    /// rebuild `transcript.md` from the audio and would otherwise drop
    /// the markers — which is precisely the case the per-mark write
    /// exists to survive.
    ///
    /// Frame links are relative (`screenshots/003.jpg`), unlike the
    /// live exporter's absolute paths: a recovered file is written
    /// INSIDE the session folder, and a relative link there survives the
    /// folder being moved.
    public static func markdownSection(for directory: URL, heading: String) -> String {
        let markers = load(from: directory)
        guard !markers.isEmpty else { return "" }
        var lines = ["## \(heading)", ""]
        for marker in markers {
            if let frame = marker.screenshot {
                lines.append("- **[\(marker.timecode)]** — ![\(marker.timecode)](screenshots/\(frame))")
            } else {
                lines.append("- **[\(marker.timecode)]**")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
