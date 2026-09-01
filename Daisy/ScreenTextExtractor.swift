//
//  ScreenTextExtractor.swift
//  Daisy
//
//  On-device OCR over the screenshots captured during a recording, run
//  once at finalize time. Turns "what was shared on screen" — slides,
//  dashboards, docs — into searchable text folded into the transcript
//  and handed to the summarizer, so a metric on a slide or a date in a
//  doc becomes part of the record even if nobody read it aloud.
//
//  100% local: Apple's Vision framework, no network. The heavy pass must
//  run in a `Task.detached` — see the isolation note below the imports.
//
//  Deduplication is the whole trick: periodic capture produces many
//  near-identical frames of the same slide. We keep only frames whose
//  text meaningfully differs from the last kept one, so a slide shown
//  for ten minutes contributes one block, not sixty.
//

import Foundation
import Vision
import CoreGraphics
import ImageIO
import os

// Isolation: `nonisolated` AND synchronous, and the caller must reach it through
// `Task.detached` — that combination is what actually gets this off the
// main actor, and only that.
//
// It used to be `nonisolated static func … async`, with a comment
// claiming the Vision pass therefore ran in the background. It did not.
// The project builds with SWIFT_APPROACHABLE_CONCURRENCY = YES, under
// which a `nonisolated async` function runs on the CALLER's executor —
// and the caller here is `finalizePostStop`, a @MainActor method. So
// every frame's `VNImageRequestHandler.perform` ran on the main thread:
// 200–600 ms per retina frame, 120 frames for a 30-minute meeting,
// which is the half-minute-to-a-minute of frozen UI right after Stop
// that field reports called "долгая пост-обработка" (audit 2026-09-01).
// Synchronous now, so there is no async hop to be misread — the
// isolation is decided entirely by whoever calls it.
nonisolated enum ScreenTextExtractor {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "ScreenOCR")

    struct Result: Sendable {
        /// Markdown block ready to append under a "## Shared on screen"
        /// heading. Empty when nothing legible was captured.
        let markdown: String
        /// How many distinct screens survived dedup.
        let distinctScreens: Int
        /// Filenames of the frames that survived, in capture order.
        ///
        /// The dedup pass already knows which frame each kept block came
        /// from; it used to throw that away and report only a count. It
        /// is the most valuable thing this pass produces for navigation:
        /// an hour of capture is ~60 near-identical frames, of which
        /// maybe eight are actually a NEW screen. Stepping through eight
        /// is browsing; stepping through sixty is a slideshow.
        let distinctFrames: [String]
    }

    /// Minimum word-like characters for a frame to count as "has content"
    /// — filters idle desktop / menu-bar-only frames.
    private static let minContentChars = 16
    /// Jaccard similarity (word-set overlap) above which two consecutive
    /// frames are treated as the same screen.
    private static let dedupThreshold = 0.80
    /// Bounds so a pathological capture can't bloat the transcript.
    private static let maxCharsPerScreen = 900
    private static let maxTotalChars = 5_000
    private static let maxFrames = 400

    /// OCR every frame in `directory` (in capture order),
    /// dedup consecutive identical screens, and return a consolidated
    /// markdown block. Best-effort: unreadable frames are skipped, and a
    /// missing/empty directory yields an empty result.
    ///
    /// Long and CPU-bound — call it from `Task.detached`, never inline
    /// from an actor-isolated context (see the note at the top).
    static func extract(from directory: URL) -> Result {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return Result(markdown: "", distinctScreens: 0, distinctFrames: [])
        }
        let frames = ScreenshotFile.ordered(entries).prefix(maxFrames)
        guard !frames.isEmpty else { return Result(markdown: "", distinctScreens: 0, distinctFrames: []) }

        var kept: [String] = []
        /// Filename behind each entry of `kept`, index-for-index.
        var keptFrames: [String] = []
        var lastTokens: Set<String> = []

        for url in frames {
            // One autorelease pool PER FRAME, and it is load-bearing.
            //
            // A frame decodes to width × height × 4 bytes NO MATTER how
            // small the file on disk is — ~6 MB on a laptop display, ~33 MB
            // on a 4K monitor at 1×; the switch to JPEG shrank the folder,
            // not this. Both the decoded `CGImage` and Vision's buffers are
            // autoreleased. Without a pool inside the loop they accumulate
            // for the WHOLE run: 15-second capture over a 30-minute
            // meeting is 120 frames, so the peak was hundreds of megabytes
            // to several gigabytes rather than one frame's worth.
            //
            // That peak is not merely wasteful, it broke summarizing.
            // LM Studio's MLX AutoFit picks a model's context length from
            // the memory FREE WHEN THE MODEL LOADS — and the model loads
            // immediately after this pass, in the same post-stop pipeline.
            // Holding gigabytes here made AutoFit choose a small window,
            // the prompt didn't fit, and the summary came back unusable.
            // Which is exactly the shape of the report: failing on every
            // meeting WITH screen capture, including 20-minute ones, and
            // fine on hour-long meetings WITHOUT it (Ken, 2026-07-30).
            //
            // Only the recognised text escapes the pool.
            let normalized: String? = autoreleasepool {
                guard let cg = loadCGImage(url) else { return nil }
                let text = recognizeText(in: cg)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return contentCharCount(text) >= minContentChars ? text : nil
            }
            guard let normalized else { continue }

            let tokens = tokenSet(normalized)
            if !lastTokens.isEmpty, jaccard(tokens, lastTokens) >= dedupThreshold {
                // Same slide as the previous kept frame — skip. Keep the
                // longer of the two (a slide often reveals more text as it
                // animates in) so the retained block is the fullest one.
                if normalized.count > (kept.last?.count ?? 0) {
                    kept[kept.count - 1] = String(normalized.prefix(maxCharsPerScreen))
                    // The fuller frame replaces the earlier one as this
                    // screen's representative — otherwise navigation lands
                    // on the half-animated version of the slide.
                    keptFrames[keptFrames.count - 1] = url.lastPathComponent
                }
                continue
            }

            kept.append(String(normalized.prefix(maxCharsPerScreen)))
            keptFrames.append(url.lastPathComponent)
            lastTokens = tokens

            if kept.reduce(0, { $0 + $1.count }) > maxTotalChars { break }
        }

        guard !kept.isEmpty else { return Result(markdown: "", distinctScreens: 0, distinctFrames: []) }

        var md = ""
        for (i, block) in kept.enumerated() {
            md += "**Screen \(i + 1)**\n\n"
            md += block
            md += "\n\n"
        }
        log.info("Screen OCR: \(frames.count, privacy: .public) frames → \(kept.count, privacy: .public) distinct screens")
        return Result(
            markdown: md.trimmingCharacters(in: .whitespacesAndNewlines),
            distinctScreens: kept.count,
            distinctFrames: keptFrames
        )
    }

    // MARK: - Vision

    private static func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Synchronous Vision text recognition. Runs on the caller's (non-main)
    /// executor — finalize is already a detached task.
    private static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Multilingual (incl. Russian) without hardcoding a language list
        // — Vision picks per frame. Available macOS 13+.
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            log.error("Vision perform failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
        // `request.results` is already typed `[VNRecognizedTextObservation]?`
        // on current SDKs — the old `as? [VNRecognizedTextObservation]`
        // downcast was a no-op (compiler warning). Nil-coalesce instead.
        let observations = request.results ?? []
        // Preserve reading order top-to-bottom: observations come sorted
        // by confidence, so re-sort by vertical position (Vision's origin
        // is bottom-left, so higher y = higher on screen).
        let lines = observations
            .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    // MARK: - Dedup helpers (pure)

    private static func contentCharCount(_ s: String) -> Int {
        s.reduce(0) { $1.isLetter || $1.isNumber ? $0 + 1 : $0 }
    }

    private static func tokenSet(_ s: String) -> Set<String> {
        Set(
            s.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 3 }
        )
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        let inter = a.intersection(b).count
        let union = a.union(b).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }
}
