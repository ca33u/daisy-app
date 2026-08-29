//
//  Transcriber.swift
//  Daisy
//
//  Whisper-backed live transcriber with chunked-streaming commit.
//
//  Pipeline:
//    1. Consume AudioChunk stream from the recorder.
//    2. Resample each chunk to 16 kHz mono Float32 (Whisper format).
//    3. Periodically re-transcribe the rolling tail window via the shared
//       WhisperEngine.
//    4. Promote segments that fall outside the live window's trailing
//       refine zone into the immutable `committedSegments` list — those
//       are frozen, the UI stops jittering on them.
//    5. On stop, run a final full-buffer pass that supersedes everything
//       (final segmentation is the most accurate Whisper can produce).
//
//  Everything runs on-device via WhisperKit CoreML.
//

import Foundation
import AVFoundation
import Observation
import os

/// Where the audio that produced a segment came from.
enum SegmentSource: String, Sendable, Codable, Equatable {
    case microphone
    case systemAudio

    var displayLabel: String {
        switch self {
        case .microphone: return "you"
        case .systemAudio: return "system"
        }
    }
}

/// One utterance in the live transcript.
struct TranscriptSegment: Identifiable, Sendable, Equatable {
    let id: UUID
    let startedAt: Date
    var text: String
    var isFinal: Bool
    var source: SegmentSource = .microphone
    /// Diarization label inside the same `source` stream — e.g. "A",
    /// "B", "C". `nil` while diarization is still running or if it
    /// failed. UI presents this as "Remote A" / "Remote B" for
    /// system-source segments and "Me" for microphone (we assume one
    /// speaker on the mic side).
    var speakerId: String? = nil
    /// Absolute end time in seconds since the session started. Used by the
    /// commit logic to decide when a pending segment is old enough to
    /// promote to committed. Not displayed.
    var endSec: Double = 0
    /// Absolute start time in seconds since the session started. Used
    /// by diarization merge to do IoU overlap with speaker spans.
    var startSec: Double = 0

    /// Human-facing speaker label combining the source stream with
    /// the diarized speaker id. Examples:
    ///   • mic, no diarization      → "Me"
    ///   • system, no diarization   → "Remote"
    ///   • system, speaker "A"      → "Remote A"
    ///   • system, low IoU (nil)    → "Remote ?"
    var speakerLabel: String { speakerLabel(displayName: nil) }

    /// Speaker label with an optional override for the user's own
    /// voice. Pass the configured `AppSettings.userDisplayName` to
    /// substitute `"Me"` with the real name (e.g. `[Egor]` instead
    /// of `[Me]`); pass nil/empty to keep the legacy generic label.
    /// System-source labels are unaffected — that's the remote
    /// party's voice, not the user's.
    func speakerLabel(displayName: String?) -> String {
        switch source {
        case .microphone:
            // Display name wins for the mic stream — always.
            //
            // Pre-1.0.6.2: when mic-side diarization assigned a
            // cluster id (e.g. Pyannote tags a solo recording's
            // segments as "A"), the label became "Speaker A" and
            // display-name override was silently skipped. Users who
            // set their name in Settings → General → You saw
            // "Speaker A" in transcripts instead of their actual
            // name — surfaced by tester report 2026-05-22.
            //
            // Mic stream = the user's microphone. Even when Pyannote
            // segments it into multiple clusters (rare — would need
            // multiple people sharing one mic in the same room),
            // display name is still the right "this is you" label
            // for the majority case. The Detail-view speaker-map UI
            // still exists for users who want per-cluster
            // disambiguation on the rare multi-speaker mic stream.
            let trimmed = (displayName ?? "").trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
            if let id = speakerId { return "Speaker \(id)" }
            return "Me"
        case .systemAudio:
            if let id = speakerId { return "Remote \(id)" }
            return "Remote"
        }
    }
}

@Observable
@MainActor
final class Transcriber {
    // MARK: - Observable

    /// Monotonic version counter — bumped on every mutation of
    /// `committedSegments` or `pendingSegments`. Build 41 added this as
    /// the cache key for `segments` and as the Observable surface that
    /// downstream consumers (RecordingSession.segments, UI) actually
    /// depend on. Reading `segmentsVersion` registers it as a dependency
    /// in the Observable tracking system, so when we bump it, every
    /// view that read it invalidates.
    ///
    /// **Why this exists:** pre-build-41 `segments` was a computed
    /// property doing `(committedSegments + pendingSegments).sorted{...}`
    /// on every read. With a 53-minute session producing ~1000 segments
    /// per transcriber, every Observable read of `session.segments`
    /// (Widget TimelineView@30fps, toolbar marquee `.onChange`, the
    /// transcript list, etc.) re-sorted both arrays — O(N log N) on
    /// the MainActor, hundreds of times per second. Symptom: pause/
    /// resume click queued behind ~8 seconds of accumulated MainActor
    /// work; widget flower animation stuck at 0 fps; toolbar marquee
    /// jittered on every Whisper commit. Build 41 caches the sort
    /// result keyed on `segmentsVersion` so consecutive reads are
    /// O(1) until the next mutation actually invalidates.
    private(set) var segmentsVersion: Int = 0
    @ObservationIgnored
    private var _segmentsCache: [TranscriptSegment] = []
    @ObservationIgnored
    private var _segmentsCacheVersion: Int = -1

    /// Merged committed + pending segments, sorted by start time.
    /// Cached behind `segmentsVersion` — see comment above.
    var segments: [TranscriptSegment] {
        // Read `segmentsVersion` first so Observable dependency tracking
        // registers it for the current view scope. When `invalidateSegmentsCache()`
        // bumps the version, all dependents invalidate. The cache slots
        // (`_segmentsCache`, `_segmentsCacheVersion`) are `@ObservationIgnored`
        // so they don't add noise to the dependency graph.
        let currentVersion = segmentsVersion
        if _segmentsCacheVersion == currentVersion {
            return _segmentsCache
        }
        let merged = (committedSegments + pendingSegments)
            .sorted(by: { $0.startedAt < $1.startedAt })
        _segmentsCache = merged
        _segmentsCacheVersion = currentVersion
        return _segmentsCache
    }

    /// Bump the version stamp so the next `segments` read re-sorts.
    /// Call after any mutation of `committedSegments` or `pendingSegments`.
    /// Wrapping add (&+=) is safe — at one mutation per ms forever this
    /// overflows in ~292 million years.
    private func invalidateSegmentsCache() {
        segmentsVersion &+= 1
    }

    /// Overwrite segment TEXT in place, by id — the write-back half of
    /// every post-stop correction pass: the vocabulary + brand rules
    /// (`MeetingVocabulary`) and the LLM polish (`TranscriptPolisher`).
    ///
    /// Text and nothing else: ids, timings, `speakerId`, `source`, and
    /// `isFinal` are all left exactly as the final Whisper pass and the
    /// diarizer left them, and no segment is added or removed. That's
    /// what keeps these passes incapable of damaging speaker
    /// attribution or the transcript's structure no matter what they
    /// return — a correction can only land inside a line's text.
    ///
    /// Ids not present in this transcriber's segments are ignored, so
    /// the caller can hand the same patch to both mic and system
    /// transcribers without splitting it first. Returns how many
    /// segments actually changed.
    @discardableResult
    func applyCorrectedText(_ byID: [UUID: String]) -> Int {
        guard !byID.isEmpty else { return 0 }
        var changed = 0
        for index in committedSegments.indices {
            if let text = byID[committedSegments[index].id], text != committedSegments[index].text {
                committedSegments[index].text = text
                changed += 1
            }
        }
        for index in pendingSegments.indices {
            if let text = byID[pendingSegments[index].id], text != pendingSegments[index].text {
                pendingSegments[index].text = text
                changed += 1
            }
        }
        if changed > 0 { invalidateSegmentsCache() }
        return changed
    }

    private(set) var isRunning = false

    /// Bumped by every `start()`. `runFinalPass` snapshots it and only
    /// clears `isRunning` at the end when the value is unchanged —
    /// i.e. when no newer session has re-started this shared
    /// transcriber while the (minutes-long) final pass ran. Wrapping
    /// add; overflow is irrelevant at one bump per session.
    private var runGeneration: UInt = 0

    private(set) var lastError: String?
    var localeIdentifier: String

    let source: SegmentSource

    // MARK: - Internal segment storage

    /// Frozen segments — Whisper won't be asked to revisit these.
    private var committedSegments: [TranscriptSegment] = []
    /// Latest pass's segments inside the active refine window.
    private var pendingSegments: [TranscriptSegment] = []
    /// Greatest end-time so far promoted to committed. Skip overlaps.
    private var committedThroughSec: Double = 0

    // MARK: - Audio buffer
    //
    // `allSamples` is a rolling buffer of 16 kHz mono Float32 audio
    // since the last `removeFirst`-trim. We keep at most
    // `bufferedSamplesCap` samples in memory; older samples have been
    // dropped (their absolute count tracked in `samplesDropped`).
    //
    // Index translation:
    //   absoluteSampleIndex = samplesDropped + allSamples.firstIndex
    //   bufferIndex          = absoluteSampleIndex - samplesDropped
    //
    // Indices into `allSamples` are LOCAL; we convert via
    // `samplesDropped` whenever we need to compare against
    // `committedThroughSec` (which is in absolute session-time
    // seconds).
    //
    // Pre-1.0.3 the buffer grew unbounded — ~230 MB on a 2-hour
    // session. Capped now at 30 min worth (~115 MB) which is enough
    // window for the live Whisper kick + live diarization to do
    // useful work. Final-transcribe on stop loses the cleanup pass
    // over audio older than 30 min but the live `committedSegments`
    // covering that range are kept intact, so the transcript still
    // covers the whole session.

    /// 30 minutes at 16 kHz mono = 30 * 60 * 16_000 = 28_800_000
    /// samples = ~115 MB as Float32.
    private static let bufferedSamplesCap: Int = 30 * 60 * 16_000
    /// Whisper's required input rate. Used by the final-pass source
    /// selection (buffer-index ↔ seconds) and the archive-decode path.
    private static let targetSampleRate: Double = 16_000
    /// Drop the oldest 5 minutes in one batch when the cap is hit —
    /// avoids per-buffer `removeFirst` churn (that would be O(n)
    /// every ingest call once we hit the cap).
    private static let trimBatchSamples: Int = 5 * 60 * 16_000

    /// Absolute count of samples dropped from the head of
    /// `allSamples` since the start of the session. Added to any
    /// local index to recover the absolute sample position.
    private var samplesDropped: Int = 0

    private var converter: AudioConverter?
    /// Input format the live `converter` was built for. The mic format can
    /// change mid-session (a route change to e.g. a 44.1 kHz wired headset);
    /// when it does we rebuild the converter. See `ingest(_:)`.
    private var converterInput: AVAudioFormat?
    private var allSamples: [Float] = []

    /// Read-only snapshot of the captured 16 kHz mono mic samples for the
    /// current session. Used by the Parakeet dictation path to transcribe
    /// the whole buffer directly, skipping the Whisper final pass.
    var capturedSamples: [Float] { allSamples }

    // MARK: - Tasks / timers

    private var consumerTask: Task<Void, Never>?
    private var liveTimer: Timer?
    private var transcribeTask: Task<Void, Never>?

    /// Apple SpeechAnalyzer live engine (macOS 26+ Lite tier). Stored as
    /// `AnyObject?` so the property itself isn't gated on macOS 26; always
    /// accessed behind `if #available`. nil ⇒ the Whisper rolling-window
    /// timer drives live instead (Full tier, or Lite fallback when Apple
    /// is unavailable / its model isn't installed yet).
    private var appleEngine: AnyObject?
    /// Session-audio seconds elapsed when the Apple engine began receiving
    /// buffers — added to its input-relative result times so segments land
    /// on the session timeline.
    private var appleEngineStartSec: Double = 0

    /// Live diarization task. Only spawned for `.systemAudio`
    /// transcribers — mic is always "Me", no clustering needed.
    /// Runs on a coarser cadence than `transcribeTask` (every
    /// ~15s of new audio) so we don't burn the Neural Engine
    /// re-clustering the same speakers every 2 seconds.
    private var diarizeTask: Task<Void, Never>?
    /// Audio-clock seconds at which the last live diarization run
    /// kicked off. `kickLiveDiarize` skips if we're inside the
    /// minimum interval. Reset on `reset()`.
    private var lastDiarizeSec: Double = 0
    /// How much new audio must accumulate between live
    /// diarization runs. 15s balances label freshness against
    /// the cost of re-clustering on a growing buffer; final
    /// pass on stop is still authoritative.
    private let liveDiarizeIntervalSec: Double = 15.0

    /// Per-cluster centroid embeddings from the most recent
    /// diarization pass — keyed by the same A/B/C labels used in
    /// `TranscriptSegment.speakerId`. Set by `runFinalTranscribe`,
    /// consumed by `RecordingSession.stop()` to write the
    /// `speakers.json` sidecar + match against `SpeakerProfileStore`.
    /// Empty for `.microphone` transcribers (no diarization runs).
    private(set) var speakerCentroids: [String: [Float]] = [:]

    /// EXPERIMENTAL (opt-in). Set by RecordingSession before the final
    /// pass when the session is calendar-bound and
    /// `settings.diarizeUseAttendeeCountHint` is on: pins the final
    /// diarization to this remote-speaker count (attendees − you) instead
    /// of auto-detecting. nil ⇒ auto (default). System-audio path only.
    var speakerCountHint: Int?

    private var sessionStartedAt: Date?
    private var bucketIDs: [Int: UUID] = [:]

    /// Language Whisper will use for every subsequent decode once we
    /// see enough committed text to confidently identify it via
    /// `LanguageDetector` (NLLanguageRecognizer). Stays nil for the
    /// first few seconds of every session, then snaps to a 2-letter
    /// ISO code and stays there.
    ///
    /// Why this exists: with `language: nil` Whisper auto-detects
    /// per chunk, and on noisy / silent chunks it sometimes drifts
    /// — an English meeting suddenly emits "ご視聴ありがとうござ
    /// いました" because a moment of silence got classified as
    /// Japanese. Pinning the language after we know what it is
    /// kills that class of hallucination outright.
    ///
    /// Only used when the user picked "Auto-detect" in Settings
    /// (`localeIdentifier == "auto"`). If they pinned a language
    /// explicitly we honour that and never touch this field.
    ///
    /// Exposed (read-only) because it is the ONLY place the session's
    /// real language is ever computed: `localeIdentifier` is a SETTING
    /// and reads "auto" for most people. `RecordingSession` writes it to
    /// the transcript frontmatter as `detected_locale:` and hands it to
    /// the voice corpus, where "which language was this?" decides which
    /// bucket the user's own speech belongs in.
    private(set) var detectedLanguage: String?

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Transcriber")

    // MARK: - Tuning constants

    /// Live re-transcribe cadence. Lite runs less often (3.5 s vs 2 s)
    /// to cut CPU/ANE load on long meetings; the final pass on Stop is
    /// full quality regardless of tier. Read after `liveTier` is set.
    private var liveIntervalSec: Double { liveTier == .lite ? 3.5 : 2.0 }
    private let liveWindowSec: Double = 30.0
    /// A segment is promoted to "committed" once its end time falls more
    /// than this many seconds before the trailing edge of the rolling
    /// window. Whisper still has refinement room for younger segments.
    /// Lite commits sooner (6 s vs 10 s) so the unsettled tail is
    /// re-decoded fewer times before it settles.
    private var commitMarginSec: Double { liveTier == .lite ? 6.0 : 10.0 }

    // MARK: - Init

    init(localeIdentifier: String = "auto",
         source: SegmentSource = .microphone,
         diarize: Bool? = nil) {
        self.localeIdentifier = localeIdentifier
        self.source = source
        // Default: diarize iff system-audio (the historical
        // behaviour). Callers can override for mic-side diarization
        // gated on `settings.diarizeMicrophone`.
        self.diarizationEnabled = diarize ?? (source == .systemAudio)
    }

    /// Whether this Transcriber runs Pyannote diarization passes
    /// (live + final). True by default for system-audio source,
    /// false for microphone unless explicitly enabled.
    private let diarizationEnabled: Bool

    // MARK: - Lifecycle

    /// `liveTranscription = true` (default, historical behaviour):
    /// kick Whisper every `liveIntervalSec` seconds so live segments
    /// land in the toolbar popover and widget feeds in near-real-time.
    /// Hammers MainActor with per-window commits + cache invalidations
    /// + SwiftUI cascades — fine on short meetings, expensive on
    /// 1.5h+ sessions where the cumulative cost saturates the main
    /// thread and pause/resume clicks stack behind it.
    ///
    /// `liveTranscription = false` (build 43 deferred mode): skip
    /// the liveTimer entirely. The consumerTask still ingests audio
    /// into `allSamples` so the on-disk archive grows, but Whisper
    /// stays silent for the duration. On Stop, `runFinalPass()` runs
    /// the same single-shot pass it always did and the transcript
    /// materialises in one go. Toolbar popover shows an empty list
    /// during recording; downstream UI that reads `segments` sees
    /// an empty array until Stop. This is the architectural escape
    /// hatch for users whose meetings are long enough that live
    /// transcription is more cost than value.
    func start(consuming audio: AsyncStream<AudioChunk>, startedAt: Date, tier: LiveTranscriptionTier = .full) {
        guard !isRunning else { return }
        // Generation stamp — lets a stale `runFinalPass` from the
        // PREVIOUS session detect that this shared transcriber has
        // been re-started for a new one and leave `isRunning` alone
        // (issue #7: the old pass finishing minutes into the next
        // meeting used to flip isRunning off and kill its live
        // transcription).
        runGeneration &+= 1
        sessionStartedAt = startedAt
        isRunning = true
        lastError = nil
        committedSegments.removeAll()
        pendingSegments.removeAll()
        invalidateSegmentsCache()
        committedThroughSec = 0
        allSamples.removeAll()
        samplesDropped = 0
        bucketIDs.removeAll()
        converter = nil
        converterInput = nil
        liveTier = tier

        consumerTask = Task { @MainActor [weak self] in
            for await chunk in audio {
                guard let strong = self else { break }
                strong.ingest(chunk)
            }
        }

        if tier != .off {
            startLivePath()
        }
    }

    /// Live-transcription tier this session started with (Full/Lite/Off),
    /// captured at `start()` time. Drives cadence (`liveIntervalSec`),
    /// commit margin (`commitMarginSec`) and the live decode profile.
    /// `.off` means no live timer at all (deferred mode — one full pass
    /// on Stop); pause/resume read this so a deferred-mode session never
    /// tries to re-arm a timer it never had.
    @ObservationIgnored
    private var liveTier: LiveTranscriptionTier = .full

    /// EXPERIMENTAL (dark): set by RecordingSession before `start()` for
    /// dictation sessions when `dictationUseNemotronLive` is on. Routes
    /// the live preview through `NemotronLiveEngine` (streaming, 560 ms
    /// chunks) instead of the Whisper rolling-window timer. The final
    /// pass / pasted text are unaffected. Cleared on `reset()`.
    @ObservationIgnored
    var dictationNemotronLive = false
    /// True while a Nemotron live session is actually running (engine
    /// loaded + session began OK). Gates the ingest forward.
    @ObservationIgnored
    private var nemotronActive = false
    /// Stable row identity for the single growing preview segment, so
    /// SwiftUI updates one row instead of churning new ones per chunk.
    @ObservationIgnored
    private var nemotronSegmentID = UUID()

    /// Set by RecordingSession before `start()` for dictation sessions
    /// whose engine is Apple SpeechAnalyzer. Dictation runs at the `.full`
    /// tier (whose live path is the Whisper rolling timer); this flag
    /// routes it through `AppleSpeechLiveEngine` instead, so the person
    /// sees words as they speak — the experience that sold Egor on the
    /// NATIVE macOS dictation (2026-08-29). Same gates as the Lite path
    /// (macOS 26, concrete locale, model installed); any miss falls back
    /// to the Whisper timer exactly as before. Cleared on `reset()`.
    @ObservationIgnored
    var dictationAppleLive = false
    /// Streaming caption sink for dictation: called with the full running
    /// transcript after each Apple live result. RecordingSession points
    /// this at the widget's caption pill for `.dictation` sessions and
    /// leaves it nil otherwise (meetings render live text in their own
    /// transcript view — no caption wanted). Fires only from the Apple
    /// live path: the Whisper fallback's ~per-window cadence is too
    /// coarse to read as "live" and would make the pill look broken.
    /// Cleared on `reset()`.
    @ObservationIgnored
    var onDictationLiveText: (@MainActor (String) -> Void)?

    /// Soft pause. Kill the live re-transcribe timer so no rolling
    /// Whisper passes run while we're paused — but keep the
    /// consumerTask alive (no audio is flowing anyway because the
    /// upstream capture is paused), keep accumulated segments
    /// visible, keep `isRunning == true` so the rest of the app
    /// reads us as "still in a session".
    func pause() {
        guard isRunning else { return }
        liveTimer?.invalidate()
        liveTimer = nil
        // Wait out any in-flight transcribe in a detached task so
        // we don't block the UI. If it finishes after we resume,
        // its result will land on the same segment maps.
    }

    /// Re-arm the live re-transcribe timer. No-op for deferred-mode
    /// sessions (build 43) — the session never had a live timer, so
    /// resume has nothing to re-arm; the audio ingestion side
    /// continues regardless.
    func resume() {
        guard isRunning, liveTier != .off else { return }
        // Apple engine keeps streaming across pause (no buffers flow while
        // the upstream capture is paused), so there's nothing to re-arm.
        if appleEngine != nil { return }
        guard liveTimer == nil else { return }
        scheduleWhisperLiveTimer()
    }

    // MARK: - Live engine selection

    /// Pick the live engine for this session: Apple SpeechTranscriber for
    /// the Lite tier on macOS 26+ with a concrete locale (zero app memory,
    /// faster); otherwise the Whisper rolling-window timer (Full tier, or
    /// the Lite fallback while/if Apple is unavailable).
    private func startLivePath() {
        // EXPERIMENTAL dictation streaming preview (dark) — see
        // NemotronLiveEngine. Falls back to the Whisper timer when the
        // engine can't run (model not downloaded yet / load failed).
        // Deliberately outranks the Apple caption path below: the dark
        // flag exists to test Nemotron, and whoever set it wants that
        // engine driving, caption or no caption.
        if dictationNemotronLive {
            startNemotronLivePath()
            return
        }
        if liveTier == .lite || dictationAppleLive, #available(macOS 26, *), let appleLocale = resolvedAppleLocale() {
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.appleEngine == nil, self.liveTimer == nil else { return }
                if await AppleSpeechLiveEngine.isUsable(locale: appleLocale),
                   await AppleSpeechLiveEngine.ensureModelReady(locale: appleLocale) {
                    let engine = AppleSpeechLiveEngine(locale: appleLocale) { [weak self] result in
                        self?.applyAppleLiveResult(result)
                    }
                    do {
                        try await engine.start()
                        guard self.isRunning else { await engine.finish(); return }
                        // Capture the offset at the moment Apple goes live, so
                        // its input-relative times map onto session time.
                        self.appleEngineStartSec = Double(self.samplesDropped + self.allSamples.count) / 16_000.0
                        self.appleEngine = engine
                        self.log.info("Live engine: Apple SpeechTranscriber (\(appleLocale.identifier, privacy: .public))")
                        return
                    } catch {
                        self.log.error("Apple live engine failed — using Whisper-Lite: \(error.localizedDescription, privacy: .public)")
                    }
                }
                // Fallback: Whisper rolling-window timer.
                if self.isRunning, self.appleEngine == nil, self.liveTimer == nil {
                    self.scheduleWhisperLiveTimer()
                }
            }
        } else {
            scheduleWhisperLiveTimer()
        }
    }

    private func scheduleWhisperLiveTimer() {
        liveTimer = Timer.scheduledTimer(withTimeInterval: liveIntervalSec, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let strong = self else { return }
                strong.kickLiveTranscribe()
            }
        }
    }

    // MARK: - Nemotron streaming live path (dictation preview, dark)

    private func startNemotronLivePath() {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            let lang = self.localeIdentifier == "auto" ? nil : self.localeIdentifier
            let ok = await NemotronLiveEngine.shared.beginSession(languageCode: lang) { [weak self] text in
                self?.applyNemotronRunningText(text)
            }
            guard self.isRunning else {
                if ok { NemotronLiveEngine.shared.endSession() }
                return
            }
            if ok {
                self.nemotronActive = true
                self.log.info("Live engine: Nemotron 3.5 streaming (dictation preview)")
            } else if self.liveTimer == nil, self.appleEngine == nil {
                self.log.warning("Nemotron live unavailable — falling back to Whisper live timer")
                self.scheduleWhisperLiveTimer()
            }
        }
    }

    /// Render the running streamed transcript as ONE growing pending
    /// segment (stable id → no SwiftUI row churn). The one-shot final
    /// pass on Stop replaces it wholesale, so nothing here is committed.
    private func applyNemotronRunningText(_ text: String) {
        guard isRunning, let started = sessionStartedAt else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let endSec = Double(samplesDropped + allSamples.count) / 16_000.0
        pendingSegments = [TranscriptSegment(
            id: nemotronSegmentID,
            startedAt: started,
            text: trimmed,
            isFinal: false,
            source: source,
            endSec: endSec,
            startSec: 0
        )]
        invalidateSegmentsCache()
    }

    /// Concrete `Locale` for the Apple engine, or nil when the user is on
    /// Auto-detect (Apple has no language detection — Whisper-Lite, which
    /// does, handles that case).
    private func resolvedAppleLocale() -> Locale? {
        let id = localeIdentifier
        let prefix = id.split(separator: "-").first.map(String.init)?.lowercased() ?? "auto"
        guard prefix != "auto", !id.isEmpty else { return nil }
        return Locale(identifier: id)
    }

    /// Change the live tier mid-session (thermal/low-power auto-downgrade).
    /// Apple-engine sessions are already Lite and are left as-is; the
    /// Whisper path re-arms its timer so the new cadence + decode profile
    /// (both derive from `liveTier`) take effect immediately.
    func setLiveTier(_ newTier: LiveTranscriptionTier) {
        guard isRunning, newTier != liveTier else { return }
        liveTier = newTier
        if appleEngine != nil { return }
        liveTimer?.invalidate()
        liveTimer = nil
        if newTier != .off {
            scheduleWhisperLiveTimer()
        }
    }

    private func finishAppleEngine() async {
        if #available(macOS 26, *), let engine = appleEngine as? AppleSpeechLiveEngine {
            await engine.finish()
        }
        appleEngine = nil
    }

    /// Map one Apple live result into committed/pending, mirroring
    /// `applyLivePass`'s 100 ms bucketing so SwiftUI keeps stable row
    /// identity as a volatile result updates and then finalizes.
    private func applyAppleLiveResult(_ r: AppleLiveResult) {
        guard isRunning, let started = sessionStartedAt else { return }
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let absStart = appleEngineStartSec + r.startSec
        let absEnd = max(absStart, appleEngineStartSec + r.endSec)
        let bucket = Int(absStart * 10)
        let id = bucketIDs[bucket] ?? UUID()
        bucketIDs[bucket] = id

        if r.isFinal {
            if !text.isEmpty {
                let seg = TranscriptSegment(
                    id: id,
                    startedAt: started.addingTimeInterval(absStart),
                    text: text,
                    isFinal: true,
                    source: source,
                    endSec: absEnd,
                    startSec: absStart
                )
                if let idx = committedSegments.firstIndex(where: { $0.id == id }) {
                    committedSegments[idx] = seg
                } else {
                    committedSegments.append(seg)
                }
                committedThroughSec = max(committedThroughSec, absEnd)
                updateLockedLanguageIfPossible()
            }
            pendingSegments.removeAll { $0.id == id || $0.endSec <= committedThroughSec }
        } else if !text.isEmpty {
            let seg = TranscriptSegment(
                id: id,
                startedAt: started.addingTimeInterval(absStart),
                text: text,
                isFinal: false,
                source: source,
                endSec: absEnd,
                startSec: absStart
            )
            if let idx = pendingSegments.firstIndex(where: { $0.id == id }) {
                pendingSegments[idx] = seg
            } else {
                pendingSegments.removeAll { $0.endSec <= committedThroughSec }
                pendingSegments.append(seg)
            }
        }
        invalidateSegmentsCache()
        kickLiveDiarizeIfDue(currentAudioSec: absEnd)

        // Dictation caption: hand the full running text (committed +
        // volatile tail, in time order) to whoever is listening. Sorted
        // because a volatile result can still be in `pendingSegments`
        // while a later bucket has already committed.
        if let onDictationLiveText {
            // Tie-break on finality: Swift's sort isn't stable, and a
            // committed final + volatile tail sharing a 100 ms bucket
            // must not momentarily swap in the caption.
            let running = (committedSegments + pendingSegments)
                .sorted {
                    ($0.startSec, $0.isFinal ? 0 : 1) < ($1.startSec, $1.isFinal ? 0 : 1)
                }
                .map(\.text)
                .joined(separator: " ")
            if !running.isEmpty { onDictationLiveText(running) }
        }
    }

    /// Legacy entry point — runs live-stop + final pass back-to-back.
    /// Kept for callers that don't care about latency. Production
    /// callers (RecordingSession.stop) use `stopCapture()` +
    /// `runFinalPass()` to keep the user-facing Stop snappy.
    func stop() async {
        await stopCapture()
        await runFinalPass()
    }

    /// Dictation stop: cancel the in-flight live windowed decode (and
    /// kill the live timer so no new window starts) WITHOUT waiting
    /// for it. The dictation final pass discards live segments
    /// wholesale (`runFinalTranscribe` clears `committedSegments` on
    /// its full-replace path), so the live result is dead weight that
    /// the final decode would otherwise queue behind on the
    /// WhisperEngine semaphore. Callers must still go through
    /// `stopCapture()` afterwards — its `await transcribeTask?.value`
    /// is what guarantees the cancelled task has actually exited and
    /// released the engine slot before the final pass starts.
    /// Meeting/voice-note stops must NOT call this: their live
    /// segments are the immediate post-stop transcript.
    func cancelLivePass() {
        liveTimer?.invalidate()
        liveTimer = nil
        transcribeTask?.cancel()
    }

    /// Fast first stage of stopping: halt live consumers, drain
    /// any in-flight live transcribe / diarize tasks, then return.
    /// Does NOT run the final Whisper pass — caller must invoke
    /// `runFinalPass()` separately (typically detached so the user
    /// can start a new recording immediately).
    ///
    /// 2026-05-27 — split out of `stop()` because the final pass
    /// on a 20-minute mic session was clocking ~4 minutes of
    /// Whisper inference (logs: `post-stop final_transcribe_mic:
    /// 237091ms`), all of it blocking `status = .finished`. Users
    /// who hit Stop because they're rushing to the next meeting
    /// got stranded in a "Stopping…" hourglass for minutes.
    func stopCapture() async {
        guard isRunning else { return }
        liveTimer?.invalidate()
        liveTimer = nil
        consumerTask?.cancel()
        consumerTask = nil

        // Disarm the dictation caption sink BEFORE finalizing the Apple
        // engine: `finalizeAndFinishThroughEndOfInput` flushes final
        // results through `applyAppleLiveResult`, and with the sink
        // still armed the caption pill — already hidden at key-up by
        // `RecordingSession.stop()` — would resurrect and sit stale
        // through the whole inline final pass (review find, 2026-08-29).
        // The flushed SEGMENTS still land; only the caption goes quiet.
        onDictationLiveText = nil

        await finishAppleEngine()

        // Stop the streaming dictation preview, if it was driving live.
        if nemotronActive {
            NemotronLiveEngine.shared.endSession()
            nemotronActive = false
        }

        // How long Stop waits for the in-flight live windowed decode
        // before the final pass can start. For dictation,
        // RecordingSession cancels the task first (`cancelLivePass()`),
        // so this should be near-zero there — the log line verifies it.
        let liveDrainStart = Date()
        await transcribeTask?.value
        transcribeTask = nil
        let liveDrainMs = Int(Date().timeIntervalSince(liveDrainStart) * 1000)
        log.info("stopCapture live-pass drain: \(liveDrainMs, privacy: .public)ms source=\(String(describing: self.source), privacy: .public)")

        // Wait for any in-flight live diarization pass — without
        // this it would race with a later `runFinalPass()` and
        // could overwrite final speaker labels with stale live ones.
        await diarizeTask?.value
        diarizeTask = nil

        // NB: isRunning is intentionally left true here. The final
        // pass still needs to consume `allSamples` and update
        // `committedSegments` + `speakerCentroids`. We flip
        // isRunning = false at the end of `runFinalPass()`.
    }

    /// Second stage of stopping: re-runs Whisper over the full
    /// accumulated audio buffer for best-quality segmentation,
    /// merges with FluidAudio diarization, and writes the final
    /// centroids to `speakerCentroids` so RecordingSession can
    /// persist `speakers.json`.
    ///
    /// On 20+ minute sessions this can take multiple minutes of
    /// Neural Engine time. Production callers run this detached
    /// from `RecordingSession.stop()` so the user is freed the
    /// moment audio capture stops, not the moment the final pass
    /// finishes.
    /// `archiveURLs` — the complete on-disk `.caf` archive(s) for this
    /// stream (mic parts, or the single system file). When present and
    /// decodable, the final pass transcribes the FULL recording from
    /// disk instead of the in-memory rolling buffer, so the saved
    /// transcript covers the whole session even when live transcription
    /// fell behind and the buffer trimmed un-transcribed audio. Empty
    /// (the default, and for transcript-only / "don't record audio"
    /// sessions) keeps the legacy buffer-based pass.
    /// `profile` — decode cost profile for the final Whisper pass.
    /// Defaults to `.full` (meeting/voice-note quality path). The
    /// dictation stop passes `.dictationFinal` so the inline
    /// release→paste decode doesn't pay full-width search latency.
    /// `biasTerms` — dictation vocabulary fed to Whisper's `promptTokens`.
    /// Default `[]` (meeting/voice-note final passes don't bias); the
    /// dictation stop passes `DictationDictionary.shared.biasTerms()`.
    func runFinalPass(archiveURLs: [URL] = [], profile: WhisperEngine.DecodeProfile = .full, biasTerms: [String] = []) async {
        let myGeneration = runGeneration
        await runFinalTranscribe(archiveURLs: archiveURLs, profile: profile, biasTerms: biasTerms)
        // Only clear `isRunning` when no NEW session has re-started
        // this shared transcriber while the pass was running. A stale
        // pass (session rotated / user quick-restarted) writing
        // `isRunning = false` here used to kill the new session's live
        // transcription — `kickLiveTranscribe` and `stopCapture` both
        // guard on `isRunning` (issue #7).
        if runGeneration == myGeneration {
            isRunning = false
        } else {
            log.info("Final pass: transcriber was re-started for a newer session — leaving isRunning untouched")
        }
    }

    func reset() {
        liveTimer?.invalidate()
        liveTimer = nil
        consumerTask?.cancel()
        consumerTask = nil
        transcribeTask?.cancel()
        transcribeTask = nil
        diarizeTask?.cancel()
        diarizeTask = nil
        lastDiarizeSec = 0
        if nemotronActive {
            NemotronLiveEngine.shared.endSession()
        }
        nemotronActive = false
        dictationNemotronLive = false
        nemotronSegmentID = UUID()
        dictationAppleLive = false
        onDictationLiveText = nil
        // Tear down a live Apple engine that never went through
        // `stopCapture()` — discard() and failFast both land here
        // directly. Left alive, it (a) blocks the NEXT session's
        // `startLivePath` on its `appleEngine == nil` guard with no
        // Whisper fallback, and (b) keeps eating that session's buffers
        // via `ingest`, committing segments with the OLD session's time
        // base (review find, 2026-08-29). reset() is synchronous, so
        // finish() is fire-and-forget — the input continuation closes
        // immediately, which is what stops the result flow.
        if #available(macOS 26, *), let engine = appleEngine as? AppleSpeechLiveEngine {
            Task { await engine.finish() }
        }
        appleEngine = nil
        appleEngineStartSec = 0
        committedSegments.removeAll()
        pendingSegments.removeAll()
        invalidateSegmentsCache()
        committedThroughSec = 0
        allSamples.removeAll()
        samplesDropped = 0
        bucketIDs.removeAll()
        speakerCentroids.removeAll()
        converter = nil
        converterInput = nil
        isRunning = false
        lastError = nil
        sessionStartedAt = nil
        detectedLanguage = nil
    }

    // MARK: - Audio ingestion

    private func ingest(_ chunk: AudioChunk) {
        // Rebuild the resampler if the mic's input format changed mid-
        // session. AudioConverter is pinned to the format it was built
        // with; after a route change to a different sample rate (e.g. a
        // 44.1 kHz wired headset) feeding it the new buffers produced
        // garbage/empty output — live transcription silently froze even
        // though capture, the archive roll, and the petals kept going.
        // Mirrors the guard AppleSpeechLiveEngine.convert() already uses.
        let inFormat = chunk.pcm.format
        if converter == nil || converterInput != inFormat {
            converter = AudioConverter(inputFormat: inFormat)
            converterInput = inFormat
        }
        guard let conv = converter,
              let samples = conv.convert(chunk.pcm),
              !samples.isEmpty else { return }
        allSamples.append(contentsOf: samples)

        // Cap rolling buffer at 30 min. When exceeded, drop the
        // oldest 5 min in one O(n) batch — better than running
        // `removeFirst(N)` per ingest call once we hit the cap.
        // Older samples are gone from memory; their committed
        // transcript segments stay in `committedSegments` so the
        // user-facing transcript is unaffected.
        if allSamples.count > Self.bufferedSamplesCap {
            let toDrop = min(Self.trimBatchSamples, allSamples.count)
            allSamples.removeFirst(toDrop)
            samplesDropped += toDrop
            log.info("Transcriber rolling buffer trimmed: dropped \(toDrop, privacy: .public) samples (total dropped: \(self.samplesDropped, privacy: .public))")
        }

        // Forward to the Apple live engine (Lite tier, macOS 26+) when active.
        // `allSamples` still accumulates above for the final Whisper pass.
        if #available(macOS 26, *), let engine = appleEngine as? AppleSpeechLiveEngine {
            engine.ingest(chunk.pcm)
        }

        // Streaming dictation preview (dark) — forward the converted
        // chunk to the Nemotron engine. Cheap enqueue; decode runs on
        // the engine's actor off the main thread, strictly FIFO.
        if nemotronActive {
            NemotronLiveEngine.shared.ingest(samples: samples)
        }
    }

    // MARK: - Live (chunked) transcribe

    private func kickLiveTranscribe() {
        guard isRunning, transcribeTask == nil, !allSamples.isEmpty else { return }

        // Slice the rolling 30 s tail, but skip audio we've already
        // committed — no point re-transcribing settled text.
        //
        // All `committedThroughSec`-derived offsets are ABSOLUTE
        // (session-time relative); convert to local buffer indices
        // by subtracting `samplesDropped`.
        let windowSampleCount = Int(liveWindowSec * 16_000)
        let committedAbsolute = Int(committedThroughSec * 16_000)
        let latestAbsolute = samplesDropped + allSamples.count
        let earliestAbsolute = max(committedAbsolute, latestAbsolute - windowSampleCount)
        // Clamp to current buffer bounds: anything older than the
        // buffer head has been trimmed, so the floor is `samplesDropped`.
        let earliestAbsoluteClamped = max(samplesDropped, earliestAbsolute)
        let clampedOffset = max(0, min(allSamples.count, earliestAbsoluteClamped - samplesDropped))

        guard allSamples.count > clampedOffset else { return }
        let samples = Array(allSamples[clampedOffset..<allSamples.count])
        let windowStartSec = Double(samplesDropped + clampedOffset) / 16_000.0
        let windowEndSec = Double(latestAbsolute) / 16_000.0
        let lang = languageHint
        let liveProfile: WhisperEngine.DecodeProfile = (liveTier == .lite) ? .lite : .full

        transcribeTask = Task { @MainActor [weak self] in
            do {
                // Cooperative cancellation (dictation stop). Don't
                // start a decode after cancel, and don't apply a
                // result that lands after cancel — the dictation final
                // pass clears live segments anyway, and skipping the
                // apply keeps committedSegments/pendingSegments
                // untouched mid-stop. WhisperEngine.transcribe also
                // checks cancellation internally (on slot acquire and
                // between VAD spans) and throws CancellationError.
                if !Task.isCancelled {
                    let result = try await WhisperEngine.shared.transcribe(
                        samples: samples,
                        language: lang,
                        profile: liveProfile
                    )
                    if let strong = self, !Task.isCancelled {
                        strong.applyLivePass(
                            result,
                            windowStartSec: windowStartSec,
                            windowEndSec: windowEndSec
                        )
                    }
                }
            } catch is CancellationError {
                // Benign: dictation stop cancelled this window — the
                // result would have been discarded by the final pass.
                self?.log.info("Live transcribe cancelled — window discarded")
            } catch {
                if let strong = self {
                    strong.log.error("Live transcribe failed: \(error.localizedDescription, privacy: .public)")
                    strong.lastError = error.localizedDescription
                }
            }
            if let strong = self {
                strong.transcribeTask = nil
            }
        }
    }

    private func applyLivePass(_ result: [WhisperSegment],
                               windowStartSec: Double,
                               windowEndSec: Double) {
        guard let started = sessionStartedAt else { return }

        let commitCutoff = windowEndSec - commitMarginSec
        var newCommitted: [TranscriptSegment] = []
        var newPending: [TranscriptSegment] = []

        for ws in result {
            let trimmed = ws.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let absStart = windowStartSec + ws.start
            let absEnd = windowStartSec + ws.end

            // Skip segments that are entirely older than what's already
            // committed (defensive — shouldn't happen given our offset).
            if absEnd <= committedThroughSec { continue }

            // Bucket at 100 ms resolution — coarser keys cause two
            // distinct short utterances ("yes." then "ok.") to share
            // a UUID, after which SwiftUI's ForEach silently drops
            // one of them.
            let bucket = Int(absStart * 10)
            let id = bucketIDs[bucket] ?? UUID()
            bucketIDs[bucket] = id

            let candidate = TranscriptSegment(
                id: id,
                startedAt: started.addingTimeInterval(absStart),
                text: trimmed,
                isFinal: false,
                source: source,
                endSec: absEnd,
                startSec: absStart
            )

            if absEnd <= commitCutoff {
                var frozen = candidate
                frozen.isFinal = true
                newCommitted.append(frozen)
            } else {
                newPending.append(candidate)
            }
        }

        if !newCommitted.isEmpty {
            committedSegments.append(contentsOf: newCommitted)
            committedThroughSec = max(committedThroughSec,
                                      newCommitted.map(\.endSec).max() ?? 0)
            // Drop any old pending whose bucket is now covered.
            pendingSegments.removeAll { $0.endSec <= committedThroughSec }
            updateLockedLanguageIfPossible()
        }
        pendingSegments = newPending
        // Mutations to committedSegments / pendingSegments above — bump
        // the cache version so the next `segments` read re-sorts.
        invalidateSegmentsCache()

        // Live diarization tick — only for system-audio transcribers,
        // and only every ~15s of accumulated audio. Mic source skips
        // entirely (single speaker "Me", no clustering needed).
        kickLiveDiarizeIfDue(currentAudioSec: windowEndSec)
    }

    // MARK: - Live diarization
    //
    // Periodic in-session pass that gives users mid-meeting visibility
    // into who's speaking. Tradeoffs:
    //
    //   • Cadence: every 15s, not per-Whisper-pass. Per-pass would
    //     run diarization every 2s on an ever-growing buffer — O(n²)
    //     on long meetings, no perceptible UX gain over 15s.
    //   • Scope: only `.systemAudio`. Mic side is always "Me".
    //   • Label stability: once a committed segment receives a
    //     speakerId, we DON'T override it on later runs even if the
    //     clustering shifts. Prevents the "Alex turned into Bob" jolt
    //     when FluidAudio re-clusters on a fresh audio length.
    //   • Final pass on stop is unchanged — full re-merge with fresh
    //     IDs, authoritative output for transcript.md.

    private func kickLiveDiarizeIfDue(currentAudioSec: Double) {
        guard diarizationEnabled else { return }
        guard diarizeTask == nil else { return }
        // First pass needs ~10s of audio to cluster anything useful;
        // skip earlier ticks so we don't waste a run on 2 seconds
        // of "hello".
        guard currentAudioSec >= 10 else { return }
        guard currentAudioSec - lastDiarizeSec >= liveDiarizeIntervalSec else { return }

        lastDiarizeSec = currentAudioSec
        let snapshotSamples = allSamples

        diarizeTask = Task { @MainActor [weak self] in
            let spans = await DiarizationEngine.shared.diarize(samples: snapshotSamples)
            guard let strong = self else { return }
            strong.applyLiveDiarization(spans: spans)
            strong.diarizeTask = nil
        }
    }

    /// Apply diarized spans to committed segments. Skips any
    /// segment that already has a `speakerId` — label stability >
    /// label freshness.
    private func applyLiveDiarization(spans: [DiarizedSpan]) {
        guard !spans.isEmpty else { return }
        committedSegments = committedSegments.map { seg in
            guard seg.speakerId == nil else { return seg }
            var copy = seg
            let segLen = seg.endSec - seg.startSec
            guard segLen > 0 else { return copy }

            var best: (id: String, ratio: Double)?
            for span in spans {
                let overlapStart = max(seg.startSec, span.startSec)
                let overlapEnd = min(seg.endSec, span.endSec)
                guard overlapEnd > overlapStart else { continue }
                let ratio = (overlapEnd - overlapStart) / segLen
                if best == nil || ratio > best!.ratio {
                    best = (span.speakerId, ratio)
                }
            }
            if let best, best.ratio >= 0.30 {
                copy.speakerId = best.id
            }
            return copy
        }
        // Replaced committedSegments wholesale — invalidate cache.
        invalidateSegmentsCache()
    }

    // MARK: - Final transcribe on stop

    private func runFinalTranscribe(archiveURLs: [URL] = [], profile: WhisperEngine.DecodeProfile = .full, biasTerms: [String] = []) async {
        guard let started = sessionStartedAt else { return }
        // 2026-05-27 — cooperative cancellation. With the 1.0.7.3 two-
        // stage Stop, this method runs inside the detached finalize
        // Task. If the user hits Start on a new recording mid-final-
        // pass, RecordingSession.start() cancels summaryTask and
        // resets the transcriber. We need to bail without touching
        // `committedSegments` / `speakerCentroids` — otherwise the
        // Whisper output from the old session would land on top of
        // the new session's freshly-reset state. The actual Whisper
        // inference itself isn't cancellation-aware, so the worst
        // case is wasted Neural Engine time on the old session's
        // audio while the new session's live transcription queues
        // behind it; the state-corruption path is closed.
        if Task.isCancelled {
            log.info("Final pass: cancelled before start — bailing")
            return
        }

        // Block-wise streaming path (2026-08-10, increment 2 same day).
        // Caps peak memory at O(block) instead of O(session)
        // (~230 MB/hour/stream), releases the engine slot between
        // blocks so the OTHER stream's final pass and a new session's
        // live windows can interleave, and makes cancellation land at
        // block boundaries instead of after an archive-length
        // inference. Diarization streams the same blocks through a
        // per-pass `DiarizationBlockPass` (FluidAudio's SpeakerManager
        // keeps IDs consistent across blocks), run OFF-main — unlike
        // the legacy `diarizeFull`, which stalls the MainActor for the
        // whole synchronous inference. The legacy path below survives
        // for buffer-fallback sessions (transcript-only, or
        // `.archiveUnusable` falling through to it).
        var streamingDeclinedArchive = false
        if !archiveURLs.isEmpty {
            switch await runStreamingFinalPass(
                archiveURLs: archiveURLs,
                profile: profile,
                biasTerms: biasTerms,
                started: started
            ) {
            case .done, .cancelled, .failed:
                return
            case .archiveUnusable:
                streamingDeclinedArchive = true
            }
        }

        // Source selection — the heart of the long-recording fix.
        //
        // Prefer the COMPLETE on-disk `.caf` archive over the in-memory
        // rolling buffer. `allSamples` is capped at 30 min and trimmed
        // (oldest 5 min dropped) whenever the live pass falls behind on a
        // long/dense recording — so a buffer-based final pass can only
        // re-transcribe the retained tail and loses everything that was
        // trimmed, even though the recorder wrote it all to disk. Decoding
        // the archive here makes the saved transcript cover the ENTIRE
        // session from 0:00, independent of live-pass lag. The decode is
        // CPU + IO heavy, so it runs on a detached background Task off the
        // MainActor. Falls back to the buffer when there's no archive
        // (transcript-only / "don't record audio" sessions) or a decode
        // failure (corrupt file) — those keep the legacy behaviour.
        // (If the streaming path already found the archive unusable,
        // don't decode it a second time just to learn the same thing —
        // go straight to the buffer fallback.)
        let archiveSamples: [Float]? = (archiveURLs.isEmpty || streamingDeclinedArchive)
            ? nil
            : await Task.detached(priority: .userInitiated) {
                AudioArchiveDecoder.decodeToMono16k(urls: archiveURLs)
            }.value

        if Task.isCancelled {
            log.info("Final pass: cancelled during archive decode — bailing")
            return
        }

        let samples: [Float]
        let finalRangeStart: Double
        let fullReplace: Bool
        if let decoded = archiveSamples, decoded.count > Int(Self.targetSampleRate) {
            // Archive covers the whole session from second 0.
            samples = decoded
            finalRangeStart = 0
            fullReplace = true
            log.info("Final pass: transcribing FULL archive — \(decoded.count, privacy: .public) samples (≈\(Int(Double(decoded.count) / Self.targetSampleRate), privacy: .public)s), \(archiveURLs.count, privacy: .public) file(s)")
        } else {
            // No usable archive — fall back to the in-memory buffer. On a
            // long session this only covers the retained (untrimmed) tail;
            // earlier live-committed segments are preserved below.
            guard !allSamples.isEmpty else {
                log.info("Final pass: no archive and empty buffer — nothing to transcribe")
                return
            }
            samples = allSamples
            finalRangeStart = Double(samplesDropped) / Self.targetSampleRate
            fullReplace = samplesDropped == 0
            if archiveURLs.isEmpty {
                log.info("Final pass: no archive (transcript-only session) — using in-memory buffer, \(samples.count, privacy: .public) samples")
            } else {
                log.error("Final pass: archive decode failed/empty — falling back to in-memory buffer (transcript may be incomplete if the buffer was trimmed)")
            }
        }
        let lang = languageHint

        // Third cancellation check — right before committing to the
        // non-cancellable Whisper inference. On session rotation or a
        // quick manual stop→start the cancel typically lands while the
        // archive decode above is in flight; bailing here keeps the
        // shared engine slot free for the NEW session's live windows
        // instead of burning minutes of Neural Engine time on a doomed
        // pass (issue #7).
        if Task.isCancelled {
            log.info("Final pass: cancelled before inference — bailing")
            return
        }

        // Run Whisper + diarization in parallel — both are CoreML on
        // the Neural Engine, but Whisper hogs the encoder and the
        // diarizer is much lighter (~15-25% of Whisper runtime), so
        // overlapping them is essentially free.
        async let whisperResult = WhisperEngine.shared.transcribe(
            samples: samples,
            language: lang,
            profile: profile,
            biasTerms: biasTerms
        )
        // Diarization is opt-in for the mic source (Settings →
        // Transcription → "Diarize microphone too") and on-by-
        // default for system audio. Use the FULL diarization output
        // (spans + centroids) so RecordingSession can fingerprint-
        // match this session's speakers against the SpeakerProfileStore.
        async let diarizationOutput: DiarizationOutput =
            diarizationEnabled
                ? DiarizationEngine.shared.diarizeFull(samples: samples, numSpeakers: speakerCountHint)
                : DiarizationOutput(spans: [], centroids: [:])

        do {
            let result = try await whisperResult
            let output = await diarizationOutput

            // Second cancellation check — Whisper + diarization
            // just returned but the user may have started a new
            // recording during that time. `allSamples`,
            // `samplesDropped`, etc. have been reset by then;
            // mutating committedSegments here would clobber the
            // new session's state-in-progress.
            if Task.isCancelled {
                log.info("Final pass: cancelled after Whisper/diarize — skipping commit")
                return
            }

            // Reconcile against the live-accumulated segments.
            //
            //   • fullReplace == true  — the source covers the whole
            //     session from second 0 (the on-disk archive, or a short
            //     buffer that never trimmed). The final pass is
            //     authoritative for the ENTIRE transcript: clear
            //     everything and rebuild from this pass's output. This is
            //     the path that closes the long-recording gap — a 37-min
            //     archive yields a 37-min transcript regardless of how
            //     little the live pass committed.
            //
            //   • fullReplace == false — buffer fallback on a trimmed
            //     long session (no archive). `samples[0]` corresponds to
            //     session-time `finalRangeStart`, not zero, so we keep
            //     the earlier live-committed segments and replace only the
            //     retained-tail range with cleaner output.
            if fullReplace {
                committedSegments.removeAll()
                pendingSegments.removeAll()
                bucketIDs.removeAll()
                committedThroughSec = 0
            } else {
                committedSegments = committedSegments.filter { $0.endSec <= finalRangeStart }
                pendingSegments.removeAll()
                bucketIDs.removeAll()
                committedThroughSec = finalRangeStart
                log.info("Final pass: buffer fallback (>\(Int(finalRangeStart), privacy: .public)s trimmed) — preserved \(self.committedSegments.count, privacy: .public) earlier live segments")
            }

            // Whisper returns segment timestamps relative to
            // samples[0]. Offset by `finalRangeStart` to get
            // session-absolute times.
            var fresh: [TranscriptSegment] = []
            for ws in result {
                let trimmed = ws.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let absStart = ws.start + finalRangeStart
                let absEnd = ws.end + finalRangeStart
                fresh.append(TranscriptSegment(
                    id: UUID(),
                    startedAt: started.addingTimeInterval(absStart),
                    text: trimmed,
                    isFinal: true,
                    source: source,
                    speakerId: nil,
                    endSec: absEnd,
                    startSec: absStart
                ))
            }
            log.info("Final pass: \(fresh.count) segments from Whisper, \(output.spans.count) speaker spans from FluidAudio (\(output.centroids.count) centroids)")

            // Attach speaker labels via max-IoU overlap. Diarization
            // spans are also relative to samples[0]; offset them too.
            let offsetSpans: [DiarizedSpan] = output.spans.map { span in
                DiarizedSpan(
                    speakerId: span.speakerId,
                    startSec: span.startSec + finalRangeStart,
                    endSec: span.endSec + finalRangeStart
                )
            }
            let mergedFresh = DiarizationEngine.mergeBySpeaker(
                segments: fresh,
                diarization: offsetSpans
            )
            // Append fresh on top of any preserved earlier segments.
            committedSegments.append(contentsOf: mergedFresh)
            committedSegments.sort { $0.startSec < $1.startSec }
            committedThroughSec = committedSegments.map(\.endSec).max() ?? 0
            // Final-pass replaced/extended committedSegments — invalidate
            // cache so any subsequent `segments` read picks up the
            // higher-quality final-pass output.
            invalidateSegmentsCache()
            // Stash centroids so RecordingSession.stop() can write
            // the speakers.json sidecar + match against profiles.
            speakerCentroids = output.centroids
        } catch is CancellationError {
            // Benign, by design: the user started a new recording (or reset)
            // while this session's final pass was mid-Whisper, so
            // RecordingSession rotated/cancelled summaryTask. NOT a failure —
            // log as info and DON'T set `lastError` (which previously surfaced
            // a spurious "failed" state for a session that's actually fine).
            // The session keeps its live-accumulated segments; only the
            // full-quality final re-pass was skipped. (If live transcription
            // was OFF this means the tail is sparse — tracked separately:
            // a new session shouldn't silently sacrifice the prior final pass.)
            log.info("Final pass cancelled (new session started mid-pass) — keeping live segments, no error surfaced.")
        } catch {
            log.error("Final transcribe failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    // MARK: - Streaming final pass

    private enum StreamingFinalOutcome {
        /// Committed (possibly zero segments from a silent archive) —
        /// nothing left for the caller to do.
        case done
        /// Session rotated / user restarted mid-pass — keep the
        /// live-accumulated segments, surface no error (same contract
        /// as the legacy CancellationError branch).
        case cancelled
        /// Inference failed — `lastError` is set, live segments kept.
        case failed
        /// Archive missing/tiny (< 1 s) — caller falls back to the
        /// legacy path, which will use the in-memory buffer.
        case archiveUnusable
    }

    /// Block-wise final pass over the on-disk archive: ~15-minute
    /// blocks cut at the quietest seam (see `ArchiveBlockReader`),
    /// each run through the full `WhisperEngine.transcribe` pipeline —
    /// Silero pre-pass, bias, post-filter, rescue all apply per block
    /// unchanged. Segments accumulate with block offsets and commit
    /// ONCE at the end, exactly like the legacy `fullReplace == true`
    /// branch: an archive always covers the session from 0:00, so the
    /// result is authoritative for the whole transcript.
    ///
    /// Diarization (when enabled for this stream) rides the same
    /// blocks: each block goes to `DiarizationBlockPass.process` on a
    /// detached task OVERLAPPING that block's Whisper decode — the
    /// same Whisper/diarizer parallelism the legacy path had, but
    /// off-main and O(block). `atTime:` gives session-absolute span
    /// timestamps, so the merge at commit needs no offsetting. A nil
    /// block pass (FluidAudio unavailable) degrades to no speaker
    /// labels, the same contract as `diarizeFull` returning empty.
    private func runStreamingFinalPass(
        archiveURLs: [URL],
        profile: WhisperEngine.DecodeProfile,
        biasTerms: [String],
        started: Date
    ) async -> StreamingFinalOutcome {
        let reader = ArchiveBlockReader(urls: archiveURLs)
        guard let firstBlock = await Task.detached(priority: .userInitiated, operation: { reader.nextBlock() }).value else {
            return .archiveUnusable
        }
        // Usability gate, mirroring the legacy `decoded.count >
        // targetSampleRate` check: the reader only returns a block
        // shorter than its 15-min target at EOF, so a ≤1 s first block
        // means the whole archive is ≤1 s.
        if firstBlock.samples.count <= Int(Self.targetSampleRate) {
            return .archiveUnusable
        }

        let lang = languageHint
        let blockPass: DiarizationBlockPass? = diarizationEnabled
            ? await DiarizationEngine.shared.makeBlockPass(numSpeakers: speakerCountHint)
            : nil
        if diarizationEnabled && blockPass == nil {
            log.warning("Final pass (streaming): diarizer unavailable — proceeding without speaker labels")
        }
        var fresh: [TranscriptSegment] = []
        var blockCount = 0
        var coveredSec = 0.0
        var block: (samples: [Float], startSec: Double)? = firstBlock

        while let current = block {
            // Cancellation lands HERE, between blocks — the wins over
            // the legacy path: at most one block of Neural Engine time
            // is wasted on a doomed pass, not the whole archive, and
            // the engine slot frees for the new session's live windows.
            if Task.isCancelled {
                log.info("Final pass (streaming): cancelled at block boundary after \(blockCount, privacy: .public) block(s) — keeping live segments")
                return .cancelled
            }
            blockCount += 1
            do {
                // Whisper + diarizer overlap per block, mirroring the
                // legacy `async let` pairing: Whisper hogs the ANE
                // encoder, the diarizer is ~15-25% of its runtime, so
                // the overlap is essentially free. The detached hop
                // keeps the synchronous CoreML inference off the
                // MainActor. `blockPass` access stays serial: this
                // `async let` is awaited before the loop advances.
                async let diarized: Void = { [blockPass] in
                    guard let blockPass else { return }
                    let samples = current.samples
                    let startSec = current.startSec
                    await Task.detached(priority: .userInitiated) {
                        blockPass.process(samples: samples, atSec: startSec)
                    }.value
                }()
                let result = try await WhisperEngine.shared.transcribe(
                    samples: current.samples,
                    language: lang,
                    profile: profile,
                    biasTerms: biasTerms
                )
                await diarized
                for ws in result {
                    let trimmed = ws.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let absStart = current.startSec + ws.start
                    let absEnd = current.startSec + ws.end
                    fresh.append(TranscriptSegment(
                        id: UUID(),
                        startedAt: started.addingTimeInterval(absStart),
                        text: trimmed,
                        isFinal: true,
                        source: source,
                        speakerId: nil,
                        endSec: absEnd,
                        startSec: absStart
                    ))
                }
                coveredSec = current.startSec + Double(current.samples.count) / Self.targetSampleRate
                log.info("Final pass (streaming): block \(blockCount, privacy: .public) [\(Int(current.startSec), privacy: .public)s–\(Int(coveredSec), privacy: .public)s] → \(result.count, privacy: .public) segments (\(fresh.count, privacy: .public) total)")
            } catch is CancellationError {
                log.info("Final pass (streaming): cancelled mid-block — keeping live segments, no error surfaced")
                return .cancelled
            } catch {
                log.error("Final pass (streaming): block \(blockCount, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
                return .failed
            }
            // Re-check BEFORE decoding the next block: a cancel that
            // arrived during this block's inference shouldn't pay for
            // another ~15 min of file IO + resampling first.
            if Task.isCancelled {
                log.info("Final pass (streaming): cancelled after block \(blockCount, privacy: .public) — keeping live segments")
                return .cancelled
            }
            block = await Task.detached(priority: .userInitiated, operation: { reader.nextBlock() }).value
        }

        if Task.isCancelled {
            log.info("Final pass (streaming): cancelled before commit — keeping live segments")
            return .cancelled
        }

        // Fold diarization: spans are already session-absolute
        // (`atTime:`), `fresh` is already offset per block — no
        // translation step, unlike the legacy path's `offsetSpans`.
        // `finish()` is label-mapping only, cheap enough for MainActor.
        let diarization = blockPass?.finish() ?? DiarizationOutput(spans: [], centroids: [:])
        let merged = DiarizationEngine.mergeBySpeaker(
            segments: fresh,
            diarization: diarization.spans
        )

        // Commit — the legacy `fullReplace` branch verbatim: the
        // archive covers the whole session, this output replaces
        // everything the live pass accumulated.
        committedSegments.removeAll()
        pendingSegments.removeAll()
        bucketIDs.removeAll()
        committedSegments = merged.sorted { $0.startSec < $1.startSec }
        committedThroughSec = committedSegments.map(\.endSec).max() ?? 0
        invalidateSegmentsCache()
        // Centroids feed RecordingSession.stop()'s speakers.json
        // sidecar + SpeakerProfileStore matching, same as legacy.
        speakerCentroids = diarization.centroids
        log.info("Final pass (streaming): committed \(merged.count, privacy: .public) segments from \(blockCount, privacy: .public) block(s), ≈\(Int(coveredSec), privacy: .public)s of archive, \(diarization.spans.count, privacy: .public) speaker spans (\(diarization.centroids.count, privacy: .public) centroids)")
        return .done
    }

    // MARK: - Locale

    /// Whisper takes two-letter ISO codes (en, ru, …) or nil for auto.
    ///
    /// Resolution order:
    ///   1. Explicit user choice in Settings (anything that isn't
    ///      "auto") — always wins.
    ///   2. Auto-detect WITH a snapped `detectedLanguage` — feed the
    ///      locked code to Whisper so it stops auto-detecting per
    ///      chunk and stops drifting on noise.
    ///   3. Auto-detect, not yet locked — return nil so Whisper picks
    ///      a language per chunk while we wait for enough committed
    ///      text to lock on.
    private var languageHint: String? {
        let prefix = localeIdentifier
            .split(separator: "-")
            .first
            .map(String.init)?
            .lowercased()
        if let prefix, prefix != "auto" { return prefix }
        return detectedLanguage
    }

    /// Try to snap `detectedLanguage` once we have enough committed
    /// text to be sure. Called from `applyLivePass` after each
    /// committed batch. Idempotent — once locked, stays locked for
    /// the session.
    private func updateLockedLanguageIfPossible() {
        guard detectedLanguage == nil else { return }
        // Only act when the user is on Auto-detect — if they pinned
        // a language explicitly, no locking needed.
        let isAuto = (
            localeIdentifier.split(separator: "-").first.map(String.init)?.lowercased() ?? "auto"
        ) == "auto"
        guard isAuto else { return }
        // Need a meaningful amount of confirmed text before we trust
        // the detector. 3 committed segments + ~120 chars is the
        // sweet spot in QA — earlier than that and pure-noise leaks
        // ("so", "はい") through filter (1)–(3) can still bias the
        // language detection.
        guard committedSegments.count >= 3 else { return }
        let text = committedSegments
            .map(\.text)
            .joined(separator: " ")
        guard text.count >= 120 else { return }
        if let detected = LanguageDetector.detect(text) {
            detectedLanguage = detected
            log.info("Locked transcription language to \(detected, privacy: .public) after \(self.committedSegments.count, privacy: .public) committed segments")
        }
    }

    // MARK: - Locale catalog (exposed for UI)

    static let availableLocales: [(id: String, label: String)] = [
        ("auto",  String(localized: "Auto-detect")),
        ("en",    "English"),
        ("ru",    "Русский"),
        ("uk",    "Українська"),
        ("pl",    "Polski"),
        ("es",    "Español"),
        ("de",    "Deutsch"),
        ("fr",    "Français"),
        ("it",    "Italiano"),
        ("pt",    "Português"),
        ("ja",    "日本語"),
        ("ko",    "한국어"),
        ("zh",    "中文"),
    ]
}
