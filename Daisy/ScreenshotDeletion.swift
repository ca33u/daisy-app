//
//  ScreenshotDeletion.swift
//  Daisy
//
//  Removing ONE frame from a session: the file, and every place its name
//  is written down.
//
//  A screenshot is not just a file in `screenshots/`. Its name is a key in
//  `index.json` (where the frame sits on the transcript's clock), possibly
//  a member of `highlights.json` (the frames OCR judged to be a new screen
//  — what the header stepper walks), possibly the illustration of a
//  `markers.json` moment, and — in every finalized recording, because the
//  post-stop pass re-renders `transcript.md` through `MarkdownExporter` —
//  a markdown image link in the transcript itself. Deleting the file alone
//  would leave a timecode for a picture nobody can open, a stepper stop
//  that shows nothing, and a broken image in the saved markdown.
//
//  So the unit of deletion is the FRAME, not the file, and this is the one
//  place that knows the whole list. Anything that learns to reference a
//  frame by name later belongs here too.
//
//  A marked moment is the one reference that is NOT removed with the
//  picture: a person pressed a key to say this minute mattered, and the
//  frame was only ever an illustration of that (see MomentMarkers). The
//  link goes; the moment stands.
//

import Foundation
import os

nonisolated enum ScreenshotDeletion {

    private static let log = Logger(
        subsystem: "app.essazanov.Daisy", category: "ScreenshotDeletion"
    )

    /// Delete `frame` and scrub its name out of the session's sidecars.
    /// Returns false only when the image itself could not be removed — in
    /// which case nothing else is touched, so the session is never left
    /// with a file that everything has stopped pointing at.
    @discardableResult
    static func delete(_ frame: URL, in sessionDirectory: URL) -> Bool {
        let fm = FileManager.default
        let name = frame.lastPathComponent
        do {
            try fm.removeItem(at: frame)
        } catch {
            // Already gone (deleted in Finder, folder synced away) is not
            // a failure: the references still have to follow it.
            guard !fm.fileExists(atPath: frame.path) else {
                log.error("Deleting \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }

        let screenshotsDirectory = frame.deletingLastPathComponent()
        pruneIndex(name, in: screenshotsDirectory)
        pruneHighlights(name, in: screenshotsDirectory)
        pruneMarkers(name, in: sessionDirectory)
        pruneTranscript(name, in: sessionDirectory)
        return true
    }

    // MARK: - Sidecars

    /// `screenshots/index.json` — filename → offset on the recording's
    /// clock. An entry for a frame that no longer exists would print a
    /// timecode in the strip for a thumbnail that can't load.
    private static func pruneIndex(_ name: String, in screenshotsDirectory: URL) {
        var offsets = ScreenshotIndex.load(from: screenshotsDirectory)
        guard offsets.removeValue(forKey: name) != nil else { return }
        if offsets.isEmpty {
            // An empty index is not the same as no index: `hasScreenTimeline`
            // reads it, and `{}` on disk is just a file to keep in sync.
            try? FileManager.default.removeItem(
                at: ScreenshotIndex.url(in: screenshotsDirectory)
            )
        } else {
            ScreenshotIndex.write(offsets, to: screenshotsDirectory)
        }
    }

    /// `screenshots/highlights.json` — the distinct screens the stepper
    /// walks.
    private static func pruneHighlights(_ name: String, in screenshotsDirectory: URL) {
        let highlights = ScreenshotIndex.loadHighlights(from: screenshotsDirectory)
        guard highlights.contains(name) else { return }
        let kept = highlights.filter { $0 != name }
        if kept.isEmpty {
            // `writeHighlights` REFUSES an empty list, so an emptied file
            // has to be removed rather than rewritten — otherwise deleting
            // the last highlight would leave the whole stale list behind.
            // The stepper then walks every remaining frame again
            // (`distinctScreenshots` falls back), which is the honest
            // answer: nothing is left that OCR called a distinct screen.
            try? FileManager.default.removeItem(
                at: ScreenshotIndex.highlightsURL(in: screenshotsDirectory)
            )
        } else {
            ScreenshotIndex.writeHighlights(kept, to: screenshotsDirectory)
        }
    }

    /// `markers.json` — keep the moment, drop the picture it pointed at.
    private static func pruneMarkers(_ name: String, in sessionDirectory: URL) {
        let markers = MomentMarkerStore.load(from: sessionDirectory)
        guard markers.contains(where: { $0.screenshot == name }) else { return }
        let updated = markers.map { marker in
            marker.screenshot == name
                ? MomentMarker(
                    offsetSec: marker.offsetSec,
                    screenshot: nil,
                    createdAt: marker.createdAt
                )
                : marker
        }
        MomentMarkerStore.write(updated, to: sessionDirectory)
    }

    /// `transcript.md` — the file that holds frame links on disk. Written
    /// two different ways, so the match has to cover both:
    ///
    ///   • ABSOLUTE, from `MarkdownExporter.renderMarkdown`, which is what
    ///     the post-stop pass re-renders every finalized recording into —
    ///     `![0:15](/Users/…/screenshots/001.jpg)`.
    ///   • RELATIVE, from a screenshot note (`ScreenshotNoteCapture
    ///     .renderNote`) and from `MomentMarkerStore.markdownSection` in a
    ///     crash-recovered transcript — `![0:12](screenshots/003.jpg)`.
    ///
    /// Hence the needle is the tail `screenshots/<name>)` rather than a
    /// leading `](`: the absolute form is the COMMON case, and matching only
    /// the relative one would leave every ordinary meeting with a broken
    /// image where the frame used to be.
    ///
    /// Two shapes on the line, and they are not deleted the same way:
    ///
    ///   • The image alone on its line (the gallery, a note's body) — the
    ///     line is the picture and goes with it.
    ///   • `- **[0:12]** — ![0:12](…)` — a marked moment. Dropping the line
    ///     would delete a moment the user marked by hand, so only the image
    ///     is cut and the timecode stays, which is exactly what
    ///     `MomentMarkerStore.markdownSection` writes for a frameless marker.
    private static func pruneTranscript(_ name: String, in sessionDirectory: URL) {
        let url = sessionDirectory.appendingPathComponent("transcript.md")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            // An unreadable transcript (iCloud-evicted, permissions) would
            // otherwise keep a link to a picture that no longer exists with
            // nothing said about it. Say it.
            log.error("Frame \(name, privacy: .public) removed but transcript.md was unreadable — its link stays")
            return
        }
        let needle = "screenshots/" + name + ")"
        guard text.contains(needle) else { return }

        var kept: [String] = []
        for line in text.components(separatedBy: "\n") {
            guard line.contains("![") && line.contains(needle) else {
                kept.append(line)
                continue
            }
            if line.hasPrefix("- **["), let image = line.range(of: " — ![") {
                kept.append(String(line[line.startIndex..<image.lowerBound]))
            }
            // Anything else: the image had the line to itself and leaves
            // with it.
        }
        do {
            try Data(kept.joined(separator: "\n").utf8).write(to: url, options: .atomic)
        } catch {
            log.error("Rewriting transcript.md without \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
