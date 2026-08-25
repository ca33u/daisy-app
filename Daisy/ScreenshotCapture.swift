//
//  ScreenshotCapture.swift
//  Daisy
//
//  Periodic screen capture via SCScreenshotManager. Writes frames into
//  the session folder so the markdown export can reference them inline.
//
//  2026-07-30: JPEG instead of a lossless PNG per frame. A screen
//  captured every 15 seconds for an hour is 240 frames, and at 1–6 MB
//  each that is hundreds of megabytes to a gigabyte per meeting sitting
//  in the session folder forever — for pictures whose job is to be
//  glanced at and OCR'd. Resolution is deliberately UNCHANGED; see
//  `ScreenshotFile`. Frames written before this are PNG and stay
//  readable; nothing is re-encoded or deleted.
//
//  Alongside the frames it writes `index.json` — filename → position on
//  the recording's timeline. The filenames alone (`001.jpg`, `002.jpg`)
//  carry only ORDER, and order times nothing: multiplying by the capture
//  interval breaks the moment a session is paused (capture stops, the
//  wall clock doesn't), and breaks again for anyone who changed the
//  interval since.
//
//  The offset is AUDIO CAPTURED, not wall-clock elapsed, because that is
//  what the transcript measures. A `[mm:ss]` marker there comes from
//  `TranscriptSegment.startedAt`, which the transcribers build as
//  `sessionStart + samplesSeen / sampleRate` — a pause synthesises no
//  samples, so media time freezes while `Date()` keeps running. Stamping
//  screenshots with a `Date` delta would leave every frame after a pause
//  later than the line spoken beside it, by exactly the paused duration.
//  `RecordingSession.elapsed` is the same clock, so the two agree.
//

import Foundation
import ScreenCaptureKit
import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers
import os

@Observable
@MainActor
final class ScreenshotCapture {
    private(set) var isRunning = false
    private(set) var screenshotURLs: [URL] = []
    private(set) var lastError: String?

    private var timer: Timer?
    private var outputDir: URL?
    private var index = 0
    /// Reads the recording's own clock — active recording time, pauses
    /// excluded. Supplied by `RecordingSession` rather than measured
    /// here, because the only clock worth stamping with is the one the
    /// transcript uses.
    private var elapsedProvider: (@MainActor () -> TimeInterval)?
    /// filename → position on the recording's timeline, in seconds.
    /// Rewritten whole on each capture: it is a few dozen entries, and a
    /// full atomic write costs nothing next to a screen grab while
    /// surviving a crash with at most the last frame missing.
    private var offsets: [String: Double] = [:]
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Screenshots")

    /// Display captured on the previous tick — only used to log
    /// display switches once instead of every 60 s.
    private var lastPickedDisplayID: CGDirectDisplayID?

    /// Begin periodic capture every `intervalSec` seconds. Writes files
    /// numbered `001.jpg`, `002.jpg`, … into the given directory.
    /// - Parameter elapsed: media time of the recording, in seconds.
    ///   Pass `RecordingSession.elapsed`; see the file header for why a
    ///   `Date` delta is the wrong clock. Note this is the MIC
    ///   recorder's measure, so a session whose microphone never
    ///   delivered frames stamps zeros — deliberately. That session's
    ///   transcript has no `[mm:ss]` progression either, so a wall-clock
    ///   fallback wouldn't be a second-best clock, it would be timecodes
    ///   aligned to nothing, stated with full confidence. Zeros are
    ///   visibly broken; plausible numbers are not.
    func start(
        intervalSec: Int,
        elapsed: @escaping @MainActor () -> TimeInterval,
        into directory: URL
    ) async {
        guard intervalSec > 0 else { return }
        outputDir = directory
        elapsedProvider = elapsed
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            lastError = error.localizedDescription
            return
        }

        // Resume-safe: pause→resume calls start() again on the SAME
        // directory. Continue numbering after any existing NNN.<ext>
        // instead of resetting to 0 and overwriting the earlier
        // screenshots (which broke the OCR chronology). A fresh session's
        // dir is empty → 0. A session that started before this app version
        // holds PNGs and resumes into JPEGs; `ordered` counts both and
        // sorts on the number, so a mixed folder needs no special case.
        let existing = ScreenshotFile.ordered((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? [])
        screenshotURLs = existing
        // Next filename = (highest existing number) + 1.
        index = existing.compactMap(ScreenshotFile.number(of:)).max() ?? 0
        // Resume path: keep the offsets already on disk. Recomputing
        // them now would date every pre-pause frame to the resume.
        offsets = ScreenshotIndex.load(from: directory)

        // Take one right away, then schedule.
        await captureOne()

        timer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(intervalSec),
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.captureOne()
            }
        }
        isRunning = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        // Forget the folder too. `captureForMarker` bootstraps itself
        // from `outputDir == nil`, and a directory left over from the
        // last session would send the next session's marker frame into
        // the previous session's folder — with `markers.json` in the new
        // one pointing at a file that isn't there.
        outputDir = nil
        elapsedProvider = nil
    }

    /// Capture ONE frame right now, outside the periodic schedule, and
    /// return its filename — for a moment marker (see `MomentMarkers`).
    ///
    /// Works whether or not the periodic timer is running: when it
    /// isn't, `directory` and `elapsed` bootstrap the same state `start`
    /// would have set, minus the timer — which covers the window between
    /// a session starting and its first tick, and a resumed session.
    /// `nil` means no frame, which the marker survives.
    ///
    /// The CALLER decides whether a frame may be taken at all. This does
    /// not consult `screenshotsEnabled`: with capture switched off, one
    /// keypress must not photograph someone's screen (or raise the
    /// Screen Recording prompt) for a feature they never turned on.
    func captureForMarker(
        elapsed: @escaping @MainActor () -> TimeInterval,
        into directory: URL
    ) async -> String? {
        if outputDir != directory {
            outputDir = directory
            elapsedProvider = elapsed
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
            } catch {
                lastError = error.localizedDescription
                return nil
            }
            // Same resume-safe numbering as `start`: this folder may
            // already hold frames from before periodic capture was
            // switched off mid-session.
            let existing = ScreenshotFile.ordered((try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? [])
            screenshotURLs = existing
            index = existing.compactMap(ScreenshotFile.number(of:)).max() ?? 0
            offsets = ScreenshotIndex.load(from: directory)
        }
        // The filename comes back from the capture itself, not from
        // `screenshotURLs.last`: the periodic timer can land a frame
        // during our await, and pointing a marker at someone else's
        // frame — up to a full interval away from the marked instant —
        // is worse than a marker with no picture.
        return await captureOne()
    }

    /// Display to capture this tick. Prefers the display hosting the
    /// meeting app's window (issue #6 — the call is often on a
    /// secondary monitor, and `displays.first` isn't even guaranteed
    /// to be the main display); falls back to the main display, then
    /// to the first. Because `captureOne` re-enumerates
    /// `SCShareableContent` on every tick, dragging the meeting window
    /// to another monitor is picked up automatically on the next shot
    /// — no move-observer needed.
    ///
    /// Browser-tab meetings (Meet in Chrome/Safari) can't be matched —
    /// the owning app is just the browser — so they use the fallback,
    /// same as today's behaviour.
    private func pickDisplay(from content: SCShareableContent) -> SCDisplay? {
        // 1. Biggest on-screen window owned by a known meeting app.
        //    Size gate skips join-panels, HUDs and toolbars; the main
        //    call window (the one rendering shared content) is large.
        // Hoisted: this decodes the user's additions from UserDefaults,
        // and there can be hundreds of windows. `allKnown…`, not
        // `meetingBundleIDs()`: switching an app off in Settings means
        // "don't ask me to record when it launches", not "this app no
        // longer hosts calls" — a recording the user started by hand
        // still belongs on the monitor showing the call window.
        let meetingApps = MeetingDetector.allKnownMeetingBundleIDs()
        let meetingWindows = content.windows.filter { w in
            guard let bid = w.owningApplication?.bundleIdentifier else { return false }
            return meetingApps.contains(bid)
                && w.isOnScreen
                && w.frame.width >= 300 && w.frame.height >= 200
        }
        if let win = meetingWindows.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) {
            // SCWindow.frame and SCDisplay.frame share the same global
            // display-space coordinates — a plain contains() works.
            let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
            if let hit = content.displays.first(where: { $0.frame.contains(center) }) {
                if hit.displayID != lastPickedDisplayID {
                    lastPickedDisplayID = hit.displayID
                    let owner = win.owningApplication?.bundleIdentifier ?? "?"
                    log.info("Screenshot display → \(hit.displayID, privacy: .public) (meeting window: \(owner, privacy: .public))")
                }
                return hit
            }
        }

        // 2. No meeting window found — main display, then first.
        let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
        let fallback = mainDisplay ?? content.displays.first
        if let picked = fallback, picked.displayID != lastPickedDisplayID {
            lastPickedDisplayID = picked.displayID
            let label = mainDisplay != nil ? "main display" : "first display"
            log.info("Screenshot display → \(picked.displayID, privacy: .public) (fallback: \(label, privacy: .public))")
        }
        return fallback
    }

    /// Returns the filename written, or `nil` when nothing was — the
    /// marker path needs to know whether ITS capture produced a frame,
    /// and `index` alone can't answer that: the periodic timer (or a
    /// second hotkey press) can complete during our await and move it.
    @discardableResult
    private func captureOne() async -> String? {
        guard let dir = outputDir else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            guard let display = pickDisplay(from: content) else { return nil }

            // Exclude our own popover from the shot.
            let ourApps = content.applications.filter {
                Bundle.main.bundleIdentifier == $0.bundleIdentifier
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ourApps,
                exceptingWindows: []
            )

            let config = SCStreamConfiguration()
            // Point dimensions, i.e. a 1× capture — see `ScreenshotFile`
            // for why this is NOT the place to save bytes.
            config.width = display.width
            config.height = display.height
            config.showsCursor = false
            config.capturesAudio = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            guard let encoded = ScreenshotFile.encode(cgImage) else {
                lastError = "Could not encode screenshot."
                return nil
            }

            let filename = ScreenshotFile.name(number: index + 1)
            let url = dir.appendingPathComponent(filename)
            // Atomic: the strip in the detail view lists this folder while
            // recording is still going, and a half-written frame is a
            // broken image in the UI rather than a frame that shows up a
            // second later.
            try encoded.write(to: url, options: .atomic)

            // Past the `try` above, so the file is on disk before it
            // gets an index entry — no orphan pointing at nothing.
            if let elapsedProvider {
                offsets[filename] = max(0, elapsedProvider())
                ScreenshotIndex.write(offsets, to: dir)
            }

            screenshotURLs.append(url)
            index += 1
            return filename
        } catch {
            log.error("Screenshot failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            return nil
        }
    }
}

// MARK: - Frame file format

/// How a captured frame is encoded, named and ordered — one place,
/// because four files have to agree on it (capture, OCR, the Library's
/// folder scan, and the markdown export's links).
///
/// JPEG, not PNG (2026-07-30, Egor): a screen stored losslessly is 1–6 MB
/// depending on the display, and capture every 15 s means 240 of them an
/// hour. At this quality the same frame is a few hundred KB — a 4–6× cut
/// on a file whose whole purpose is being glanced at and read by OCR.
/// JPEG rather than HEIC despite HEIC being better at both: these files
/// get dragged into Obsidian vaults, pasted into Notion and mailed
/// around, and HEIC still renders as a broken image in half of that.
///
/// Quality is set high for a lossy format because the primary reader is
/// not a person, it is Vision: JPEG ringing lands on glyph edges, which
/// is the one thing OCR cannot spare. 0.9 rather than the usual 0.8 buys
/// that back for roughly a third more bytes, and the bytes were never
/// the scarce thing here — a gigabyte of PNG was.
///
/// RESOLUTION IS NOT A KNOB HERE, and the reason is easy to lose.
/// `SCDisplay.width` is in POINTS while `SCStreamConfiguration.width` is
/// in PIXELS, so the capture has always been 1× — half-linear on any
/// Retina panel. That is already the floor for OCR: Vision needs text
/// tall enough in pixels, and 1× system text is ~13 px of cap height.
/// Capping the long side would therefore change nothing for the displays
/// that actually cost disk (a Retina laptop reports ~1500 pt, a 4K
/// monitor in HiDPI ~1920 pt) and would cut into legibility on exactly
/// the ones it did touch — a 5120×1440 ultrawide driven at 1× would land
/// at 2560×720, halving text height on a frame that was already 1×.
/// Compression is the free axis; resolution is not. If frames ever need
/// to get cheaper again, the next lever is writing FEWER of them (a
/// perceptual hash against the previous frame at capture time — an idle
/// screen is most of a long meeting), not smaller ones.
nonisolated enum ScreenshotFile {
    static let jpegQuality: CGFloat = 0.9

    /// Extension written for new frames.
    static let writtenExtension = "jpg"
    /// Extensions recognised when READING a session folder: `png` is
    /// every frame captured before 2026-07-30. Old sessions are neither
    /// re-encoded nor hidden.
    static let readableExtensions: Set<String> = ["jpg", "jpeg", "png"]

    /// A frame is a readable image type whose name is JUST its number.
    /// The number requirement is not pedantry: `screenshots/` travels —
    /// into Obsidian vaults, onto network shares — and comes back with
    /// `001 copy.jpg` and `._001.jpg` in it. Those sort unpredictably,
    /// have no entry in `index.json`, and in the AppleDouble case aren't
    /// decodable at all, so they have no business being frames.
    static func isFrame(_ url: URL) -> Bool {
        readableExtensions.contains(url.pathExtension.lowercased())
            && number(of: url) != nil
    }

    /// `001.jpg`, zero-padded — but see `ordered(_:)`: padding is for
    /// human eyes, ordering does not depend on it.
    static func name(number: Int) -> String {
        String(format: "%03d", number) + "." + writtenExtension
    }

    static func number(of url: URL) -> Int? {
        Int(url.deletingPathExtension().lastPathComponent)
    }

    /// The frames of a session folder, in CAPTURE order. Sorted by number
    /// rather than by name, which matters twice: `%03d` stops padding at
    /// the 1000th frame, and `"1000.jpg" < "999.jpg"` lexically — so a
    /// 4-hour session used to put its tail at the head, which silently
    /// mis-paired every frame with a timecode and made the OCR pass dedup
    /// non-adjacent frames. It also makes order independent of the file
    /// format, so a session that started as PNG and resumed as JPEG needs
    /// no special case.
    static func ordered(_ urls: [URL]) -> [URL] {
        urls.compactMap { url -> (number: Int, url: URL)? in
            guard isFrame(url), let number = number(of: url) else { return nil }
            return (number, url)
        }
        .sorted { $0.number < $1.number }
        .map { $0.url }
    }

    /// Encode via ImageIO rather than `NSBitmapImageRep`: a captured frame
    /// is BGRA with an ignored alpha channel, and the AppKit path has to be
    /// talked out of premultiplying it.
    static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let options: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: jpegQuality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

// MARK: - Timeline index

/// `screenshots/index.json` — filename → position on the recording's
/// timeline, in seconds of audio captured (the transcript's clock, not
/// the wall clock; see this file's header).
///
/// Deliberately a sidecar rather than a filename convention or EXIF: the
/// frames are an exported artifact people copy into Obsidian vaults and
/// mail to each other, and renaming them to carry a timestamp would break
/// every existing link. A sibling JSON file is ignorable by everything
/// that doesn't want it — including `ScreenTextExtractor` and
/// `SessionStore`, which both filter the folder through
/// `ScreenshotFile.isFrame`.
///
/// Sessions recorded before this existed have no index, and there is no
/// way to reconstruct one: the capture interval is a global setting that
/// may have changed since, and a paused session breaks the arithmetic
/// anyway. Those sessions show no timestamps, which is the honest
/// outcome — a plausible wrong time is worse than none.
nonisolated enum ScreenshotIndex {
    static let filename = "index.json"

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// `screenshots/highlights.json` — the frames OCR dedup judged to be
    /// a NEW screen rather than the same one again. Written once at
    /// finalize; absent when nothing legible was captured (a video call
    /// grid, a demo video), in which case callers walk every frame.
    static let highlightsFilename = "highlights.json"

    static func highlightsURL(in directory: URL) -> URL {
        directory.appendingPathComponent(highlightsFilename)
    }

    static func loadHighlights(from directory: URL) -> [String] {
        guard let data = try? Data(contentsOf: highlightsURL(in: directory)),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    static func writeHighlights(_ frames: [String], to directory: URL) {
        guard !frames.isEmpty, let data = try? JSONEncoder().encode(frames) else { return }
        try? data.write(to: highlightsURL(in: directory), options: .atomic)
    }

    static func load(from directory: URL) -> [String: Double] {
        guard let data = try? Data(contentsOf: url(in: directory)),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func write(_ offsets: [String: Double], to directory: URL) {
        guard let data = try? JSONEncoder().encode(offsets) else { return }
        try? data.write(to: url(in: directory), options: .atomic)
    }

    /// `12:04` for a screenshot URL — directly comparable to a
    /// `[mm:ss]` marker in the transcript. Nil when this session
    /// predates the index, or the frame somehow isn't in it.
    static func timecode(for screenshot: URL, offsets: [String: Double]) -> String? {
        guard let seconds = offsets[screenshot.lastPathComponent] else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
