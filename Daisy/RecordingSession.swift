//
//  RecordingSession.swift
//  Daisy
//
//  Ties together microphone capture, optional system audio loopback,
//  Whisper transcription for each, periodic screenshots, and Apple
//  Intelligence summarization into a single observable session.
//

import Foundation
import AVFoundation
import Observation
import os
// NSPasteboard / Accessibility-paste live behind `DictationPaste`
// now — RecordingSession itself doesn't need AppKit.
// The `.send_failures.json` JSON coders moved to
// RecordingSession+Finalize.swift next to their consumer.

/// Why a meeting ended up with only the user's own voice in it.
///
/// Top-level rather than nested in `RecordingSession` because the value
/// outlives the session: it is written to `daisy_mic_only:` in the
/// transcript frontmatter and read back by `StoredSession` and the
/// Library detail long after the recording is gone. The raw values are
/// therefore an ON-DISK CONTRACT — extend the enum freely, never rename
/// a case's string (older builds' parsers drop unknown keys safely, but
/// a renamed one silently loses the reason on every existing session).
///
/// Distinct from `RecordingSession.ArchiveStatus`, which records the
/// SYMPTOM (`empty`) and reads identically for a Bluetooth output
/// route, DRM-protected playback, a revoked permission, and a meeting
/// where nobody spoke. This names a cause.
nonisolated enum MicOnlyCause: String, Sendable {
    /// `CGPreflightScreenCaptureAccess()` said no before we ever armed
    /// the loopback stream. The actionable one: the fix is a toggle.
    case screenRecordingDenied = "screen-recording-denied"
    /// Permission was there but `SCStream` refused to start, refused to
    /// resume after a pause, or died mid-meeting and spent its restart
    /// budget — display gone, SCK regression, and so on.
    case systemAudioFailed = "system-audio-failed"
}

@Observable
@MainActor
final class RecordingSession {
    /// One of three top-level modes the user can engage:
    ///
    ///   - `.meeting` — the classic Daisy flow. Mic + system audio,
    ///     LLM summary, autoSend to Notion/MCP, full session saved
    ///     to History.
    ///
    ///   - `.voiceNote` — quick personal capture. Mic only (no
    ///     system audio, no remote participants), NO LLM summary
    ///     (just the transcript). Persisted with `daisy_kind: note`
    ///     (SessionKind) so it surfaces in the Notes tab regardless of
    ///     which project it lives in; defaults to Inbox like any capture.
    ///     Useful for "remember this before I forget" moments.
    ///
    ///   - `.dictation` — Wispr-Flow-lite. Mic only, no summary,
    ///     transcript goes straight to the clipboard and the
    ///     session directory is deleted on stop. A toast tells the
    ///     user to ⌘V into their target app. No persistent
    ///     artifacts — the user is producing typed text, not a
    ///     transcript.
    ///
    /// Mode is set at start time via the corresponding hotkey or
    /// public toggle method. It survives across `pause()`/`resume()`
    /// (you can pause a voice note mid-record). Defaults to
    /// `.meeting` for any code path that doesn't explicitly pick.
    enum RecordingMode: String, Codable, Sendable {
        case meeting
        case voiceNote
        case dictation
    }

    enum Status: Equatable {
        case idle
        case preparing
        case recording
        /// Soft pause: audio capture stopped and live transcription
        /// halted, but the session is preserved. On `resume()` we
        /// reopen the capture pipelines and keep appending to the
        /// same audio archive + transcript. From `paused` you can
        /// either `resume()` (back to .recording) or `stop()`
        /// (full finalize, summary, etc.).
        case paused
        case stopping
        /// **Deprecated as of 2026-05-19** — `stop()` now jumps from
        /// `.stopping` straight to `.finished` and runs summarize +
        /// autoSend in a detached background task, so the widget /
        /// panel no longer blocks for the 15-30 seconds an LLM call
        /// takes. See `summaryGenerationState` for the new lifecycle.
        /// The case is kept so existing exhaustive switches still
        /// compile; it is never assigned by normal flow.
        case summarizing
        case finished
        case failed(String)
    }

    /// Independent lifecycle for the post-Stop summary + auto-send
    /// pipeline. Decoupled from `Status` so the widget can go idle
    /// the instant `transcript.md` is on disk, while the LLM call
    /// keeps running in the background and a placeholder skeleton
    /// shows in SessionDetailView until the summary lands.
    enum SummaryGenerationState: Equatable {
        /// No active post-Stop summary task. Either none was needed
        /// (auto-summarize off, no provider, zero segments) or the
        /// previous one finished/was cancelled.
        case idle
        /// Detached task is running: summarize() in flight, then
        /// summary.json write, then autoSend.
        case generating
        /// summary.json is on disk and autoSend has completed.
        case ready
        /// Summarizer threw, autoSend failed, or the task was
        /// cancelled by a fresh `start()`. Carries a short reason
        /// for surfacing in toasts/logs.
        case failed(String)
    }

    // MARK: - Observable

    /// User-facing summary of the system-audio capture pipeline.
    /// Exposed so UI surfaces (HomeView, sidebar capsule, widget)
    /// can show whether the "other side" of the meeting is being
    /// captured — a permission denial or silent failure shouldn't
    /// leave the user discovering it after a 60-minute meeting.
    enum SystemAudioStatus: Equatable {
        case disabled               // user toggled it off in Settings
        case pending                // recording hasn't started yet
        case capturing              // SCStream is live and feeding the transcriber
        case denied                 // Screen Recording permission missing — skipped at start()
        case failed(String)         // SCStream.startCapture() threw or stopped unexpectedly
    }

    /// Post-stop audit verdict for an individual archive file (.caf
    /// on disk). Distinct from the live `SystemAudioStatus` /
    /// recording-state machine — this is what the user sees in the
    /// transcript frontmatter and in any "save outcome" toast.
    ///
    /// Pre-1.0.7.1 the frontmatter only distinguished off / captured /
    /// empty, all derived from in-memory `hasReceivedAudio`. The
    /// Billions 2026-05-25 test exposed the silent case missing from
    /// that taxonomy: SCKit was delivering buffers (transcriber got
    /// 44 min), AVAudioFile.write was throwing mid-session (every
    /// frame after some point), and the frontmatter still proudly
    /// stamped `captured` because at least ONE buffer had arrived
    /// before things went sideways. `.truncated` is the new fourth
    /// state — surfaced as a post-stop warning toast AND a grep-able
    /// frontmatter line.
    enum ArchiveStatus: Equatable {
        /// User had the toggle disabled (system) or stream isn't
        /// applicable to mode (mic in dictation-only mode). No file
        /// was expected.
        case off
        /// File exists, frames-written matches expected within a
        /// reasonable tolerance, on-disk byte count is non-trivial.
        case captured(bytes: Int64)
        /// Stream was armed but zero frames ever arrived (BT output,
        /// SCKit Tahoe regression, denied permission). User saw a
        /// mid-recording warning toast (silenceMonitor) but also gets
        /// this in the frontmatter for post-hoc grep.
        case empty
        /// **The silent-write-death case.** Frames arrived in callbacks
        /// (hasReceivedAudio=true) but disk-write count is far below
        /// what was received, or the file size is < header threshold
        /// despite reported frames, or a non-trivial number of write
        /// errors fired. User gets a loud toast at stop time so they
        /// know their audio is partial.
        case truncated(bytes: Int64, framesWritten: UInt64, writeErrors: Int)
    }

    private(set) var status: Status = .idle

    /// Post-Stop summary lifecycle. Set to `.generating` the moment
    /// `stop()` spins up the detached finalize task; flips to
    /// `.ready` when summary.json is written + autoSend ran; flips
    /// to `.failed` if summarizer threw or task was cancelled by a
    /// fresh recording. Drives the SessionDetailView skeleton + the
    /// widget's amber-pulse "summary cooking" indicator.
    // setter internal for RecordingSession+Finalize.swift
    var summaryGenerationState: SummaryGenerationState = .idle

    /// Detached task spun up by `stop()` that handles the full post-
    /// stop pipeline (final Whisper pass → speaker match → re-render
    /// transcript.md → summary → autoSend → audio purge). Held so a
    /// fresh `start()` / `reset()` can cancel it. Kept
    /// @ObservationIgnored because the Task reference itself isn't
    /// UI-relevant — only `summaryGenerationState` is.
    @ObservationIgnored
    // internal for RecordingSession+Finalize.swift
    var summaryTask: Task<Void, Never>?

    /// Monotonic generation counter for `summaryTask`. Bumped on
    /// every spawn. The finalize task captures its own generation at
    /// spawn time, and only clears `summaryTask` at exit when its
    /// captured generation still matches `summaryTaskGeneration` —
    /// i.e., when no fresh `stop()` has rotated the slot to a newer
    /// task in the meantime. Without this, the race is:
    ///   1. M1 stop → spawn T1 (gen=1)
    ///   2. User starts M2 → `start()` cancels T1, nils slot
    ///   3. M2 stop → spawn T2 (gen=2)
    ///   4. T1 wakes from Whisper, sees Task.isCancelled, runs
    ///      `bailRotated` which would `summaryTask = nil`,
    ///      clobbering T2's reference — T2 is now uncancellable.
    /// Generation check at exit (`if myGen == summaryTaskGeneration`)
    /// makes T1's cleanup a no-op once T2 has rotated past it.
    @ObservationIgnored
    // internal for RecordingSession+Finalize.swift
    var summaryTaskGeneration: UInt = 0

    /// One-shot flag set by `performStartFromMeeting` right before its
    /// rotation `stop()`: tells stop() NOT to spawn the finalize task
    /// for the outgoing meeting (it would be cancelled immediately
    /// anyway, but used to win the MainActor FIFO race against that
    /// cancel and hog the Whisper slot / clobber shared transcriber
    /// state — issue #7, back-to-back meetings). Consumed (reset to
    /// false) by the next stop().
    @ObservationIgnored
    private var skipFinalPassOnNextStop = false

    /// True when the most recent `start()` skipped system audio
    /// because `CGPreflightScreenCaptureAccess()` returned false.
    /// Cleared on the next start() that successfully bootstraps the
    /// stream — so toggling Screen Recording on and starting a new
    /// recording produces the right `systemAudioStatus`.
    private var systemAudioDeniedThisSession: Bool = false

    /// Why THIS session is microphone-only, if it is. Set once (first
    /// cause wins) by `noteMicOnlyDegradation`, persisted into the
    /// transcript frontmatter as `daisy_mic_only:` and surfaced in the
    /// Library detail. Nil for a healthy meeting, and for every
    /// dictation / voice note (those are mic-only by design and never
    /// go near the loopback stream).
    ///
    /// Exists because the warning at start time is a toast and a pill —
    /// both gone within seconds, and both invisible when the session was
    /// auto-started while the user was already in Zoom. Two mic-only
    /// meetings on 1.0.7.61 were only diagnosed days later.
    private(set) var micOnlyCause: MicOnlyCause?
    var title: String = ""
    var localeIdentifier: String {
        didSet {
            micTranscriber.localeIdentifier = localeIdentifier
            systemTranscriber.localeIdentifier = localeIdentifier
        }
    }
    private(set) var sessionDirectory: URL?
    private(set) var micArchiveURL: URL?
    private(set) var systemArchiveURL: URL?
    private(set) var startedAt: Date?

    // MARK: - Side notes (voice note layered over a live meeting)

    /// A wall-clock span the user marked as a side note WHILE a meeting
    /// was recording, via the voice-note hotkey. On finalize the meeting
    /// segments overlapping each span are COPIED (never cut) into their
    /// own note session in the Notes folder, together with a matching
    /// audio excerpt (mic + system, mixed) sliced from the meeting's own
    /// archive — i.e. the note is a clip of the meeting, snapped to the
    /// covered transcript-segment boundaries. The meeting itself stays
    /// whole. ("excerpt" model, 2026-07-21.) Meeting-mode only.
    struct SideNoteWindow: Sendable, Equatable {
        let start: Date
        var end: Date?
    }
    private(set) var sideNoteWindows: [SideNoteWindow] = []

    /// True while a side-note window is open (started, not yet ended).
    /// Drives the recording-capsule / toast indication.
    var isCapturingSideNote: Bool {
        sideNoteWindows.last.map { $0.end == nil } ?? false
    }

    /// Whether a wall-clock instant falls inside any side-note window
    /// (an open window extends to now). Finalize uses it to gather the
    /// meeting segments that belong to each note excerpt.
    func isInSideNoteWindow(_ date: Date) -> Bool {
        sideNoteWindows.contains { w in
            date >= w.start && (w.end.map { date <= $0 } ?? true)
        }
    }

    /// Toggle side-note capture from the voice-note hotkey during a
    /// meeting: first press opens a window, second closes it. No-op
    /// outside an active meeting (the hotkey keeps its normal meaning
    /// when idle or in a standalone voice-note session). Just drops
    /// wall-clock markers — the audio/text excerpt is sliced from the
    /// meeting's own recording on finalize, so nothing extra is captured
    /// live and the meeting recording is never touched.
    func toggleSideNoteCapture() {
        guard currentMode == .meeting,
              status == .recording || status == .paused else { return }
        if isCapturingSideNote {
            let idx = sideNoteWindows.count - 1
            sideNoteWindows[idx].end = Date()
            ToastCenter.shared.show(
                String(localized: "Side note saved — it'll be split out when you stop."),
                style: .success
            )
        } else {
            sideNoteWindows.append(SideNoteWindow(start: Date(), end: nil))
            ToastCenter.shared.show(
                String(localized: "Marking a side note… press the voice-note key again to end it."),
                style: .info
            )
        }
    }

    /// Auto-matched speaker map produced after the final diarization
    /// pass — Daisy looks up each detected speaker's centroid
    /// embedding in `SpeakerProfileStore` and pre-fills "A" → "Alex"
    /// when a stored profile cosine-matches. Read by `MarkdownExporter`
    /// when writing transcript.md so the user opens the session and
    /// sees real names already in place; empty map for first-time
    /// recordings (no profiles yet) or mic-only sessions.
    // setter internal for RecordingSession+Finalize.swift
    var initialSpeakerMap: [String: String] = [:]

    /// When the recording was triggered by a calendar event, this
    /// holds the meeting metadata so the transcript markdown
    /// frontmatter can persist the binding. `nil` means a manual
    /// (hotkey / button) start.
    // setter internal for RecordingSession+AutoStop.swift
    var boundMeeting: DaisyMeeting?

    /// Immutable preparation captured when this calendar recording began.
    /// Persisted immediately as `meeting-preparation.json` in the session
    /// directory and surfaced by `StoredSession` after a Library refresh.
    var meetingPreparationSnapshot: MeetingPreparationSnapshot?

    /// Folder this recording will be filed into. Defaults to .inbox;
    /// the user can change it from the Home toolbar before pressing
    /// Start, and from SessionDetailView after the fact (which
    /// rewrites the transcript frontmatter on disk).
    var folder: SessionFolder = .inbox

    /// Free-form tag for this session. Persisted to frontmatter as
    /// `daisy_tag:` and used for grouping in History (sidebar
    /// selector + chip in the row). Empty string == "untagged"
    /// (the default). `TagSuggestion.suggest(from:)` pre-fills
    /// this when the session is bound to a calendar event with
    /// attendees from an external organization. Renamed from
    /// `client` in 1.0.5.2 — kept the same backing field, just a
    /// more generic user-facing name.
    var tag: String = ""

    // Phase 2 modules — exposed so the UI can read state.
    let summarizer: Summarizer
    let screenshots: ScreenshotCapture
    let micTranscriber: Transcriber
    let systemTranscriber: Transcriber
    /// Watches recorder.levelDB during recording and flips
    /// `questionVisible` after ~3 min of continuous quiet so the
    /// floating widget can pop an "Are we done?" callout. The
    /// session owns it (matches start/pause/resume/stop lifecycle).
    /// `var` (not `let`) only so the init can assign a `self`-aware
    /// monitor after the rest of the stored state is up.
    private(set) var silenceMonitor: SilenceMonitor!

    /// The screenshot note this dictation was started for, claimed at
    /// key-down and consumed at release (see `ScreenshotNoteCapture`).
    /// `nil` for an ordinary dictation, which pastes as always.
    var pendingScreenshotNote: ScreenshotNoteCapture.Pending?

    /// The note this dictation was feeding was thrown away from its pill
    /// while the hold was still live. Clearing `pendingScreenshotNote`
    /// alone is NOT enough: by then the key may already be released and
    /// the finalize pipeline suspended inside the ASR pass, and a nil
    /// claim there means "ordinary dictation" — so the sentence the person
    /// just cancelled would be pasted into whatever app is in front. This
    /// says the whole take goes with the note.
    ///
    /// Zeroed at the top of the next `start()`, NOT in `reset()` — same
    /// reason as `micOnlyCause`, mirrored: `start()` runs `reset()` in its
    /// middle, well after `startDictationHotkey` has claimed the note, so
    /// clearing there would drop a discard made while the session was
    /// still coming up.
    var screenshotNoteDiscarded = false

    /// Moments the user marked during THIS session, in time order. Kept
    /// in memory so the widget and detail view can react live; the file
    /// (`markers.json`) is written on every mark and is the truth after
    /// a relaunch. See `MomentMarkers`.
    ///
    /// Not `private(set)` only because the one writer —
    /// `markMomentByHotkey` — lives in `RecordingSession+Hotkeys.swift`,
    /// and Swift's setter access is file-scoped. Nothing else should
    /// write it.
    var momentMarkers: [MomentMarker] = []

    // Re-exported recorder state.
    var elapsed: TimeInterval { recorder.elapsed }
    var levelDB: Float { recorder.levelDB }
    /// Live audio spectrum (6 voice-tuned bands, 0…1) used by the floating
    /// Daisy widget to animate its petals — the lower 4 drive the 8 petals,
    /// mirrored for symmetry. Forwarded from the mic recorder.
    var spectrumBands: [Float] { recorder.spectrumBands }
    /// Every archived audio file the mic recorder produced for this
    /// session. Always at least `[microphone.caf]` while recording;
    /// becomes `[microphone.caf, microphone.part2.caf, …]` when a
    /// mid-session route change forced a format-rollover into a
    /// new part. Exposed for `MarkdownExporter` frontmatter +
    /// future History-pane "this session has N audio parts"
    /// affordance.
    var archivedAudioParts: [URL] { recorder.archivedParts }

    /// Merged transcript across mic + system, sorted by absolute start
    /// time. Cached behind a `(mic.segmentsVersion, system.segmentsVersion)`
    /// composite key — see build 41 comment on `Transcriber.segmentsVersion`
    /// for the why. Tl;dr: pre-build-41 this re-sorted both arrays on
    /// every Observable read, and on a 53-min session (1000+ segments
    /// per transcriber) that drowned the MainActor; pause/resume clicks
    /// queued behind ~8 seconds of accumulated sort work, the widget
    /// flower animation stalled at 0 fps.
    ///
    /// Cache hits when both transcribers' versions match the snapshot
    /// captured at last sort. Reading their `segmentsVersion` registers
    /// them in Observable dependency tracking, so when either transcriber
    /// mutates, the current view scope invalidates and re-reads here.
    var segments: [TranscriptSegment] {
        let micV = micTranscriber.segmentsVersion
        let sysV = systemTranscriber.segmentsVersion
        if _segmentsCacheMicVersion == micV && _segmentsCacheSysVersion == sysV {
            return _segmentsCache
        }
        let merged = (micTranscriber.segments + systemTranscriber.segments)
            .sorted(by: { $0.startedAt < $1.startedAt })
        _segmentsCache = merged
        _segmentsCacheMicVersion = micV
        _segmentsCacheSysVersion = sysV
        return _segmentsCache
    }
    @ObservationIgnored
    private var _segmentsCache: [TranscriptSegment] = []
    @ObservationIgnored
    private var _segmentsCacheMicVersion: Int = -1
    @ObservationIgnored
    private var _segmentsCacheSysVersion: Int = -1

    /// `segments` minus empty / whitespace-only lines, cached behind the
    /// same `(mic, system) segmentsVersion` composite key as `segments`.
    /// The live transcript popover reads this so SwiftUI does not run an
    /// O(N) `.filter` (plus a `String` allocation per segment) on every
    /// body re-evaluation — pre-this, `ContentView.filteredSegments` was
    /// recomputed 3-4× per render and again every `liveIntervalSec` pass.
    /// Predicate is byte-for-byte the old `filteredSegments` one, so
    /// behaviour is unchanged; the filter just runs once per mutation.
    /// Reading the transcribers' `segmentsVersion` here registers the
    /// Observable dependency, so this cache invalidates exactly when
    /// `segments` does.
    var displaySegments: [TranscriptSegment] {
        let micV = micTranscriber.segmentsVersion
        let sysV = systemTranscriber.segmentsVersion
        if _displayCacheMicVersion == micV && _displayCacheSysVersion == sysV {
            return _displayCache
        }
        let filtered = segments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        _displayCache = filtered
        _displayCacheMicVersion = micV
        _displayCacheSysVersion = sysV
        return _displayCache
    }
    @ObservationIgnored
    private var _displayCache: [TranscriptSegment] = []
    /// `segments` with acoustic echo removed — what every LLM consumer
    /// reads (via `fullTranscriptText`), the live catch-up slices, and
    /// the voice-corpus harvest keeps.
    ///
    /// Cached behind the same `(mic, system) segmentsVersion` composite
    /// key as `segments`, because the pass is not free: a sort plus a
    /// windowed Levenshtein scan per mic segment. One stop reads this
    /// five times over (WPM gate, usage stats, locale hint, the summary,
    /// the polish silence check) and would otherwise redo the whole
    /// thing each time.
    ///
    /// Meetings only. Dictation and voice notes have no system stream
    /// for the microphone to echo, so there is nothing to remove and the
    /// pass would only cost time.
    var dedupedSegments: [TranscriptSegment] {
        let all = segments
        guard currentMode == .meeting, settings.suppressAcousticEcho else { return all }
        let micV = micTranscriber.segmentsVersion
        let sysV = systemTranscriber.segmentsVersion
        if _dedupCacheMicVersion == micV && _dedupCacheSysVersion == sysV {
            return _dedupCache
        }
        // `filteredQuietly`, not `filter`: `lastFilterWasSystemic` is the
        // render's to set, and `stop()` reads it in the gap between the
        // render and the headphones toast.
        let filtered = AcousticEchoDedup.filteredQuietly(all)
        _dedupCache = filtered
        _dedupCacheMicVersion = micV
        _dedupCacheSysVersion = sysV
        return filtered
    }
    @ObservationIgnored
    private var _dedupCache: [TranscriptSegment] = []
    @ObservationIgnored
    private var _dedupCacheMicVersion: Int = -1
    @ObservationIgnored
    private var _dedupCacheSysVersion: Int = -1

    @ObservationIgnored
    private var _displayCacheMicVersion: Int = -1
    @ObservationIgnored
    private var _displayCacheSysVersion: Int = -1

    /// Derived from `SystemAudioCapture.state` + the once-per-session
    /// denial flag set when preflight rejected us at start. UI binds
    /// to this for a "Other side: capturing / off" pill so users see
    /// mid-recording whether the remote party is actually being
    /// captured.
    var systemAudioStatus: SystemAudioStatus {
        // System audio is only meaningful in meeting mode. Voice
        // notes and dictation are personal-mic-only flows by design
        // — the user is the only voice that matters. start() skips
        // the SCStream wiring entirely for those modes, so
        // `systemAudio.state` stays at `.idle`, which would otherwise
        // fall through to the `.failed("Capture stopped unexpectedly")`
        // case below and surface a bogus warning for a recording
        // that is working exactly as intended. Map non-meeting modes
        // to `.disabled` so the status pill hides itself.
        guard currentMode == .meeting else { return .disabled }
        if !settings.captureSystemAudio { return .disabled }
        // Only meaningful once we're recording — before that
        // SystemAudioCapture sits in .idle which doesn't yet say
        // anything about runtime state.
        guard status == .recording || status == .paused else {
            return .pending
        }
        if systemAudioDeniedThisSession { return .denied }
        switch systemAudio.state {
        case .capturing, .starting, .paused:
            // SCStream is "running" but the silence monitor may have found
            // it's delivering NO usable audio (no buffers, or all silence —
            // denied permission, Bluetooth output, DRM, the Tahoe zero-
            // buffer glitch). Surface that as a failure so the user sees the
            // other side isn't actually being recorded, instead of a falsely
            // reassuring "capturing".
            if systemAudio.isSilentCaptureDetected {
                return .failed(systemAudio.lastError ?? "No audio is reaching Daisy from the other side")
            }
            return .capturing
        case .idle, .stopped:
            return .failed(systemAudio.lastError ?? "Capture stopped unexpectedly")
        }
    }

    // MARK: - Children

    // Module-internal so `SilenceMonitor` can read
    // `silencePromptsEnabled` without us threading an extra
    // reference through its constructor.
    let settings: AppSettings
    /// Microphone recorder — direct CoreAudio AUHAL capture. Stored as
    /// the concrete type (not an existential) so SwiftUI Observation
    /// tracks its `levelDB` / `spectrumBands` through the concrete
    /// `@Observable` class. (Previously selectable against a legacy
    /// AVAudioEngine `AudioRecorder` behind `useCoreAudioMicCapture`;
    /// that flag and backend were removed once CoreAudio was validated.)
    // internal for RecordingSession+AutoStop.swift / +ArchiveAudit.swift
    let recorder: CoreAudioMicRecorder
    // internal for RecordingSession+AutoStop.swift / +ArchiveAudit.swift
    let systemAudio: SystemAudioCapture
    // internal for RecordingSession+Finalize.swift / +Hotkeys.swift
    let log = Logger(subsystem: "app.essazanov.Daisy", category: "Session")
    /// Dedicated logger for auto-stop wire-up. Separate category so
    /// support can filter Console.app to the exact flow:
    ///   `subsystem:app.essazanov.Daisy category:AutoStop`
    /// Pre-1.0.4 every early-return in `scheduleAutoStopIfNeeded()` was
    /// silent, which is why a tester with the toggle ON but a manual
    /// start (no `boundMeeting`) looked indistinguishable from a wire
    /// bug. Now each abort logs which guard tripped.
    // internal for RecordingSession+AutoStop.swift
    let autoStopLog = Logger(subsystem: "app.essazanov.Daisy", category: "AutoStop")

    /// Security-scoped access ticket for the user-picked sessions
    /// folder, if one is configured. Acquired at start, released at
    /// stop/reset. Sandbox apps lose access to user-picked URLs once
    /// the matching `stopAccessing` runs, so keeping the ticket
    /// alive for the whole recording is required for the audio
    /// engine's writes to land.
    private var sessionsFolderTicket: SessionsFolder.AccessTicket?

    // Auto-stop stored state — internal for RecordingSession+AutoStop.swift
    // (the methods + tuning constants live there; the stored timers/flags
    // must stay on the class because extensions can't add storage).

    /// Schedule that fires the actual Stop & save at calendar end +
    /// grace. Lifecycle owned by start/stop/reset.
    var autoStopTimer: Timer?
    /// Schedule that fires 30s before `autoStopTimer` to give the
    /// user a Cancel-able warning toast.
    var autoStopWarningTimer: Timer?
    /// Set true when the user clicks "Keep going" on the warning
    /// toast — suppresses any further auto-stop attempts in this
    /// session (no point pestering them every 30s).
    var autoStopSuppressed: Bool = false

    /// Silence-gated auto-stop state (2026-06-01). Auto-stop no longer
    /// fires at a fixed endDate+grace; it waits for a quiet stretch past
    /// the scheduled end (or a hard maximum). `autoStopWarned` latches
    /// once the 30s warning + pending stop are armed; `autoStopLastAudibleAt`
    /// is the last time mic RMS or a fresh audible system buffer cleared the auto-stop gate.
    var autoStopWarned: Bool = false
    var autoStopLastAudibleAt: Date?
    /// Prompt-mode auto-stop snooze deadline ("10 / 30 more minutes"
    /// on the "Meeting seems over" banner). While set and in the
    /// future, `evaluateAutoStop` skips entirely; on expiry it clears
    /// this and un-latches `autoStopWarned` so the question can be
    /// asked again. Reset by `cancelAutoStop()` (stop/reset/re-arm).
    // internal for RecordingSession+AutoStop.swift
    var autoStopSnoozeUntil: Date?

    // ─── Low-disk guard (transcript-only fallback) ───────────────────
    /// True when this session is transcript-only because of low disk (set
    /// at start or after a mid-recording switch). Stops the disk monitor
    /// from firing twice.
    @ObservationIgnored
    private var diskTranscriptOnly = false

    /// True when this session writes NO audio archive on purpose — either
    /// the disk was too full at start (or ran critically low mid-way), or
    /// the user picked "Don't record audio" in Storage.
    ///
    /// Internal rather than private because `RecordingSession+ArchiveAudit`
    /// lives in another file and MUST consult it: with no archive open,
    /// both streams report zero frames written and zero write errors —
    /// byte-for-byte the signature of a dead recorder. Without this flag
    /// the audit calls a deliberate choice `.empty` / `.truncated`, the
    /// frontmatter records a failure that never happened, and the
    /// post-stop toast blames the user's headphones (2026-07-27 field
    /// report: four meetings, 0.4 GB free, "Bluetooth took over the mic"
    /// on wired headphones).
    var audioArchivingDisabled: Bool {
        diskTranscriptOnly
            || settings.audioRetentionDays == AppSettings.audioRetentionDoNotRecord
    }
    @ObservationIgnored
    private var diskMonitorTimer: Timer?
    // Both thresholds live in `DiskSpace` — HomeView's low-disk row and
    // LogReporter's `Disk:` line have to quote the SAME floor this
    // recorder acts on, or the warning and the behaviour disagree.
    /// Disk-space poll cadence while recording.
    private static let diskMonitorIntervalSec: TimeInterval = 45

    /// Live tier the active session STARTED with — the restore target once
    /// thermal/low-power pressure clears. Only Full sessions auto-downgrade.
    @ObservationIgnored
    private var startedLiveTier: LiveTranscriptionTier = .full
    /// True while a thermal/low-power auto-downgrade (Full→Lite) is in
    /// effect. Runtime only — never written to `settings.liveTranscriptionTier`.
    @ObservationIgnored
    private var thermalDowngradeActive = false
    @ObservationIgnored
    private var thermalObserver: NSObjectProtocol?
    @ObservationIgnored
    private var powerObserver: NSObjectProtocol?

    /// Active recording mode. Persists across pause/resume but
    /// resets to `.meeting` on `reset()` — fresh sessions default
    /// to the original Daisy meeting flow unless a mode-specific
    /// hotkey set `pendingMode` first.
    private(set) var currentMode: RecordingMode = .meeting

    /// How this session persists in the Library taxonomy: a `.voiceNote`
    /// is a NOTE, everything else (meetings) is a RECORDING. Stamped into
    /// transcript frontmatter as `daisy_kind:` (see MarkdownExporter) so
    /// the Library/Notes tabs can split by kind rather than by folder.
    /// `.dictation` never persists a StoredSession, so its mapping here is
    /// irrelevant (it falls in the `.recording` default, unused).
    var sessionKind: SessionKind {
        currentMode == .voiceNote ? .note : .recording
    }

    /// Mode the next `start()` should adopt. Set by mode-specific
    /// entry points (`toggleVoiceNoteByHotkey`, etc.) right before
    /// they call `start()`, consumed inside `start()` after
    /// `reset()`. Same pattern as `pendingBoundMeeting` —
    /// `reset()` clears the live value, the pending channel
    /// survives the wipe.
    @ObservationIgnored
    // internal for RecordingSession+Hotkeys.swift
    var pendingMode: RecordingMode?

    /// Calendar-driven meeting binding that should be applied to the
    /// session AFTER `start()` runs its internal `reset()` (which
    /// otherwise nukes the binding). Set by `startFromMeeting(_:)`
    /// just before it calls `start()`; consumed inside `start()` and
    /// cleared. This is the channel that makes calendar auto-stop
    /// actually work — without it, reset() blew away `boundMeeting`
    /// between the caller setting it and `scheduleAutoStopIfNeeded()`
    /// reading it, so the auto-stop timer was never armed.
    @ObservationIgnored
    private var pendingBoundMeeting: DaisyMeeting?

    /// Preparation companion to `pendingBoundMeeting`. It must cross the
    /// internal reset boundary through a pending channel for the same reason
    /// as the event itself.
    @ObservationIgnored
    private var pendingMeetingPreparation: MeetingPreparationSnapshot?

    /// Folder hint applied in the same after-reset() phase as
    /// `pendingBoundMeeting`. Used by calendar starts to default
    /// the new session into Work (instead of Inbox) without leaking
    /// state through `reset()`.
    @ObservationIgnored
    // internal for RecordingSession+Hotkeys.swift
    var pendingFolderHint: SessionFolder?

    /// What a `.prompt`-mode "Record" tap should start. Set by
    /// `promptToStartFromMeeting` / `promptToStartFromAppLaunch` when
    /// they surface the ask; consumed by the `recordRequested` handler.
    /// Held (not acted on) so the banner's yes/no decides whether the
    /// recording happens at all. A fresh trigger replaces an unanswered
    /// older one — only the most recent detected call is offered.
    enum PendingAutoStartTrigger {
        case calendar(DaisyMeeting)
        case appLaunch(String)   // pretty app name, for the banner subject
    }
    @ObservationIgnored
    private var pendingAutoStartTrigger: PendingAutoStartTrigger?

    /// Weak app-wide handle to the live session, set by `DaisyApp.init`.
    /// Lets the terminate handler (DaisyAppDelegate.applicationShouldTerminate)
    /// confirm + finalize an in-progress recording on Quit without plumbing
    /// the instance through the NSApplicationDelegateAdaptor. Weak so the
    /// app's `@State` reference remains the owner.
    static weak var current: RecordingSession?

    init(settings: AppSettings, localeIdentifier: String? = nil) {
        self.settings = settings
        // Caller can override (used by tests), otherwise pull the
        // user's chosen default from Settings → Transcription.
        // Empty / missing falls back to "auto" — the legacy
        // behaviour. Per-session override still works via the
        // popover locale picker, which writes through
        // `session.localeIdentifier`.
        let resolved = localeIdentifier ?? settings.defaultTranscriptionLocale
        let effective = resolved.isEmpty ? "auto" : resolved
        self.localeIdentifier = effective
        // Direct CoreAudio AUHAL mic capture — the sole capture backend.
        // (The legacy AVAudioEngine `AudioRecorder` and the
        // `useCoreAudioMicCapture` switch were removed once CoreAudio was
        // validated as the default.)
        self.recorder = CoreAudioMicRecorder()
        self.systemAudio = SystemAudioCapture()
        self.micTranscriber = Transcriber(
            localeIdentifier: effective,
            source: .microphone,
            // Opt-in mic-side diarization — useful when remote
            // participants are heard through the user's speakers
            // (in-room playback) instead of being captured separately
            // via system-audio loopback. See AppSettings comment.
            diarize: settings.diarizeMicrophone
        )
        self.systemTranscriber = Transcriber(
            localeIdentifier: effective,
            source: .systemAudio,
            // 2026-05-25 — diarization on the remote stream is now
            // user-gated via `settings.diarizeRemoteSpeakers`. Default
            // true preserves the historical per-voice clustering;
            // false collapses every system-audio segment to a single
            // "Remote" label (Granola-style two-side mode). Useful
            // for users hitting pyannote over-segmentation on
            // rapid-fire dialogue with similar voices.
            diarize: settings.diarizeRemoteSpeakers
        )
        self.summarizer = Summarizer.shared
        self.screenshots = ScreenshotCapture()
        self.silenceMonitor = nil  // assigned below once `self` is usable
        self.silenceMonitor = SilenceMonitor(session: self)

        // The loopback stream dying mid-meeting and failing to restart
        // is the same degradation as a denied preflight, arriving three
        // minutes later. `SystemAudioCapture` already warns; this makes
        // the session remember, so `daisy_mic_only:` lands in the
        // frontmatter and the Library says so afterwards. Silent — the
        // toast has already been shown by the capture itself. Weak:
        // the capture is owned by this session, so a strong capture
        // would be a retain cycle.
        self.systemAudio.onCaptureGaveUp = { [weak self] in
            self?.recordMicOnlyDegradation(cause: .systemAudioFailed)
        }

        // Preload the Whisper + diarization models so the first Record click
        // is instant. An XCTest bundle is hosted inside Daisy.app, however,
        // and must reach the test runner before app-startup model I/O begins.
        // Otherwise a slow or unavailable model volume can block every unit
        // test at "waiting for workers to materialize" without running one.
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isRunningTests {
            Task { await WhisperEngine.shared.ensureLoaded() }
            Task { await DiarizationEngine.shared.ensureLoaded() }
        }

        // 1.0.5.1 hotfix: REMOVED recorder.prewarm() — calling
        // AVAudioEngine.prepare() at app-init time crashes the
        // process on macOS 26.2 because the engine's input graph
        // isn't initializable until microphone permission is
        // granted AND the user actually intends to record. The
        // ObjC NSException AVAudioEngineGraph::Initialize threw
        // propagates straight through Swift and aborts the process
        // before SwiftUI even mounts. Cold-start lag is a worse
        // problem than no lag — but a crash on launch is worse
        // than both. Re-introduce gated on
        // `SystemPermissions.shared.microphone == .granted` in a
        // future release, or move prewarm to the first user-
        // initiated record() call where the engine state is sane.

        // Probe the configured summary provider once so its status
        // (Available / Unavailable) is known before the user opens
        // Settings → Summary for the first time. Without this, the
        // first visit to that tab shows "Checking…" for ~1s before
        // resolving.
        Task { await Summarizer.shared.refreshAvailability() }

        // Audio retention sweep — deletes raw .caf archives older
        // than the user-configured cutoff. No-op when
        // audioRetentionDays == 0 (default, preserves backwards-
        // compat). Runs detached on a background queue.
        AudioRetentionSweep.runIfNeeded(retentionDays: settings.audioRetentionDays)

        // Listen for the auto-start banner's "Stop & save" action.
        // DaisyAppDelegate routes the macOS notification action into
        // this Foundation bus; we run the same stop() the user would
        // get from the toolbar / widget. Observer is owned by the
        // singleton's lifetime — no removal needed.
        NotificationCenter.default.addObserver(
            forName: AutoStartNotification.stopRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.status == .recording || self.status == .paused else { return }
                self.log.info("Auto-start banner Stop & save tapped — stopping session")
                await self.stop()
            }
        }

        // Prompt-mode (policy = .prompt): the "Record this call?" banner's
        // Record / Ignore taps come back over the same Foundation bus.
        // Record consumes the pending trigger and starts it; Ignore drops
        // it. Same singleton-lifetime ownership as the observer above.
        NotificationCenter.default.addObserver(
            forName: AutoStartPromptNotification.recordRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.consumePendingAutoStartTrigger()
            }
        }
        NotificationCenter.default.addObserver(
            forName: AutoStartPromptNotification.ignoreRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.pendingAutoStartTrigger != nil {
                    self.log.info("Auto-start prompt ignored — dropping pending trigger")
                }
                self.pendingAutoStartTrigger = nil
            }
        }

        // Prompt-mode auto-stop (Settings → "Ask before auto-stopping"):
        // the "Meeting seems over" banner's actions come back over the
        // same Foundation bus. Stop & save runs the auto-stop now; the
        // snooze actions park the evaluator for 10 / 30 minutes. Same
        // singleton-lifetime ownership as the observers above.
        NotificationCenter.default.addObserver(
            forName: AutoStopPromptNotification.stopRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.performAutoStopFromPrompt()
            }
        }
        NotificationCenter.default.addObserver(
            forName: AutoStopPromptNotification.snooze10Requested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.snoozeAutoStop(minutes: 10)
            }
        }
        NotificationCenter.default.addObserver(
            forName: AutoStopPromptNotification.snooze30Requested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.snoozeAutoStop(minutes: 30)
            }
        }
    }

    // MARK: - Lifecycle

    // Hotkey / mode entry points (toggleByHotkey, toggleVoiceNoteByHotkey,
    // startDictationHotkey, stopDictationHotkey) live in
    // RecordingSession+Hotkeys.swift.

    /// Start a recording that is bound to a specific calendar event.
    /// The event's title pre-fills the session title, the transcript
    /// markdown carries the event id in frontmatter so we can match
    /// transcripts ↔ events later, and (if `settings.autoStopFromCalendar`
    /// is on) an auto-stop timer is armed for `meeting.endDate +
    /// autoStopGraceSec`. Defaults the folder to "Work" since most
    /// calendar meetings are work-context.
    ///
    /// Handles three cases:
    ///   1. **Idle/finished/failed** — fresh start, the simple path.
    ///   2. **Already recording the SAME event** — calendar tick polls
    ///      the +30/-120 s fire window every 15 s, so re-fires happen
    ///      naturally. No-op so we don't churn title/binding.
    ///   3. **Already recording a DIFFERENT event** — the back-to-back
    ///      meeting case that produced the tester's "M2 recorded into
    ///      M1's session" bug. Stop & save M1, cancel any in-flight
    ///      summary, then start M2 fresh. Surfaces a toast so the user
    ///      knows the rotation happened.
    ///
    /// The `pendingBoundMeeting` / `pendingFolderHint` channel matters
    /// here: a naive `boundMeeting = meeting` before `await start()`
    /// silently fails, because `start()` calls `reset()` internally
    /// which sets `boundMeeting = nil` (and the field never gets
    /// repopulated before `scheduleAutoStopIfNeeded()` reads it). The
    /// pending properties are picked up AFTER reset() and applied to
    /// the fresh session, which is what actually wires up auto-stop.
    func startFromMeeting(
        _ meeting: DaisyMeeting,
        preparation: MeetingPreparationSnapshot? = nil,
        userInitiated: Bool = false
    ) async {
        // Same event re-fired — no-op rather than stamping title/
        // binding on top of an already-running session. Checked BEFORE
        // the policy gate so a 15s calendar re-tick during an active
        // recording never re-prompts.
        if (status == .recording || status == .paused),
           boundMeeting?.localID == meeting.localID {
            return
        }

        // Prompt mode (policy = .prompt): don't start (or rotate) yet —
        // surface the "Record this call?" ask and let the user's tap
        // drive `performStartFromMeeting` via consumePendingAutoStartTrigger.
        // Applies whether idle or already recording a different meeting:
        // we never silently rotate in Prompt mode.
        if settings.autoStartPromptMode && !userInitiated {
            promptToStartFromMeeting(meeting)
            return
        }

        await performStartFromMeeting(meeting, preparation: preparation)
    }

    /// The actual calendar-bound start (and back-to-back rotation),
    /// bypassing the policy gate. Called directly by `startFromMeeting`
    /// in Always/Selective modes, and by `consumePendingAutoStartTrigger`
    /// when the user taps Record in Prompt mode.
    private func performStartFromMeeting(
        _ meeting: DaisyMeeting,
        preparation suppliedPreparation: MeetingPreparationSnapshot? = nil
    ) async {
        // Same event re-fired — no-op rather than stamping title/
        // binding on top of an already-running session.
        if (status == .recording || status == .paused),
           boundMeeting?.localID == meeting.localID {
            return
        }

        // Different event fired while we're still recording — auto-
        // rotate sessions. Without this branch, calendar trigger for
        // Meeting #2 silently returns and M1's session keeps running
        // with M1's bindings.
        if status == .recording || status == .paused {
            let oldTitle = self.boundMeeting?.title ?? self.title
            log.warning("Calendar fired \(meeting.title, privacy: .private) while still recording \(oldTitle, privacy: .private). Auto-rotating sessions.")
            ToastCenter.shared.show(
                String(localized: "Previous meeting saved — starting new session for \(meeting.title)."),
                style: .info
            )
            // Issue #7 (back-to-back meetings): the final pass spawned
            // by stop() is doomed on rotation — summaryTask?.cancel()
            // below always cancels it. But on the FIFO MainActor the
            // spawned task used to RUN FIRST (before the cancel), start
            // the non-cancellable Whisper inference on the shared
            // engine slot for minutes, and on return flip the shared
            // transcribers' isRunning off — killing the NEW session's
            // transcription while screenshots kept going ("second
            // meeting only captures the screen"). Tell stop() to skip
            // spawning it: deterministic, and M1 keeps exactly what it
            // kept before (the live transcript already on disk).
            skipFinalPassOnNextStop = true
            await stop()
        }

        // After stop() the post-Stop summary task may still be in
        // flight (status == .summarizing). Cancel it so the new
        // session's writes don't race against the old session's
        // summary.json write — transcript.md for the previous
        // meeting is already on disk; the user can re-summarize
        // from History if they need that summary.
        summaryTask?.cancel()
        summaryTask = nil

        // Bridge .summarizing → .finished so start()'s guard accepts
        // immediately rather than letting the rotation drop on the
        // floor.
        if status == .summarizing { status = .finished }

        guard status == .idle || status == .finished || isFailed else {
            log.warning("startFromMeeting aborted — unexpected state \(String(describing: self.status), privacy: .public)")
            return
        }

        // Stash for after-reset() pickup inside start(). Setting these
        // directly here would be erased by reset().
        pendingBoundMeeting = meeting
        let preparation = suppliedPreparation ?? savedPreparationSnapshot(for: meeting)
        pendingMeetingPreparation = preparation
        // Meetings file into the user's configured default folder (was
        // hardcoded `.work`); falls back to Inbox if that folder was
        // deleted. Applied in start() only when the session is still in
        // Inbox, so a manual folder pick still wins.
        let projectSlug = preparation?.projectSlug ?? settings.defaultMeetingFolderSlug
        pendingFolderHint = FolderStore.shared.existingFolder(slug: projectSlug) ?? .inbox
        // 2026-05-25: previously we set `title = meeting.title` here
        // because reset() didn't clear title. That created the bug
        // where a meeting's name leaked into a later voice-note
        // session days afterward (stale title sat in memory the whole
        // time). Now reset() clears title, and start()'s title-
        // generation block picks up `boundMeeting.title` directly when
        // the mode is meeting + a binding exists. No need to set
        // title here at all.

        await start()

        // Surface the fact that Daisy just auto-started — the user may
        // be anywhere on screen. Widget bubble first (2026-08-21:
        // system banners are being retired); info-only, no action — the
        // stop/discard affordances live in the widget the pill is
        // anchored to, and a whole-pill tap is an ACCEPT gesture we
        // don't want to mean "stop". Falls back to the actionable
        // banner when no panel host exists. Gated on the per-class
        // toggle in Settings → General → Notifications.
        if settings.notifyOnAutoStart {
            let shown = WidgetBubbleCenter.shared.show(WidgetBubbleContent(
                text: String(localized: "Recording started"),
                tag: "recording-started"
            ))
            if !shown {
                AutoStartNotification.post(meetingTitle: meeting.title)
            }
        }
    }

    /// Resolve a stored draft at the moment the recording actually starts.
    /// This matters for Prompt mode: the user may edit the preparation while
    /// the prompt is waiting, and the recording should capture that latest
    /// version rather than an earlier trigger-time copy.
    private func savedPreparationSnapshot(for meeting: DaisyMeeting) -> MeetingPreparationSnapshot? {
        let key = PreMeetingBriefStore.key(for: meeting)
        guard let draft = MeetingPreparationStore.shared.preparations[key] else { return nil }
        let briefSources: [String]
        if case .ready(let brief) = PreMeetingBriefStore.shared.state(for: meeting) {
            briefSources = brief.sourceSessionIDs
        } else {
            briefSources = []
        }
        return MeetingPreparationSnapshot(
            preparation: draft,
            briefSourceSessionIDs: briefSources
        )
    }

    // MARK: - Auto-start prompt (policy = .prompt)

    /// Stash a calendar meeting as the pending trigger and surface the
    /// "Record this call?" ask. The actual start happens only if the
    /// user taps Record (→ `consumePendingAutoStartTrigger`).
    private func promptToStartFromMeeting(_ meeting: DaisyMeeting) {
        pendingAutoStartTrigger = .calendar(meeting)
        log.info("Auto-start prompt: asking to record calendar meeting '\(meeting.title, privacy: .private)'")
        presentAutoStartAsk(fallbackSubject: meeting.title)
    }

    /// Entry point for the NSWorkspace app-launch detector — for EVERY
    /// policy, not just `.prompt` (2026-08-21). An app launch is a much
    /// weaker "meeting is happening" signal than a calendar event:
    /// opening Discord to type a message used to silently start a
    /// recording in Always mode (field log: 132 s of dead air the user
    /// only found by noticing the session). So app launches always ASK —
    /// via the widget bubble when the widget is on screen (immediate,
    /// over whatever app just launched), else the actionable
    /// notification. Calendar auto-start keeps its policy-driven
    /// behaviour untouched.
    func promptToStartFromAppLaunch(appName: String) {
        // If we're already recording, an app launch shouldn't prompt —
        // mirrors the old non-prompt app-launch path which just toasted.
        guard status == .idle || status == .finished || isFailed else {
            ToastCenter.shared.show(
                String(localized: "\(appName) launched while Daisy is already recording — stop the current session first if you want a fresh one."),
                style: .info
            )
            return
        }
        pendingAutoStartTrigger = .appLaunch(appName)
        log.info("Auto-start prompt: asking to record after \(appName, privacy: .public) launch")
        presentAutoStartAsk(fallbackSubject: appName)
    }

    /// Stable bubble tag for the "Start recording?" ask, so cancel
    /// paths can withdraw it without touching unrelated bubbles.
    static let autoStartAskBubbleTag = "autostart-ask"

    /// The one "Start recording?" surface, shared by the calendar
    /// prompt (policy = Ask me first) and the app-launch ask: widget
    /// bubble when the panel exists (anchored to the widget, or the
    /// bottom-right corner when it's hidden), else the actionable
    /// Record/Ignore banner. Deliberately word-light (Egor,
    /// 2026-08-21): no app/meeting name, just the question + record
    /// icon; the ✕'s countdown ring makes the window visible. A tap
    /// anywhere on the pill records.
    private func presentAutoStartAsk(fallbackSubject: String) {
        let shown = WidgetBubbleCenter.shared.show(WidgetBubbleContent(
            text: String(localized: "Start recording?"),
            actionTitle: String(localized: "Record"),
            actionSymbol: "record.circle",
            autoDismiss: 7,
            tag: Self.autoStartAskBubbleTag,
            action: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.consumePendingAutoStartTrigger()
                }
            }
        ))
        if shown {
            log.info("Auto-start prompt surface: bubble")
        } else {
            log.info("Auto-start prompt surface: notification (no bubble host)")
            AutoStartPromptNotification.post(subject: fallbackSubject)
        }
    }

    /// User tapped "Record" on the prompt — start whatever was pending.
    /// No-op (with a cancel of any stray banner) if the trigger is gone
    /// or we're somehow already recording, so a stale tap can't double-
    /// start or rotate unexpectedly.
    private func consumePendingAutoStartTrigger() async {
        AutoStartPromptNotification.cancel()
        WidgetBubbleCenter.shared.dismiss(tag: Self.autoStartAskBubbleTag)
        guard let trigger = pendingAutoStartTrigger else { return }
        pendingAutoStartTrigger = nil
        switch trigger {
        case .calendar(let meeting):
            // Re-use the full calendar path (binding, auto-stop arming,
            // back-to-back rotation) — just bypassing the prompt gate.
            await performStartFromMeeting(meeting)
        case .appLaunch:
            // Generic start, same as the Always/Selective app-launch path.
            guard status == .idle || status == .finished || isFailed else { return }
            await start()
        }
    }

    /// The microphone this session would actually bind to: the pinned
    /// device when it's still present, the system default otherwise
    /// (a pinned device that's been unplugged falls back, so judge the
    /// default in that case). Mirrors the first two steps of
    /// `CoreAudioMicRecorder.resolveInputDeviceID`.
    ///
    /// NOT the whole resolution. The recorder still steers away from a
    /// Bluetooth default, from the built-in mic in clamshell, and — the
    /// step that matters to the virtual-device warning below — from a
    /// default input that reports no live input streams, which is
    /// exactly how a virtual driver squatting the default slot gets
    /// bypassed. A caller that warns about this device has to re-check
    /// the same conditions, or it warns about a device the recording
    /// never touches.
    private func plannedInputDeviceID() -> AudioDeviceID {
        if !settings.selectedMicDeviceUID.isEmpty,
           let pinned = AudioInputDevices.deviceID(forUID: settings.selectedMicDeviceUID) {
            return pinned
        }
        return AudioInputDevices.systemDefaultInputID()
    }

    /// True when the microphone this session would actually bind to is
    /// the Mac's built-in one — the device that goes hardware-silent
    /// with the lid closed.
    private func plannedInputIsBuiltIn() -> Bool {
        AudioInputDevices.isBuiltIn(plannedInputDeviceID())
    }

    /// Device UIDs already warned about this launch. A set, not one
    /// slot: someone who alternates between two virtual inputs would
    /// otherwise be re-warned every time they switch back.
    @ObservationIgnored
    private var virtualInputWarnedUIDs: Set<String> = []

    /// Note it in the log, and say it once, when the microphone we're
    /// about to record from is another app's virtual audio device that
    /// isn't carrying real mic audio (BlackHole, Loopback, a capture
    /// sink left selected after a screen recording).
    ///
    /// Soft on purpose. Routing a meeting through a virtual device can
    /// be exactly what the user set up, so this neither blocks the start
    /// nor switches the device — unlike the clamshell and Bluetooth
    /// paths, where the silence is a certainty rather than a risk. What
    /// it buys is the link between "the recording was empty" and the
    /// driver that made it so: the log line lands on every start (the
    /// evidence a report needs), the visible warning only on the first
    /// start per device per launch (the nudge a user needs).
    ///
    /// Three gates before we say anything, each one a way of not crying
    /// wolf:
    ///  • mic pass-through drivers (Krisp, Wave Link, eqMac…) are
    ///    excluded by the signature table — they deliver real
    ///    microphone audio and are a working setup, not a fault;
    ///  • a device with no live input streams or zero input channels is
    ///    one `CoreAudioMicRecorder` never binds to — its default-input
    ///    fallback exists precisely for a virtual driver squatting that
    ///    slot — so the recording lands on a real mic and the warning
    ///    would be about a device we already stepped around;
    ///  • no readable device name means no sentence worth showing —
    ///    "pick your microphone" is only actionable when we can say
    ///    which one is wrong. The log line still goes out.
    ///
    /// Surfaces: the widget bubble FIRST, then the toast. Dictation is
    /// triggered by hotkey from another app, where an in-window toast is
    /// invisible — and dictation is often the first recording of a
    /// launch, so a toast-only warning would burn the once-per-launch
    /// budget on something nobody saw. No `CaptureProblemNotification`
    /// though: a system banner for a setup the user may well have chosen
    /// is nagging, and this is a "if it comes out empty, here's why"
    /// hint, not "Daisy can't hear you".
    private func warnIfPlannedInputIsVirtual() {
        let deviceID = plannedInputDeviceID()
        guard AudioInputDevices.virtualInputMayBeSilent(deviceID) else { return }
        log.warning("Planned input is a third-party virtual audio device — capture may be silent or routed elsewhere. \(AudioInputDevices.describe(deviceID), privacy: .public)")
        guard AudioInputDevices.hasInputStreams(deviceID),
              AudioInputDevices.inputChannelCount(deviceID) > 0 else {
            log.info("Virtual input reports no live input channels — the recorder won't bind to it, so not warning the user")
            return
        }
        guard let deviceName = AudioInputDevices.name(for: deviceID) else { return }
        let uid = AudioInputDevices.uid(for: deviceID) ?? deviceName
        guard virtualInputWarnedUIDs.insert(uid).inserted else { return }
        let message = String(localized: "The microphone is set to “\(deviceName)” — a virtual audio device. If the recording comes out empty, pick your microphone in Settings.")
        _ = WidgetBubbleCenter.shared.show(
            WidgetBubbleContent(text: message, autoDismiss: 12, tag: Self.virtualInputBubbleTag)
        )
        ToastCenter.shared.showAction(
            message,
            actionLabel: String(localized: "Open audio settings"),
            style: .warning,
            duration: .seconds(12)
        ) {
            AppNavigation.shared.openInSettings(.recording)
        }
    }

    /// Tag for the virtual-input bubble, so it can never be withdrawn by
    /// another prompt's `dismiss(tag:)`.
    private static let virtualInputBubbleTag = "virtual-input-warning"

    /// Set when `start()` already warned about a closed lid, so the
    /// silence watchdog 10 s later doesn't repeat the same toast.
    @ObservationIgnored
    var clamshellWarned = false

    /// Toast for "we can't record because macOS won't give us the mic".
    /// Actionable — the deep link lands the user exactly where the
    /// switch is, instead of leaving them to hunt through Settings.
    private func showMicBlockedToast() {
        ToastCenter.shared.showAction(
            String(localized: "Daisy can’t hear your microphone — access is turned off in System Settings."),
            actionLabel: String(localized: "Open Microphone settings"),
            style: .warning,
            duration: .seconds(30)
        ) {
            SystemPermissions.shared.openMicrophoneSettings()
        }
    }

    func start() async {
        // Stored-audio re-transcription temporarily owns the shared
        // Whisper engine and can load a second CoreML graph. Starting a
        // live capture in the middle of that job would make both workflows
        // compete for the same serialized decoder and memory budget.
        guard !SessionAudioProcessing.shared.isRunning else {
            ToastCenter.shared.show(
                String(localized: "Wait for stored audio processing to finish."),
                style: .info
            )
            return
        }

        // If a previous Stop's summary task is still in flight, the
        // user has explicitly asked for a NEW recording — drop the
        // old finalize. transcript.md is already on disk (synchronous
        // path in stop()), so the worst case is that summary.json
        // and any auto-send to Notion/MCP haven't landed yet for the
        // previous session; the user can fix that from History →
        // Re-summarize. Fire-and-forget cancel: we don't await the
        // task value, the new recording shouldn't wait on the LLM.
        summaryTask?.cancel()
        summaryTask = nil

        guard status == .idle || status == .finished || isFailed else { return }

        // A discard flag left over from a previous take. Cleared HERE and
        // not in `reset()`: reset runs in the middle of this function,
        // after `startDictationHotkey` has already claimed a screenshot
        // note, so clearing it there would swallow a trash press made
        // while this very session was still starting up.
        screenshotNoteDiscarded = false

        // Microphone preflight — FIRST, before any state is allocated
        // (2026-07-26). The Screen Recording path further down has
        // always gated on TCC; the mic path never did, so a denied or
        // never-asked mic produced a "successful" capture full of
        // digital silence with no user-visible clue. Deliberately
        // placed above `reset()`/`makeSessionDirectory()` so bailing
        // out here leaves no half-built session folder or `.recording`
        // marker behind.
        switch SystemPermissions.micAuthorization() {
        case .notDetermined:
            log.warning("Mic permission notDetermined at capture start — prompting")
            await SystemPermissions.shared.requestMicrophone()
            if SystemPermissions.micAuthorization() != .authorized {
                showMicBlockedToast()
                return
            }
        case .denied, .restricted:
            log.error("Mic permission is \(SystemPermissions.micAuthorizationDescription(), privacy: .public) — refusing to start a silent recording")
            showMicBlockedToast()
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        // Clamshell preflight (Egor, 2026-07-26). Lid closed + the
        // device we'd actually bind to is the built-in mic + nothing
        // external to switch to = a guaranteed silent session. Say so
        // BEFORE recording rather than after the 10-second watchdog,
        // and say it as a system notification too: a dictation
        // triggered by hotkey from another app never sees an in-app
        // toast (ToastOverlay lives in the main window).
        //
        // Gate on the PLANNED device, not just "unpinned": a user on
        // AirPods records fine with the lid shut (their mic isn't the
        // built-in one), while a user who explicitly pinned the
        // built-in mic is silent and deserves the same warning.
        clamshellWarned = false
        if AudioInputDevices.isLidClosed(),
           plannedInputIsBuiltIn(),
           AudioInputDevices.firstExternalWiredInputID() == nil {
            log.warning("Lid closed and the planned input is the built-in mic with no external alternative — capture will be silent")
            clamshellWarned = true
            CaptureProblemNotification.post(
                title: String(localized: "Daisy can’t hear you"),
                body: String(localized: "The lid is closed, so the Mac’s built-in microphone is off. Open the lid or connect an external mic.")
            )
            ToastCenter.shared.show(
                String(localized: "The lid is closed — the built-in microphone is off in clamshell mode. Open the lid or connect an external mic."),
                style: .warning
            )
        }

        // Virtual-input preflight (2026-08-25). Sits next to the
        // clamshell check because it answers the same question one step
        // later — not "can macOS give us the mic" but "is the thing it
        // hands us a microphone at all". Warns, never blocks: see
        // `warnIfPlannedInputIsVirtual`.
        warnIfPlannedInputIsVirtual()

        reset()

        // Cleared HERE and not inside `reset()`: the value has to
        // survive every reset that happens between Stop and the last
        // write of transcript.md (the Stage-3 re-render in
        // `finalizePostStop` reads it), so the one safe moment to zero
        // it is the start of the NEXT recording. Same lifecycle as
        // `systemAudioDeniedThisSession`, and cleared before the session
        // directory below can be claimed, so a new session can never
        // inherit the previous one's reason.
        micOnlyCause = nil

        // Apply meeting/folder/mode bindings stashed by entry-point
        // helpers (`startFromMeeting`, `toggleVoiceNoteByHotkey`,
        // `toggleDictationByHotkey`). These need to land AFTER
        // reset() — reset clears boundMeeting/folder/currentMode
        // back to defaults — otherwise `scheduleAutoStopIfNeeded`
        // sees `boundMeeting == nil`, and `finalizePostStop` runs
        // the meeting pipeline against what should have been a
        // dictation session.
        if let m = pendingBoundMeeting {
            boundMeeting = m
            pendingBoundMeeting = nil
            // Auto-suggest client tag from attendee domains. The
            // user can override in SessionDetailView; this just
            // pre-fills with a sensible guess so most meetings end
            // up tagged without any manual work.
            if tag.isEmpty, let suggested = TagSuggestion.suggest(from: m.attendeeEmails) {
                tag = suggested
            }
        }
        if let preparation = pendingMeetingPreparation {
            meetingPreparationSnapshot = preparation
            pendingMeetingPreparation = nil
            // Explicit preparation wins over automatic folder/tag hints.
            folder = FolderStore.shared.existingFolder(slug: preparation.projectSlug) ?? .inbox
            tag = preparation.tag
        }
        if let hint = pendingFolderHint {
            if meetingPreparationSnapshot == nil, folder == .inbox { folder = hint }
            pendingFolderHint = nil
        }
        if let mode = pendingMode {
            currentMode = mode
            pendingMode = nil
        } else {
            currentMode = .meeting
        }

        // Voice notes are no longer FORCED into the Notes folder: a note
        // is now identified by `daisy_kind: note` (RecordingSession.
        // sessionKind, written by MarkdownExporter) and can live in any
        // project just like a recording. A fresh voice note therefore
        // stays in the default Inbox (or whatever folder a UI pick /
        // calendar hint chose), and the Notes tab finds it by kind, not
        // by folder. Dictation sessions are ephemeral (no History entry),
        // so their folder value is irrelevant either way.

        // Apply mode-specific transcription locale override, falling
        // back to the meeting default. Empty string in the override
        // means "inherit". Pre-1.0.3 dictation/voice-note always used
        // `defaultTranscriptionLocale`, which auto-detected English
        // for a clearly Russian dictation if the early few seconds
        // were ambiguous — user reported "Я диктовал на русском, а
        // он перевёл на английский".
        let modeLocale: String
        switch currentMode {
        case .meeting:
            modeLocale = settings.defaultTranscriptionLocale
        case .voiceNote:
            modeLocale = settings.voiceNoteLocale.isEmpty
                ? settings.defaultTranscriptionLocale
                : settings.voiceNoteLocale
        case .dictation:
            modeLocale = settings.dictationLocale.isEmpty
                ? settings.defaultTranscriptionLocale
                : settings.dictationLocale
        }
        let effectiveLocale = modeLocale.isEmpty ? "auto" : modeLocale
        if localeIdentifier != effectiveLocale {
            localeIdentifier = effectiveLocale
        }

        if title.isEmpty {
            // Calendar-bound sessions take the EVENT's name. This is
            // the pickup the 2026-05-25 note in performStartFromMeeting
            // promised ("start()'s title-generation block picks up
            // boundMeeting.title directly") — it was never actually
            // wired, so auto-started meetings showed the placeholder
            // "Meeting yyyy-MM-dd HH:mm" instead of the calendar
            // title (tester report, 2026-06-12).
            if currentMode == .meeting,
               let boundTitle = boundMeeting?.title,
               !boundTitle.isEmpty {
                title = boundTitle
            } else {
                // Mode-aware default title. Pre-1.0.6.3 every session
                // (meeting, voice note, dictation) got the "Meeting …"
                // prefix regardless of `currentMode`, which made voice
                // notes look like miscategorised meetings in the
                // History sidebar. Now the title reflects what the
                // session actually is — the user's expectation when
                // they tap the voice-notes hotkey is a Library entry
                // that reads "Voice note", not "Meeting".
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH:mm"
                let prefix: String
                switch currentMode {
                case .meeting:   prefix = "Meeting"
                case .voiceNote: prefix = "Voice note"
                case .dictation: prefix = "Dictation"
                }
                title = "\(prefix) \(f.string(from: Date()))"
            }
        }

        status = .preparing

        // First-record explainer toast.
        //
        // If Whisper isn't yet `.ready`, the user is about to wait
        // 1-3 minutes while the 626 MB model downloads + CoreML loads.
        // The widget centre + tooltip surface the live progress, but
        // a one-shot toast at the moment of click gives the user a
        // concrete "how long" so they don't think the app is hung.
        // Skip the toast when prewarm has already finished — most
        // sessions land in `.ready` here, and a "model is loading"
        // toast on a sub-second startup would be noise.
        switch WhisperEngine.shared.state {
        case .notLoaded, .downloading, .loading:
            ToastCenter.shared.show(
                String(localized: "Setting up transcription model — first run only, about 1–3 minutes"),
                style: .info
            )
        case .ready, .failed:
            break
        }

        // Make sure Whisper is ready before we tap the mic — otherwise the
        // user sees "Recording…" with nothing happening. Each early-exit
        // path below goes through `failFast(_:)` so we don't leak the
        // sandbox ticket from `makeSessionDirectory()` or the half-
        // started transcribers — pre-1.0.3 these `return`s left
        // `sessionsFolderTicket` retained until the next start/reset.
        await WhisperEngine.shared.ensureLoaded()
        // Cold-restart race: the very first model load right after an app
        // restart can briefly land not-ready or transiently failed, which
        // surfaced as a red "Try again" button that just works on the second
        // tap (Egor 2026-06-16). Auto-do that retry — up to twice, letting
        // the in-flight load settle between attempts (a second ensureLoaded
        // re-runs performLoad once the first task has cleared). Only the
        // not-ready path pays this; a warm engine skips it entirely.
        var whisperRetries = 0
        while !WhisperEngine.shared.isReady && whisperRetries < 2 {
            whisperRetries += 1
            try? await Task.sleep(for: .milliseconds(300))
            await WhisperEngine.shared.ensureLoaded()
        }
        if case .failed(let msg) = WhisperEngine.shared.state {
            await failFast(String(localized: "Whisper model failed to load: \(msg)"))
            return
        }
        guard WhisperEngine.shared.isReady else {
            await failFast(String(localized: "Whisper model isn't ready yet — try again in a moment."))
            return
        }

        // Session directory for archive + screenshots.
        let dir: URL?
        do { dir = try makeSessionDirectory() }
        catch {
            log.error("Session dir failed: \(error.localizedDescription, privacy: .public)")
            dir = nil
        }
        sessionDirectory = dir
        if let dir, let preparation = meetingPreparationSnapshot {
            do {
                try preparation.write(to: dir)
            } catch {
                // Recording remains usable even if this lightweight context
                // sidecar cannot be written; surface the loss instead of
                // aborting microphone capture.
                log.error("Meeting preparation sidecar failed: \(error.localizedDescription, privacy: .public)")
                ToastCenter.shared.show(
                    String(localized: "Couldn’t save the meeting preparation with this recording."),
                    style: .warning
                )
            }
        }
        // Fresh session, fresh markers. Resume keeps them (this runs on
        // start only) — a mark made before a pause still points at the
        // same media time afterwards.
        momentMarkers = []

        // Tell SessionStore which visible folder is live. Refresh can show it,
        // but interrupted-recording recovery and every bulk-delete path must
        // leave the open `.caf` descriptors alone until Stop finishes.
        SessionStore.shared.activeRecordingDirName = dir?.lastPathComponent

        // Pattern (d) per the 2026-05-28 competitor research:
        // when audioRetentionDays == audioRetentionDoNotRecord (-2),
        // skip the on-disk .caf archives entirely. AVAudioFile is
        // never opened on the mic tap, SCStream's archiveWriter is
        // never lazy-opened on the system-audio path. Whisper still
        // gets full audio via the live AsyncStream<AudioChunk>
        // continuations so transcript quality is unaffected — only
        // the disk artifact is gone. Strongest privacy posture in
        // the Storage picker; the trade-off is no crash-recovery
        // (if Daisy goes away mid-meeting, transcript is lost too)
        // and no "re-summarize with a better model" after the fact.
        let skipForRetention = settings.audioRetentionDays == AppSettings.audioRetentionDoNotRecord
        // Low-disk guard (2026-06-01, Egor's "auto + notify"): if the volume
        // is below the start threshold, record TRANSCRIPT-ONLY this session —
        // audio is the heavy part (~0.7 GB/hr) and would fill the disk. Reuses
        // the same skip-archive path as the "Don't record audio" retention
        // mode (Whisper still gets full audio via the live stream).
        let freeAtStart = Self.freeDiskBytes(at: dir)
        let lowDiskAtStart = !skipForRetention && (freeAtStart ?? .max) < DiskSpace.recordingFloorBytes
        diskTranscriptOnly = lowDiskAtStart
        let skipAudioArchive = skipForRetention || lowDiskAtStart
        let micArchive = skipAudioArchive ? nil : dir?.appendingPathComponent("microphone.caf")
        let systemArchive = skipAudioArchive ? nil : dir?.appendingPathComponent("system_audio.caf")
        if lowDiskAtStart {
            let freeGB = Double(freeAtStart ?? 0) / 1_073_741_824
            ToastCenter.shared.show(
                String(format: String(localized: "Low disk space (%.1f GB free) — recording transcript only this session, no audio. Free up space to record audio again."), freeGB),
                style: .warning,
                duration: .seconds(6)
            )
            log.warning("Low disk at start (\(freeAtStart ?? -1, privacy: .public) bytes free) — transcript-only session")
        }

        let nowStarted = Date()

        // P1 — write the in-progress marker so a crash / power-loss leftover
        // is recognised as a recoverable recording on next launch. Only when
        // we're actually archiving audio: in the
        // no-audio retention mode there's nothing on disk to recover.
        if !skipAudioArchive, let dir {
            try? Data(ISO8601DateFormatter().string(from: nowStarted).utf8)
                .write(to: dir.appendingPathComponent(SessionStore.recordingMarkerName))
        }

        // Wire mic. Build 43: `liveTranscription` propagated from
        // AppSettings — when OFF, the transcriber accumulates audio
        // for `runFinalPass()` but doesn't fire per-window Whisper
        // commits during the meeting. Dictation mode forces live ON
        // regardless of the setting because dictation IS the live
        // transcript (paste happens on hotkey release).
        // Dictation IS the live transcript, so it always runs live at Full
        // regardless of the meeting tier; otherwise honour the user's tier.
        let tier: LiveTranscriptionTier = currentMode == .dictation ? .full : settings.liveTranscriptionTier
        let micAudio = recorder.buffers
        // EXPERIMENTAL (dark): streaming Nemotron live preview for
        // dictation — replaces the Whisper live timer for this session
        // only; the pasted final text is unchanged. See NemotronLiveEngine.
        micTranscriber.dictationNemotronLive =
            currentMode == .dictation && settings.dictationUseNemotronLive
        // Live word-by-word caption for dictation on the Apple engine —
        // the native-macOS-dictation experience (Egor, 2026-08-29),
        // rendered on the widget's caption pill. The flag routes the
        // live path through AppleSpeechLiveEngine; the sink carries the
        // running text out. Both are no-ops unless every gate holds
        // (macOS 26, concrete locale, model installed) — any miss keeps
        // today's behaviour: Whisper live, no caption, unchanged paste.
        micTranscriber.dictationAppleLive =
            currentMode == .dictation && settings.dictationEngine == .appleSpeech
        micTranscriber.onDictationLiveText = currentMode == .dictation
            ? { text in WidgetBubbleCenter.shared.updateLiveCaption(text) }
            : nil
        micTranscriber.start(consuming: micAudio, startedAt: nowStarted, tier: tier)
        do {
            try recorder.start(
                archiveURL: micArchive,
                preferredDeviceUID: settings.selectedMicDeviceUID,
                noiseSuppressionEnabled: settings.microphoneNoiseSuppressionEnabled
            )
        } catch {
            await failFast(error.localizedDescription)
            return
        }
        micArchiveURL = recorder.archivedFileURL

        // Wire system audio (optional).
        //
        // Two failure modes used to be silent:
        //   1. Screen Recording permission is denied — `SCStream.
        //      startCapture()` throws, we logged it, the user kept
        //      talking, only their voice ended up in the transcript.
        //   2. Permission is granted but the stream errored out
        //      mid-start (display gone, etc.) — same silent fall-
        //      through.
        // Both now produce a visible toast (the deny case includes
        // an "Open Privacy Settings" deeplink) so the user finds out
        // BEFORE the meeting, not after.
        systemAudioDeniedThisSession = false
        // Voice notes and dictation are personal-mic-only flows —
        // the user is the only voice that matters. Skip the
        // SCStream loopback entirely so we don't ask for Screen
        // Recording permission on first dictation use and don't
        // burn CPU on a 2×2 video stream we'll throw away.
        if settings.captureSystemAudio && currentMode == .meeting {
            // Preflight TCC. `CGPreflightScreenCaptureAccess()`
            // doesn't itself prompt — calling SCK without checking
            // would prompt mid-startCapture, but if the user
            // already denied once we'd skip straight to "throw".
            //
            // `preflight()` rather than `isGranted`: same verdict, but it
            // also stamps "we saw the grant in place at this moment",
            // which is what turns a later `denied` in a log report into
            // evidence of a TCC reset instead of an unanswerable
            // question (macOS 27.0 beta, 2026-08-21).
            //
            // The gate belongs to the ScreenCaptureKit backend. The P1-6
            // process-tap spike captures below the window server and asks
            // for its own, narrower permission ("System Audio Recording"),
            // so demanding Screen Recording there would refuse a path that
            // doesn't need it — and its denial can't be preflighted at all
            // (Core Audio reports no error; the silent-content monitor
            // inside SystemAudioCapture is what catches it).
            if !SystemAudioCapture.usesProcessTapBackend,
               !ScreenRecordingPermission.preflight() {
                systemAudioDeniedThisSession = true
                log.warning("Screen Recording permission denied — recording mic only")
                noteMicOnlyDegradation(cause: .screenRecordingDenied)
            } else {
                let systemAudioStream = systemAudio.buffers
                systemTranscriber.start(consuming: systemAudioStream, startedAt: nowStarted, tier: tier)
                do {
                    try await systemAudio.start(archiveURL: systemArchive)
                    systemArchiveURL = systemArchive
                } catch {
                    log.error("System audio start failed: \(error.localizedDescription, privacy: .public)")
                    systemTranscriber.reset()
                    systemArchiveURL = nil
                    // Loud fail — previously swallowed in os_log.
                    // The user is about to start a meeting; they
                    // need to know the remote side won't be
                    // captured.
                    noteMicOnlyDegradation(cause: .systemAudioFailed)
                }
            }
        }

        startedAt = nowStarted
        status = .recording
        installThermalDowngrade(startedTier: tier)
        if settings.recordingSoundsEnabled { SoundEffects.playStart(for: currentMode) }

        // Optional screenshots.
        if settings.screenshotsEnabled, let dir {
            let screenshotsDir = dir.appendingPathComponent("screenshots", isDirectory: true)
            await screenshots.start(
                intervalSec: settings.screenshotIntervalSec,
                elapsed: { [weak self] in self?.elapsed ?? 0 },
                into: screenshotsDir
            )
        }

        // Manual-start fallback: if the user hit the hotkey before
        // CalendarService.tick() got to auto-start, try to match the
        // session to a currently-running meeting so auto-stop still
        // arms. No-op if `boundMeeting` is already set (auto-start
        // path).
        bindCurrentMeetingIfPossible()

        // Calendar-bound sessions can opt into auto-stop at end+grace.
        scheduleAutoStopIfNeeded()
        silenceMonitor.start()
        startDiskMonitor()
    }

    /// Remember that this meeting is microphone-only. Silent and
    /// idempotent — first cause wins, because a denied preflight
    /// explains the session better than the resume failure it goes on
    /// to cause.
    ///
    /// The recording half is separate from the warning half on purpose:
    /// `SystemAudioCapture` already warns, in its own words, when the
    /// stream dies mid-meeting and the restart budget runs out. That
    /// path needs the session to REMEMBER without a second toast landing
    /// on top of the first.
    ///
    /// What remembering buys: `micOnlyCause` rides into the transcript
    /// frontmatter and the Library detail, so the answer to "why does
    /// this recording only have my voice in it" is still there next
    /// week. A toast lasts seconds; the two mic-only meetings on
    /// 1.0.7.61 were diagnosed days later, from nothing.
    func recordMicOnlyDegradation(cause: MicOnlyCause) {
        // Dictation and voice notes are mic-only BY DESIGN and never arm
        // the loopback stream, so "microphone only" is not news there —
        // it's the feature. Guarding here rather than at each call site
        // keeps a future caller from stamping a voice note as degraded.
        guard currentMode == .meeting else { return }
        guard micOnlyCause == nil else { return }
        micOnlyCause = cause
        log.warning("Session degraded to microphone-only: \(cause.rawValue, privacy: .public)")
        ScreenRecordingPermission.noteMicOnlySession(cause: cause)
    }

    /// Record it AND tell the user, once per session.
    ///
    /// Three call sites: a denied preflight, an SCStream that wouldn't
    /// start, and one that wouldn't resume after a pause — the last of
    /// which used to fail silently. The warning fires only when the
    /// cause is NEW, so a stream that failed at start and then fails
    /// again on every resume doesn't re-toast.
    ///
    /// The warning also leaves the main window. The paths that hit this
    /// most often are the ones the user didn't press — calendar
    /// auto-start, the app-launch ask — and by then they are looking at
    /// Zoom, where `ToastCenter` renders nothing at all. Same
    /// bubble-first / banner-fallback surface the clamshell warning
    /// uses, which is also why it yields to that one: they share a
    /// single notification slot, and "the lid is shut, nothing is being
    /// recorded" outranks "half of it is".
    ///
    /// Deliberately NOT a hard stop — the user is on the doorstep of a
    /// meeting, and mic-only beats nothing at all (P0-2, 2026-08-25).
    private func noteMicOnlyDegradation(cause: MicOnlyCause) {
        let before = micOnlyCause
        recordMicOnlyDegradation(cause: cause)
        // Warn only when THIS call is the one that recorded the cause:
        // no second toast for a repeat failure, and nothing at all in
        // the modes `recordMicOnlyDegradation` declines to mark.
        guard before == nil, micOnlyCause != nil else { return }

        let notificationBody: String
        switch cause {
        case .screenRecordingDenied:
            ToastCenter.shared.showAction(
                String(localized: "Couldn't capture the other side — Screen Recording permission is off. Recording your voice only."),
                actionLabel: String(localized: "Open Privacy Settings"),
                style: .warning,
                duration: .seconds(20),
                perform: { ScreenRecordingPermission.openSystemSettings() }
            )
            notificationBody = String(localized: "Screen Recording permission is off, so Daisy can’t capture the other side of this call. Turn it on in System Settings → Privacy & Security → Screen Recording.")
        case .systemAudioFailed:
            ToastCenter.shared.show(
                String(localized: "Couldn't capture the other side — recording your voice only."),
                style: .warning
            )
            notificationBody = String(localized: "Daisy couldn’t capture the other side of this call. Your microphone is still being recorded.")
        }

        // `CaptureProblemNotification` is a single slot — one request id,
        // one bubble tag — so posting here would REPLACE the clamshell
        // warning raised moments earlier in the same `start()`. On a
        // docked Mac with the lid shut and Screen Recording off, that
        // would swap "Daisy can't hear you" for "recording your voice
        // only", which is worse than useless: it isn't recording a voice
        // at all. The in-app toast above still fires either way.
        guard !clamshellWarned else { return }
        CaptureProblemNotification.post(
            title: String(localized: "Recording your voice only"),
            body: notificationBody
        )
    }

    // Auto-stop (calendar-bound) — scheduleAutoStopIfNeeded,
    // bindCurrentMeetingIfPossible, cancelAutoStop and the silence-gated
    // evaluator live in RecordingSession+AutoStop.swift.

    // MARK: - Low-disk guard (auto transcript-only)

    private func startDiskMonitor() {
        stopDiskMonitor()
        diskMonitorTimer = Timer.scheduledTimer(
            withTimeInterval: Self.diskMonitorIntervalSec, repeats: true
        ) { [weak self] _ in
            // Rebind to a strong `let` so the Task captures by value —
            // otherwise Swift 6 flags the captured `weak self` var crossing
            // the concurrency boundary (same pattern as the auto-stop timers).
            guard let self else { return }
            Task { @MainActor in self.checkDiskSpace() }
        }
    }

    private func stopDiskMonitor() {
        diskMonitorTimer?.invalidate()
        diskMonitorTimer = nil
    }

    /// Why this recording came out with nothing usable, in the user's
    /// terms. Ordered by what the user can act on FIRST, and each branch
    /// only claims what we actually measured:
    ///
    ///  1. Disk ran out → Daisy chose transcript-only, so there is no
    ///     audio to fall back on and the empty live transcript is the
    ///     whole story. Nothing to do with hardware.
    ///  2. User turned audio recording off in Storage → same shape, but
    ///     it's their setting, not a problem to fix.
    ///  3. A Bluetooth device is actually on the route → the original
    ///     AirPods failure mode, and now only stated when a BT device is
    ///     really there.
    ///  4. Otherwise → say what we know and point at the input device
    ///     rather than inventing a cause.
    private func captureFailureMessage() -> String {
        if diskTranscriptOnly {
            return String(localized: "Not enough disk space, so this meeting was recorded without audio — and the live transcript came out empty, so no summary was made. Free up space and the audio comes back.")
        }
        if settings.audioRetentionDays == AppSettings.audioRetentionDoNotRecord {
            return String(localized: "Audio recording is off in Settings → Privacy, and the live transcript came out empty, so no summary was made. There's no audio file to fall back on in this mode.")
        }
        if AudioInputDevices.isBluetooth(AudioInputDevices.systemDefaultOutputID())
            || AudioInputDevices.isBluetooth(AudioInputDevices.systemDefaultInputID()) {
            return String(localized: "This recording captured almost no audio — a Bluetooth headset (e.g. AirPods) likely took over the mic and system audio. The transcript is empty or unreliable, so no summary was generated. Use the built-in mic and speakers for meetings.")
        }
        return String(localized: "This recording captured almost no audio, so the transcript is unreliable and no summary was made. Check that the right microphone is selected and that other-side audio is being captured.")
    }

    /// Mid-recording low-disk guard. If free space drops below the critical
    /// floor while we're still archiving audio, auto-switch to transcript-only
    /// (stop both archives, keep transcribing) + notify — Egor's 2026-06-01
    /// "auto + notify" choice. Fires once; self-terminates once recording ends.
    private func checkDiskSpace() {
        guard status == .recording else { stopDiskMonitor(); return }
        guard !diskTranscriptOnly,
              settings.audioRetentionDays != AppSettings.audioRetentionDoNotRecord,
              let free = Self.freeDiskBytes(at: sessionDirectory),
              free < DiskSpace.criticalFloorBytes
        else { return }
        diskTranscriptOnly = true
        recorder.stopArchivingKeepTranscribing()
        systemAudio.stopArchivingKeepTranscribing()
        let freeGB = Double(free) / 1_073_741_824
        ToastCenter.shared.show(
            String(format: String(localized: "Disk space critically low (%.1f GB) — switched to transcript only. Audio stopped to avoid filling your disk; the transcript keeps recording."), freeGB),
            style: .warning,
            duration: .seconds(7)
        )
        log.warning("Low disk mid-recording (\(free, privacy: .public) bytes free) — switched to transcript-only")
    }

    // MARK: - Pause / Resume

    /// Soft pause. Audio capture and live transcription halt but the
    /// session state is preserved: same directory, same audio files,
    /// same accumulated segments. No celebration animation, no
    /// summary run — just a quiet hold. On `resume()` we re-open the
    /// pipelines and continue appending to the same archives.
    ///
    /// Privacy intent: clicking the floating widget mid-meeting
    /// shouldn't capture a side-conversation you didn't intend to
    /// record. Pause cuts the input stream entirely, not just the
    /// live transcript view.
    func pause() async {
        guard status == .recording else { return }
        recorder.pause()
        // Was: `Task { await systemAudio.pause() }` — unawaited race.
        // User who pause→resume'd quickly caught `systemAudio.state`
        // still at `.capturing` (the detached pause Task hadn't
        // completed), and `resume()`'s `guard state == .paused`
        // silently returned. Net effect: SCStream never paused, then
        // "resumed" with stale capture state → system audio went
        // silent until full Stop+Start. Build 40 fix per macOS audit:
        // make pause() async + await the SystemAudio pause so
        // `status = .paused` flips only after the pause has
        // actually committed downstream.
        await systemAudio.pause()
        micTranscriber.pause()
        systemTranscriber.pause()
        screenshots.stop()
        silenceMonitor.pause()
        status = .paused
        // Pause cue removed — it fired mid-capture (leak window) and the
        // widget colour already signals paused (gray). See SoundEffects.
        log.info("Session paused after \(self.elapsed, privacy: .public)s")
    }

    /// Resume a paused session. Audio capture restarts; the existing
    /// audio archive is appended to so the .caf file ends up as one
    /// continuous recording (gaps are simply absent, not silent).
    func resume() async {
        guard status == .paused else { return }
        do {
            try recorder.resume()
        } catch {
            log.error("Resume mic failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(String(localized: "Couldn't resume mic capture: \(error.localizedDescription)"))
            return
        }
        if settings.captureSystemAudio {
            do {
                try await systemAudio.resume()
            } catch {
                log.error("Resume system audio failed: \(error.localizedDescription, privacy: .public)")
                // Soft-fail: continue mic-only, same as during start —
                // but no longer SILENTLY, which is how a session that
                // captured the other side for its first ten minutes and
                // nothing after the pause used to look exactly like one
                // that worked. (`noteMicOnlyDegradation` is a no-op
                // outside meeting mode and after the first cause, so a
                // repeated pause/resume can't re-toast.)
                noteMicOnlyDegradation(cause: .systemAudioFailed)
            }
        }
        micTranscriber.resume()
        systemTranscriber.resume()
        if settings.screenshotsEnabled, let dir = sessionDirectory {
            let screenshotsDir = dir.appendingPathComponent("screenshots", isDirectory: true)
            // `elapsed` already carries the pre-pause total, so a
            // resume continues the timeline instead of restarting it.
            await screenshots.start(
                intervalSec: settings.screenshotIntervalSec,
                elapsed: { [weak self] in self?.elapsed ?? 0 },
                into: screenshotsDir
            )
        }
        silenceMonitor.resume()
        // Late-binding safety net: a user could have granted Calendar
        // access AFTER starting + pausing the session, or the meeting
        // could have appeared in the calendar mid-session via iCloud
        // sync. Re-running the bind + schedule on resume catches those
        // edge cases cheaply (no-op if boundMeeting is already set).
        bindCurrentMeetingIfPossible()
        scheduleAutoStopIfNeeded()
        status = .recording
        // Resume cue removed — same reasoning as pause (mid-capture leak
        // window + redundant with the widget colour). See SoundEffects.
        log.info("Session resumed")
    }

    /// Stop capture and throw the whole session away — audio, live
    /// transcript, screenshots, the directory itself (Trash when
    /// possible, hard delete as fallback). Explicit user action from
    /// the widget's context menu, guarded there by a confirmation
    /// dialog — this is the ONE path allowed to delete a live
    /// recording deliberately, as opposed to husk-cleanup and
    /// crash-recovery which must never delete on their own
    /// (see the husk-deletes-live-recording incident).
    ///
    /// `announcing: false` for the one caller whose user is looking at
    /// something else: trashing a screenshot note kills the dictation hold
    /// feeding it, and "Recording discarded — nothing was saved" is both a
    /// toast in a window they aren't in and a sentence about a recording
    /// they never thought they started.
    func discard(announcing: Bool = true) async {
        guard status == .recording || status == .paused else { return }
        skipFinalPassOnNextStop = false
        status = .stopping
        recorder.stop()
        await systemAudio.stop()
        screenshots.stop()
        silenceMonitor.stop()
        cancelAutoStop()
        removeThermalDowngrade()

        let dir = sessionDirectory
        // Clear the live-directory marker BEFORE deleting, so no scan
        // or recovery path sees a "live" folder vanish mid-flight.
        SessionStore.shared.activeRecordingDirName = nil
        // reset() BEFORE the delete, not after: it tears down the
        // transcribers, and a final ASR segment landing in the window
        // between trash and reset could write into (or recreate paths
        // under) the just-deleted directory — the husk-resurrection
        // class of bug (review find, 2026-08-21).
        let captured = elapsed
        // Read before `reset()` puts the mode back to `.meeting`.
        let wasDictation = (currentMode == .dictation)
        reset()
        if let dir {
            if wasDictation {
                // A dictation directory is scratch space — every ordinary
                // dictation exit unlinks it (see RecordingSession+Dictation).
                // Trashing it would leave a `mic.caf` of what the person
                // just said sitting in ~/.Trash after they pressed delete,
                // which for this app is a bug report, not a safety net.
                try? FileManager.default.removeItem(at: dir)
            } else {
                do {
                    try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
                } catch {
                    try? FileManager.default.removeItem(at: dir)
                }
            }
            log.info("Session discarded by user — directory removed (\(captured, privacy: .public)s captured)")
        }
        if announcing {
            ToastCenter.shared.show(
                String(localized: "Recording discarded — nothing was saved."),
                style: .info,
                duration: .seconds(4)
            )
        }
        await SessionStore.shared.refresh()
    }

    func stop() async {
        // Full finalize — explicit user action. Allowed from both
        // .recording and .paused (the latter so the user can pause
        // first, change their mind, then commit). Anything else is a
        // no-op so transient states aren't interrupted.
        guard status == .recording || status == .paused else { return }
        // Consume the rotation flag IMMEDIATELY — stop() has several
        // early returns below (husk cleanup, dictation branch, missing
        // session dir), and a stale `true` surviving one of them would
        // make a LATER legitimate stop silently skip its finalize
        // (no summary, no auto-send — hours later, undiagnosable).
        let isRotationStop = skipFinalPassOnNextStop
        skipFinalPassOnNextStop = false
        // Caption down at key-up, not after the decode: the dictation
        // final pass runs INLINE below, and a caption that lingers
        // through it reads as "still listening". Harmless no-op for
        // meetings/voice notes (no caption was ever shown).
        WidgetBubbleCenter.shared.hideLiveCaption()
        removeThermalDowngrade()
        // No stop-click cue — it fired before capture stopped (tailing the
        // recording) and before any work finished. The "done" cue now plays
        // when `.finished` lands (SoundEffects.playFinished) — leak-safe and
        // synced to the widget's celebration pop.
        // Flip to .stopping BEFORE the first await. The paused-teardown
        // below suspends, and a second `stop()` arriving during that
        // suspension (auto-stop timer racing a manual Stop, or
        // willPowerOff racing the quit confirmation) would pass the
        // guard above and run the whole finalize pipeline twice —
        // double final pass, double summary, duplicate auto-send.
        let wasPaused = (status == .paused)
        status = .stopping
        // Close any still-open side-note window so its excerpt ends at
        // Stop rather than being dropped.
        if isCapturingSideNote {
            sideNoteWindows[sideNoteWindows.count - 1].end = Date()
        }
        if wasPaused {
            // Make sure any half-open paused pipelines are fully
            // torn down before the final transcribe.
            recorder.stop()
            await systemAudio.stop()
        }

        recorder.stop()
        await systemAudio.stop()
        screenshots.stop()
        silenceMonitor.stop()
        cancelAutoStop()
        removeThermalDowngrade()

        // Surface the "system audio capture armed but received zero
        // frames" condition before the user navigates away from the
        // session. Most common root cause: the macOS default output
        // is a Bluetooth device — Screen Capture can't loop back BT
        // by design, so the captured stream is silent and the
        // user's `system_audio.caf` ends up 0 bytes. The 30-second
        // in-flight watchdog inside SystemAudioCapture warns once
        // per session, but it can be missed (focus mode, busy
        // meeting); this is the second-chance summary toast.
        //
        // Sessions shorter than 60 s skip the warning — there's not
        // enough signal to distinguish "user stopped intentionally"
        // from "capture broken".
        if settings.captureSystemAudio,
           currentMode == .meeting,
           elapsed > 60,
           !systemAudio.hasReceivedAudio {
            // Two well-understood causes: Bluetooth output (macOS
            // refuses to loop BT audio through ScreenCaptureKit), and
            // a ScreenCaptureKit regression on macOS 26.0.x (early
            // Tahoe builds) where SCStream reports `.capturing` but
            // never delivers a single audio buffer even with wired or
            // built-in output. Phrase the toast neutrally so we don't
            // mislead the macOS 26 cohort into chasing a BT issue
            // they don't have.
            // 2026-05-25 — toast shortened to one line per Egor's
            // pass. Pre-fix this was a 4-sentence wall (microphone
            // track + system loopback + Tahoe regression caveat +
            // built-in-speaker workaround + diarization implication)
            // that wrapped to ~4 lines of dense text in the toast
            // surface — visually overwhelming and edge-to-edge on
            // wide displays. The same session also surfaces the
            // acousticLoopbackBanner inside SessionDetailView when
            // the user opens it, which carries the one-line warning
            // permanently (until "Got it"). The Tahoe-specific
            // "switch to built-in speakers" workaround was also
            // unreliable in tester reports — keeping it in the
            // toast set a false expectation of fix-ability.
            ToastCenter.shared.show(
                String(localized: "Other side wasn't captured — only your mic was recorded this session"),
                style: .warning,
                duration: .seconds(8)
            )
            log.warning("Session ended with empty system audio despite captureSystemAudio=on (no audio buffers from SCStream — BT output, or macOS 26 SCStream regression)")
        }
        // NOTE: do NOT release the user-folder ticket here yet —
        // we still need to write transcript.md and summary.json
        // below, both of which land inside the user-picked folder.
        // Release happens at the bottom of stop() after all writes
        // have flushed (or in the no-audio early-return path).

        // Defensive: if the user hit Stop within ~1 second of Start
        // (or any other path that didn't actually capture audio),
        // there's no point keeping the session directory around as a
        // husk. Bail out before running Whisper / writing markdown.
        // Did we capture anything worth keeping? Two data-loss fixes vs.
        // the old check (which only tested the BASE microphone.caf /
        // system_audio.caf files):
        //   1. Count frames across ALL parts via `archivedFrameCount`,
        //      not just the base file. A route change — including the
        //      spurious one that fires ~24 ms after start — rolls the
        //      archive into `microphone.partN.caf` and leaves the BASE
        //      file 0 bytes. The old `fileExistsNonEmpty(micArchiveURL)`
        //      then saw "no audio" and deleted a session that actually
        //      had minutes of audio in a .partN file (real repro: 81 s
        //      recorded, live transcript fine, whole session erased on Stop).
        //   2. Never delete a session that produced transcript segments,
        //      even at zero audio frames — covers "Don't record audio"
        //      mode (the transcript IS the product) and any path where
        //      audio didn't reach disk but Whisper still committed text.
        let capturedAnyAudio =
            recorder.archivedFrameCount > 0 ||
            systemAudio.archivedFrameCount > 0
        let hasTranscript = !segments.isEmpty
        if !capturedAnyAudio && !hasTranscript {
            // Nothing usable was captured — and NEITHER branch may delete
            // a recording silently. This path has erased real recordings
            // before, and a session the user deliberately started must
            // never just vanish.
            if elapsed < 10 {
                // Genuine accidental tap (Record → immediately Stop).
                // Remove the husk, but say so — not silent.
                if let dir = sessionDirectory {
                    try? FileManager.default.removeItem(at: dir)
                    log.info("Stop: <10s and nothing captured — removed husk")
                }
                ToastCenter.shared.show(
                    String(localized: "Recording too short — nothing to save"),
                    style: .info,
                    duration: .seconds(3)
                )
                reset()
                return
            }
            // ≥10s but empty (e.g. the live engine silently produced
            // nothing in "Don't record audio" mode). KEEP the session and
            // warn, so it stays visible in the Library and the user can
            // act — rather than disappearing. Safe to keep: summary
            // (`willSummarize … && !segments.isEmpty`) and auto-send
            // (`!segments.isEmpty`) both already skip an empty transcript,
            // so nothing gets summarised or pushed to Notion on empty — it
            // just leaves an (empty) transcript.md the user can see.
            log.warning("Stop: \(self.elapsed, privacy: .public)s elapsed but no audio and no transcript — keeping session and warning (not deleting)")
            ToastCenter.shared.show(
                String(localized: "Nothing was transcribed this session — check your mic and Settings → Transcription. The recording was kept, not discarded"),
                style: .warning,
                duration: .seconds(8)
            )
            // fall through — keep the empty session instead of removing it.
        }

        // 2026-05-25 — per-stage timing for the pre-`.finished`
        // pipeline. Pre-fix every stage between Final pass and
        // status=.finished ran silently; on long sessions users
        // reported "пост-обработка очень долгая" with nothing to
        // attribute it to (see [[feedback_silent_early_returns_need_logger_category]]).
        // Mirrors the OSSignposter spans inside finalizePostStop so
        // Instruments traces and `log show --signpost` both line up
        // under PostStop category; the .info lines below are visible
        // in plain `log show ... --info --debug` as a fallback.
        let stopSignposter = OSSignposter(subsystem: "app.essazanov.Daisy", category: "PostStop")
        func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

        // 2026-05-27 — TWO-STAGE STOP (1.0.7.3).
        //
        // Pre-fix this is where we ran the full Whisper final pass
        // (mic + system) inline, blocking `status = .finished` until
        // it returned. On a 20+ minute mic session this clocked
        // 237091ms in real-world logs — the user sees "Stopping…"
        // for 4 minutes and can't start the next recording. PH
        // launch is in a week and meeting-to-meeting flow is core,
        // so we changed shape.
        //
        // New shape:
        //   1. `stopCapture()` instead of `stop()` on each transcriber
        //      — drains live consumers + in-flight diarization, no
        //      final Whisper pass. Returns in well under a second.
        //   2. Render transcript.md from LIVE-accumulated segments
        //      (they're real Whisper output too, just per-window
        //      context instead of full-session context). User opens
        //      the session, sees content immediately.
        //   3. `status = .finished` fires below — user is unblocked.
        //   4. Detached task (`finalizePostStop`) runs the final
        //      Whisper pass + applySpeakerProfileMatches +
        //      re-renders/overwrites transcript.md with final
        //      quality, then continues to summary + autoSend.
        //
        // Trade-off: transcript.md is live-quality for ~tens of
        // seconds to a few minutes after Stop, then polishes
        // itself. Users who hit Stop are typically rushing to the
        // next meeting and will look at the transcript later — by
        // which time the final pass is done. Summary still uses
        // final-quality transcript (waits for re-render).
        // Dictation only: cancel the in-flight live windowed decode
        // BEFORE stopCapture's `await transcribeTask?.value`. The
        // dictation final pass below discards the live result wholesale
        // (full-replace clears committedSegments), so without the
        // cancel the final decode just queues behind a doomed live
        // window on the WhisperEngine semaphore — pure release→paste
        // latency. cancelLivePass() also kills the live timer so no
        // new window can start; stopCapture still awaits the cancelled
        // task, guaranteeing the engine slot is free before the final
        // pass. Meeting/voice-note paths are untouched — their live
        // segments ARE the immediate post-stop transcript.
        if currentMode == .dictation {
            micTranscriber.cancelLivePass()
        }
        let stopCaptureState = stopSignposter.beginInterval("stop_capture", id: stopSignposter.makeSignpostID())
        let t_stopCapture = Date()
        async let micCaptured: Void = micTranscriber.stopCapture()
        async let sysCaptured: Void = systemTranscriber.stopCapture()
        _ = await (micCaptured, sysCaptured)
        stopSignposter.endInterval("stop_capture", stopCaptureState)
        log.info("post-stop stop_capture: \(ms(t_stopCapture), privacy: .public)ms")
        // applySpeakerProfileMatches is intentionally NOT called
        // here — it depends on `speakerCentroids` which only get
        // populated by the final pass. The detached task runs it
        // after `runFinalPass()` lands.

        // 2026-05-25 — silent-write-death audit (1.0.7.1). Pre-fix the
        // only signals were `hasReceivedAudio` (in-memory flag, flips
        // true on first buffer regardless of disk write outcome) and a
        // per-write `log.error` line that no user ever sees. Result:
        // the Billions test session shipped frontmatter that claimed
        // `daisy_system_audio_status: captured` while system_audio.caf
        // was 0 bytes, mic.caf had 5% of the audio the transcript
        // referenced, and the user got zero indication anything was
        // wrong. Now: we read both ArchiveStatus values BEFORE the
        // frontmatter is rendered, log the verdict structurally for
        // `log show`, and toast if either side is truncated so the
        // user has the chance to keep the raw .caf around for repair
        // instead of letting delete-after-transcription nuke it.
        let micStatus = micAudioArchiveStatus
        let sysStatus = systemAudioArchiveStatus
        log.info("post-stop archive_audit mic: \(String(describing: micStatus), privacy: .public)")
        log.info("post-stop archive_audit system: \(String(describing: sysStatus), privacy: .public)")

        // One consolidated, SURVIVABLE summary per session (.notice
        // persists to the on-disk store; the .info lines above rotate
        // out of the in-memory window and often aren't in a tester's
        // `log show` capture). Everything a "what happened?" report
        // needs in one greppable line: mode, recorded length, both
        // archive verdicts, whether the other side was ever received
        // (separates .empty-from-silence vs .truncated-on-write), the
        // capture setting, and how far the bound meeting's scheduled
        // end was from this stop — the signal for "did auto-stop cut
        // it short?". No title/transcript content — privacy-safe.
        let durSec = startedAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
        let boundEndDelta = boundMeeting.map { Int(Date().timeIntervalSince($0.endDate)) }
        // `archivingDisabled` earns its place here: without it, `sys=off
        // mic=off` in a report is ambiguous between "user turned system
        // audio off" and "no archive was written at all", and the reader
        // has to go hunting for a low-disk warning elsewhere in the log.
        let summary = "mode=\(currentMode) dur=\(durSec)s sys=\(String(describing: sysStatus)) mic=\(String(describing: micStatus)) sysReceived=\(hasCapturedSystemAudio) captureSysSetting=\(settings.captureSystemAudio) archivingDisabled=\(audioArchivingDisabled) boundEndDelta=\(boundEndDelta.map { "\($0)s" } ?? "none")"
        log.notice("post-stop SESSION SUMMARY — \(summary, privacy: .public)")

        // ── Capture-failure gate (2026-07-22, AirPods support case) ───────
        // If NEITHER channel reached `.captured` AND the transcript is
        // sparse for its length, the recording holds no usable audio: the
        // live transcript is at best fragments and, on a near-silent
        // stream, Whisper hallucinates. Real report: AirPods took the
        // audio route, mic + system both went empty, yet a confident
        // summary + client follow-up email were generated from garbage.
        // Suppress the auto-summary so no authoritative-looking text comes
        // out of a failed capture — the raw transcript is still saved, and
        // the user can Re-summarize by hand if they disagree. Gated on
        // sparsity too so a dead ARCHIVE with a good LIVE transcript
        // (archive-write died but capture was fine) isn't wrongly blocked.
        var anyChannelCaptured = false
        if case .captured = micStatus { anyChannelCaptured = true }
        if case .captured = sysStatus { anyChannelCaptured = true }
        // RAW segments, not `fullTranscriptText`: this asks "did the
        // microphone hear anything at all", and echo dedup can halve the
        // word count on a speakers-on meeting. Counting deduped words
        // here would push a perfectly-transcribed meeting under the
        // threshold and suppress its summary with a red "capture failed"
        // toast.
        let rawWords = segments
            .map { $0.text }
            .joined(separator: " ")
        let transcriptWPM = durSec > 0
            ? Double(UsageStats.wordCount(rawWords)) / (Double(durSec) / 60.0)
            : 0
        // Real meetings run ~100-150 wpm; <20 over the whole recording
        // means almost nothing was heard.
        let captureLikelyFailed = currentMode == .meeting
            && !anyChannelCaptured
            && transcriptWPM < 20
        if captureLikelyFailed {
            log.error("Capture likely FAILED — mic=\(String(describing: micStatus), privacy: .public) sys=\(String(describing: sysStatus), privacy: .public) wpm=\(Int(transcriptWPM), privacy: .public) archivingDisabled=\(self.audioArchivingDisabled, privacy: .public); suppressing auto-summary")
            // SUPPRESSION is right in every branch below — an empty
            // transcript has nothing to summarise. What differs is the
            // reason, and the old single string asserted Bluetooth
            // unconditionally. It sent a user on wired headphones with a
            // full disk off to unpair AirPods she wasn't wearing.
            ToastCenter.shared.show(
                captureFailureMessage(),
                style: .error,
                duration: .seconds(15)
            )
        }

        // Per-channel truncation toasts — only when we haven't already
        // shown the unified capture-failed message above. Both are
        // unreachable when archiving is off by design: the audit reports
        // `.off`, not `.truncated`.
        if !captureLikelyFailed, case .truncated(let bytes, let framesWritten, let writeErrors) = micStatus {
            log.error("Mic archive TRUNCATED: \(bytes, privacy: .public) bytes on disk, \(framesWritten, privacy: .public) frames written, \(writeErrors, privacy: .public) write errors")
            ToastCenter.shared.show(
                String(localized: "Mic recording is incomplete — only part of your audio made it to disk. Keep this session's folder to recover what's there."),
                style: .error,
                duration: .seconds(12)
            )
        }
        if !captureLikelyFailed, case .truncated(let bytes, let framesWritten, let writeErrors) = sysStatus {
            log.error("System audio archive TRUNCATED: \(bytes, privacy: .public) bytes on disk, \(framesWritten, privacy: .public) frames written, \(writeErrors, privacy: .public) write errors")
            ToastCenter.shared.show(
                String(localized: "Other-side audio is incomplete — capture started but the file didn't grow. Transcript may still be usable; raw audio is partial."),
                style: .error,
                duration: .seconds(12)
            )
        }

        // Dictation mode — fully ephemeral. Run the final Whisper pass
        // INLINE before reading `fullTranscriptText` (build 41 fix):
        // pre-build-41 we relied on the live windowed transcriber
        // having committed everything by the time `stopCapture()`
        // returned, but the live transcriber requires either a full
        // 14-second VAD window OR an end-of-speech silence boundary
        // to commit a segment. Short utterances ("просто для аудита",
        // ~1.2 s) released as soon as the user lifted the hotkey
        // never got either — buffer flushed silently, no transcript,
        // paste landed empty. User feedback: "цветок видит, но текст
        // не вставляется; приходится держать с тишиной".
        //
        // Final pass forces Whisper to transcribe whatever's in the
        // mic buffer regardless of VAD state. Typical <30s dictation
        // → 200-800ms decode. The Stop blocks for that window before
        // paste; price for short-utterance reliability.
        //
        // For non-dictation modes the final pass runs in the detached
        // `finalizePostStop` task after `.finished` flips — that path
        // still applies, just below.
        if currentMode == .dictation {
            // Dictation post-processing (fast-engine → Whisper fallback,
            // optional voice polish, usage, paste, teardown) lives in
            // RecordingSession+Dictation.swift.
            await finishDictation(durSec: durSec)
            return
        }

        // Save markdown next to the audio archive. A failure here means
        // the user just lost their transcript on disk — surface it
        // loudly rather than swallowing.
        // `renderMarkdown` runs AcousticEchoDedup + transcript shaping
        // internally; on long sessions with hundreds of segments this
        // is the likely "long silent stage" suspect. Split into render
        // vs write so we can tell which one is slow.
        if let dir = sessionDirectory {
            let url = dir.appendingPathComponent("transcript.md")
            let renderState = stopSignposter.beginInterval("render_markdown", id: stopSignposter.makeSignpostID())
            let t_render = Date()
            let md = MarkdownExporter.renderMarkdown(session: self)
            stopSignposter.endInterval("render_markdown", renderState)
            log.info("post-stop render_markdown: \(ms(t_render), privacy: .public)ms, \(md.count, privacy: .public) bytes")

            // Product call 2026-07-25: when the dedup pass concluded the
            // whole meeting echoed through the speakers (systemic mode),
            // say so once — the durable fix is a headset, not smarter
            // attribution. Complements the at-start internal-speakers
            // nudge in SystemAudioCapture.start().
            if settings.suppressAcousticEcho, AcousticEchoDedup.lastFilterWasSystemic {
                ToastCenter.shared.show(
                    String(localized: "Echo removed — this meeting seems to have played through the speakers. Use headphones for clean speaker separation."),
                    style: .info
                )
            }

            let writeState = stopSignposter.beginInterval("write_transcript_md", id: stopSignposter.makeSignpostID())
            let t_write = Date()
            do {
                try md.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                log.error("Failed to write transcript.md: \(error.localizedDescription)")
                ToastCenter.shared.show(
                    String(localized: "Couldn’t save transcript file. Check Console for details."),
                    style: .error
                )
            }
            stopSignposter.endInterval("write_transcript_md", writeState)
            log.info("post-stop write_transcript_md: \(ms(t_write), privacy: .public)ms")

            // Split any side notes captured during the meeting into their
            // own Notes sessions. Best-effort and after the meeting's
            // transcript is safely on disk — never blocks the save.
            if !sideNoteWindows.isEmpty { await writeSideNotes() }
        }

        // Local usage stats for meetings / voice notes (same widgets as
        // dictation). Live-quality transcript is fine for a word count.
        // Recorded as `.recording` so it counts toward total words + the
        // heatmap but NOT the dictation-only WPM.
        UsageStats.shared.record(
            words: UsageStats.wordCount(fullTranscriptText),
            seconds: Double(max(0, durSec)),
            kind: .recording
        )

        // Opt-in: grow the voice corpus with the user's own speech from
        // this MEETING. Mic-source segments only — the microphone stream
        // is the user by definition, so no diarization or speaker-map
        // guesswork is involved and the remote side can't leak in.
        //
        // Echo dedup runs FIRST, exactly as MarkdownExporter does it. On
        // speakers the mic re-captures the other party and Whisper
        // re-transcribes them as `.microphone` segments — feeding those
        // in would train "your voice" on whoever was talking. Skipping
        // this would also make the live path disagree with
        // `ownSpeech(inTranscript:)`, which reads the already-deduped
        // transcript on disk.
        //
        // Meetings only, matching what the switch promises and what
        // `backfillFromMeetings` collects; a voice note is left out in
        // both paths rather than counted in one of them.
        if currentMode == .meeting, VoiceProfileStore.shared.includesMeetings {
            let ownSpeech = dedupedSegments
                .filter { $0.source == .microphone }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            VoiceProfileStore.shared.appendMeetingSpeech(ownSpeech)
        }

        // ── Granola-style: status → .finished BEFORE summary ──────────
        //
        // Everything user-visible the recording lifecycle needs is on
        // disk now: audio, transcript.md, speakers.json. The widget /
        // panel can go idle, the user can start a new recording. The
        // LLM call (15-30 s) and downstream auto-send happen in a
        // detached task below and report progress through
        // `summaryGenerationState`, not through `status`.
        // LLM summary only runs for full `.meeting` mode. Voice
        // notes are bare transcript + audio (kept in History under
        // Notes folder), dictation is ephemeral and skipped
        // entirely below.
        let willSummarize = settings.autoSummarize
            && summarizer.availability == .available
            && !segments.isEmpty
            && currentMode == .meeting
            && !captureLikelyFailed

        guard let dir = sessionDirectory else {
            // No session dir — shouldn't happen post-capture, but
            // bail cleanly. transcript.md never landed, no summary
            // can run, no auto-send needed.
            releaseSessionsFolderTicket()
            status = .finished
            if settings.recordingSoundsEnabled { SoundEffects.playFinished() }
            return
        }
        let sessionID = dir.lastPathComponent

        // Mark the session as "summary in flight" BEFORE flipping
        // status — SessionDetailView observers may snap into the
        // skeleton state the moment .finished arrives and look at
        // the SessionStore set for the loading flag.
        if willSummarize {
            SessionStore.shared.beginGenerating(sessionID)
            summaryGenerationState = .generating
        } else {
            summaryGenerationState = .idle
        }

        // Refresh the History list synchronously so the row is in
        // place before the auto-open onChange handler (driven by
        // .finished) fires. Without this, MainView's deep-link
        // would land on Library with `pendingLibrarySelection`
        // pointing at an ID that hasn't been parsed yet.
        let refreshState = stopSignposter.beginInterval("session_store_refresh", id: stopSignposter.makeSignpostID())
        let t_refresh = Date()
        await SessionStore.shared.refresh()
        stopSignposter.endInterval("session_store_refresh", refreshState)
        log.info("post-stop session_store_refresh: \(ms(t_refresh), privacy: .public)ms")
        status = .finished
        if settings.recordingSoundsEnabled { SoundEffects.playFinished() }

        // 2026-05-27 — ALWAYS launch the detached finalize task,
        // not just for the summary case. The final Whisper pass
        // moved out of `.stopping` and into the detached path; the
        // task now owns: runFinalPass(mic+system) → speakerMatch →
        // re-render transcript.md → (optionally) summary → autoSend
        // → audio purge. The "no summary needed" branch used to
        // skip launching the task at all; now it still launches,
        // just sets willSummarize=false so the LLM step is no-op'd.
        let titleSnapshot = title
        let localeHint = localeHintForSummary
        // Snapshot the complete on-disk archive URLs NOW (capture is
        // stopped, files are flushed/closed), before the detached task
        // runs or a fresh start() rotates the recorder. The final pass
        // decodes these to transcribe the whole recording rather than
        // the trimmed in-memory buffer. Empty for transcript-only /
        // "don't record audio" sessions → buffer fallback. Mic can be
        // multiple parts after a mid-session format change; system is a
        // single file.
        let micArchiveURLs = recorder.archivedParts
        let systemArchiveURLs = systemArchiveURL.map { [$0] } ?? []
        // Transfer ticket ownership to the detached task BEFORE
        // spawning it. If the user hits Stop & save on M1 and
        // then immediately starts M2 (calendar auto-rotation,
        // hotkey, whatever), `start()` will assign a NEW ticket
        // to `self.sessionsFolderTicket` for M2 — and pre-1.0.3
        // the M1 task would later call `releaseSessionsFolderTicket()`,
        // releasing M2's ticket and silently breaking M2's file
        // writes. Snapshot here, release via `defer` on the
        // captured value only.
        let ticketSnapshot = sessionsFolderTicket
        sessionsFolderTicket = nil
        // Bump generation BEFORE spawning so the task captures the
        // post-bump value. Wrapping add (&+=) is safe — at one stop
        // per second forever this overflows in ~136 years.
        summaryTaskGeneration &+= 1
        let myGeneration = summaryTaskGeneration
        // Session-rotation fast-path (issue #7): when this stop() runs
        // because a back-to-back calendar meeting is about to take
        // over, don't spawn the finalize task at all — see
        // `performStartFromMeeting` for the full story. The sandbox
        // ticket still has to be released (normally the spawned task's
        // defer does it).
        if isRotationStop {
            ticketSnapshot?.release()
            // Mirror finalizePostStop's `bailRotated` cleanup: stop()
            // already ran beginGenerating + set .generating above, and
            // with no finalize task spawned nobody else would ever
            // clear them — the rotated-away meeting would show the
            // summary skeleton until relaunch.
            if willSummarize {
                summaryGenerationState = .failed("cancelled")
                await SessionStore.shared.finishGenerating(sessionID)
            }
            log.warning("Final pass skipped — session rotation (back-to-back meeting) is taking over")
            return
        }
        summaryTask = Task { [weak self] in
            defer { ticketSnapshot?.release() }
            await self?.finalizePostStop(
                sessionID: sessionID,
                directory: dir,
                title: titleSnapshot,
                localeHint: localeHint,
                willSummarize: willSummarize,
                generation: myGeneration,
                micArchiveURLs: micArchiveURLs,
                systemArchiveURLs: systemArchiveURLs
            )
        }
    }

    // Post-Stop pipeline (finalizePostStop), speaker-profile matching,
    // auto-send + SendFailureRecord, and the StoredSession /
    // MeetingExportData snapshot builders + exportData() live in
    // RecordingSession+Finalize.swift.

    /// Centralised cleanup for the early-return paths in `start()`.
    /// Before 1.0.3 each early `return` only set `status = .failed(...)`
    /// — but by that point we'd already acquired the sandbox ticket
    /// (`makeSessionDirectory()` ran before the Whisper check) and
    /// started one or both transcribers. The leftover scoped resource
    /// held until the next `start()` or `reset()`, and any in-flight
    /// transcribers kept consuming buffers from a recorder that never
    /// actually started. `failFast` collapses all of that into one
    /// idempotent cleanup: release the ticket, stop both transcribers,
    /// stop the recorder + system-audio capture, cancel auto-stop
    /// timers, then flip the status. Safe to call multiple times.
    private func failFast(_ message: String) async {
        log.error("Session start failed: \(message, privacy: .public)")
        // A screenshot note claimed at key-down would otherwise die
        // with the failed start: its pill sits frozen (claim paused the
        // countdown) and the note can never be dictated into. Give the
        // window back whole — restorePending re-presents a live pill
        // (review find, 2026-08-21).
        if let p = pendingScreenshotNote {
            pendingScreenshotNote = nil
            ScreenshotNoteCapture.shared.restorePending(p)
        }
        releaseSessionsFolderTicket()
        WidgetBubbleCenter.shared.hideLiveCaption()
        micTranscriber.reset()
        systemTranscriber.reset()
        // recorder/systemAudio may not have started yet on early
        // paths (Whisper-failed branches) — reset is idempotent.
        recorder.reset()
        // Was: `Task { await systemAudio.stop() }` — unawaited race
        // with the next start(). If the user immediately retried
        // (e.g. after a "Whisper not ready yet" early-exit), the
        // next systemAudio.start() could run before this stop() had
        // finished, leaving SCStream in an inconsistent "starting
        // over an already-starting stream" state. Build 40 fix per
        // macOS audit: make failFast() async + await the stop so
        // the next start() always sees a clean slate.
        await systemAudio.stop()
        screenshots.stop()
        silenceMonitor.stop()
        cancelAutoStop()
        removeThermalDowngrade()
        sessionDirectory = nil
        momentMarkers = []
        micArchiveURL = nil
        systemArchiveURL = nil
        startedAt = nil
        status = .failed(message)
    }

    // MARK: - Thermal / low-power auto-downgrade

    /// Watch thermal state + Low Power Mode while a Full-tier session runs
    /// and silently drop live transcription Full→Lite under pressure,
    /// auto-restoring when it clears. The final pass on Stop stays full
    /// quality and the user's saved tier is never modified (runtime override).
    private func installThermalDowngrade(startedTier: LiveTranscriptionTier) {
        removeThermalDowngrade()
        startedLiveTier = startedTier
        // Only Full sessions have headroom to shed; Lite/Off/Apple are
        // already light. (Dictation forces Full but is short — harmless.)
        guard startedTier == .full else { return }
        let nc = NotificationCenter.default
        thermalObserver = nc.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluateThermalDowngrade() }
        }
        powerObserver = nc.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluateThermalDowngrade() }
        }
        // Evaluate immediately in case we START already hot / in Low Power Mode.
        evaluateThermalDowngrade()
    }

    private func removeThermalDowngrade() {
        if let t = thermalObserver { NotificationCenter.default.removeObserver(t); thermalObserver = nil }
        if let p = powerObserver { NotificationCenter.default.removeObserver(p); powerObserver = nil }
        thermalDowngradeActive = false
    }

    private func evaluateThermalDowngrade() {
        guard status == .recording, startedLiveTier == .full else { return }
        let info = ProcessInfo.processInfo
        let hot = info.thermalState == .serious || info.thermalState == .critical
        let shouldThrottle = hot || info.isLowPowerModeEnabled
        if shouldThrottle, !thermalDowngradeActive {
            thermalDowngradeActive = true
            micTranscriber.setLiveTier(.lite)
            systemTranscriber.setLiveTier(.lite)
            log.info("Live transcription auto-downgraded Full→Lite (\(hot ? "thermal" : "low-power", privacy: .public))")
            ToastCenter.shared.show(
                String(localized: "High \(hot ? String(localized: "heat") : String(localized: "power")) load — live transcript eased to Lite. The final transcript on Stop stays full quality."),
                style: .info
            )
        } else if !shouldThrottle, thermalDowngradeActive {
            thermalDowngradeActive = false
            micTranscriber.setLiveTier(startedLiveTier)
            systemTranscriber.setLiveTier(startedLiveTier)
            log.info("Live transcription auto-restored to Full (load normalised)")
            ToastCenter.shared.show(String(localized: "Load eased — live transcript back to Full."), style: .info)
        }
    }

    func reset() {
        // Best-effort cancel of any post-Stop finalize task. start()
        // already cancels first (so this is usually a no-op), but
        // direct reset() callers — e.g. an early-return after a Stop
        // that captured no audio — need it too.
        summaryTask?.cancel()
        summaryTask = nil
        summaryGenerationState = .idle
        // Belt to stop()'s braces: reset() is reached by every exit —
        // discard, husk cleanup, failed starts that got far enough —
        // and a caption with no session behind it must never survive.
        WidgetBubbleCenter.shared.hideLiveCaption()
        // Defensive: the rotation flag is normally consumed at the top
        // of stop(), but a reset() between set and consume (husk
        // cleanup path) must not leave it armed for a later stop.
        skipFinalPassOnNextStop = false
        recorder.reset()
        micTranscriber.reset()
        systemTranscriber.reset()
        screenshots.stop()
        silenceMonitor.stop()
        cancelAutoStop()
        removeThermalDowngrade()
        releaseSessionsFolderTicket()
        summarizer.clear()
        sessionDirectory = nil
        momentMarkers = []
        micArchiveURL = nil
        systemArchiveURL = nil
        // `micOnlyCause` is deliberately NOT cleared here — the
        // post-stop re-render of transcript.md still has to write
        // `daisy_mic_only:`, and reset() runs before that. It is zeroed
        // at the top of the next `start()` instead.
        startedAt = nil
        sideNoteWindows = []
        boundMeeting = nil
        meetingPreparationSnapshot = nil
        // Tester bug 2026-05-25: a calendar-bound meeting (title set
        // to the event name, e.g. "Pilik's Birthday") completed days
        // earlier, the session was saved, and `title` lived on in
        // memory. Two days later a voice-note hotkey hit triggered a
        // new session — reset() cleared boundMeeting/folder/currentMode
        // but NOT title. start() checked `if title.isEmpty` to decide
        // whether to regenerate, found it non-empty, and the voice
        // note was saved under "Pilik's Birthday". Cleared here so
        // the regeneration path in start() always runs from a clean
        // slate. The `pendingBoundMeeting` flow in `bindToMeeting`
        // re-sets the title from `meeting.title` AFTER reset() — same
        // pattern as boundMeeting / folder / mode pending fields —
        // so calendar-driven sessions still inherit the event name.
        title = ""
        folder = .inbox
        tag = ""
        currentMode = .meeting
        // Drop any unanswered Prompt-mode trigger + retract its banner —
        // starting/resetting supersedes a pending ask.
        pendingAutoStartTrigger = nil
        AutoStartPromptNotification.cancel()
        WidgetBubbleCenter.shared.dismiss(tag: Self.autoStartAskBubbleTag)
        status = .idle
    }

    // MARK: - Computed

    /// The transcript as the LLM sees it. Everything downstream of this
    /// — the summary, the follow-up draft, the catch-up, the word count
    /// — reads it, so the echo pass has to happen HERE and not only in
    /// `MarkdownExporter`.
    ///
    /// Before this, the two disagreed: transcript.md on disk was
    /// deduped and the summary was not. On speakers that meant the
    /// model read every remote line twice, the second copy labelled
    /// with the user's own name — so the notes had the user agreeing
    /// with themselves, and the follow-up draft attributed the other
    /// party's commitments to them (2026-08 audit). Meetings only:
    /// dictation and voice notes have no system stream for the mic to
    /// echo.
    var fullTranscriptText: String {
        let nonEmpty = dedupedSegments
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        switch currentMode {
        case .meeting:
            // Multi-speaker context — labels are signal ("[Egor]"
            // vs "[Alex]" vs "[Remote A]" tell the LLM who said
            // what for the summary pass). User's own voice uses
            // the configured display name when set; otherwise
            // falls back to the generic "Me".
            let myName = settings.userDisplayName
            return nonEmpty
                .map { "[\($0.speakerLabel(displayName: myName))] \($0.text)" }
                .joined(separator: "\n\n")
        case .voiceNote, .dictation:
            // Single-speaker, no diarization, no LLM downstream.
            // The speaker tag is noise — for dictation it'd end
            // up pasted into the user's text field as "[Me] hi
            // there", which is exactly what they don't want.
            //
            // Joined with " " (not "\n") because each entry in
            // `segments` is one Whisper VAD chunk — a pause-bounded
            // run of speech, NOT a paragraph. Pre-1.0.5 we joined
            // with single newlines, which made dictated text look
            // shredded: every breath turned into a line break.
            // Now consecutive chunks flow into one continuous
            // string, with each chunk's own punctuation handling
            // sentence boundaries. The model usually emits a
            // trailing space inside `.text`; we trim duplicates
            // afterwards so we never produce double spaces.
            let joined = nonEmpty
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " ")
            // Collapse any accidental double-spaces from per-chunk
            // trim artefacts. Single regex sweep, cheap.
            return joined.replacingOccurrences(
                of: "  +",
                with: " ",
                options: .regularExpression
            )
        }
    }

    var hasContent: Bool {
        segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    // hasCapturedSystemAudio + the archive truncation audit
    // (systemAudioArchiveStatus / micAudioArchiveStatus /
    // systemAudioStatusValue) live in RecordingSession+ArchiveAudit.swift.

    /// Free bytes on the volume backing `url` — "important usage" capacity,
    /// which counts purgeable space, so we don't drop to transcript-only on a
    /// disk macOS could free on demand. nil if unqueryable; callers treat nil
    /// as "plenty".
    private static func freeDiskBytes(at url: URL?) -> Int64? {
        DiskSpace.freeBytes(at: url)
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    func runSummary() async {
        guard !segments.isEmpty else { return }
        guard case .available = summarizer.availability else { return }
        let priorStatus = status
        status = .summarizing
        await summarizer.summarize(
            transcript: fullTranscriptText,
            title: title,
            localeHint: localeHintForSummary
        )
        status = priorStatus
    }

    /// Two-letter ISO code that pins the *summary* language. Reads
    /// from the canonical resolver so the post-Stop auto-summary and
    /// the manual Re-summarize button in SessionDetailView can never
    /// drift apart and produce different languages for the same
    /// transcript.
    private var localeHintForSummary: String? {
        Self.resolveSummaryLocaleHint(
            transcript: fullTranscriptText,
            transcriptLocale: localeIdentifier,
            summaryLanguageOverride: settings.summaryLanguage
        )
    }

    /// **Single source of truth** for "what language should this
    /// summary be in?". Used by both the post-Stop detached pipeline
    /// (via `localeHintForSummary`) and SessionDetailView's manual
    /// Re-summarize button. Inconsistency between those two paths
    /// is what produced the QA-reported "first summary was Russian,
    /// pressing Re-summarize gave English" bug — the manual path
    /// used to bypass language detection entirely and naively trust
    /// the frontmatter locale tag.
    ///
    /// **Contract — explicit picker wins.** A user who deliberately
    /// picks "Polish" in Settings → Summary language wants Polish
    /// summaries regardless of what NLLanguageRecognizer thinks the
    /// transcript was in. Previously detection beat the picker so a
    /// Polish-pick + Russian-transcript always produced Russian
    /// summary, which looked like a localization bug from the user's
    /// seat. The detection path is now the FALLBACK for the "Auto"
    /// case — that's the explicit "let Daisy figure it out" mode.
    ///
    /// Precedence:
    ///   1. `summaryLanguageOverride` (when not "auto" and not empty)
    ///      — explicit user pick wins, period.
    ///   2. **`LanguageDetector.detect(transcript)`** — only consulted
    ///      when the picker is "Auto". Returns nil for too-short /
    ///      low-confidence input so the next fallback runs.
    ///   3. `transcriptLocale` prefix (when not "auto" / empty) —
    ///      user-pinned recording locale from frontmatter.
    ///   4. `nil` — truly unknown, model decides on its own.
    ///
    /// Note: the Re-summarize action passes through the same path,
    /// so an "Auto" session re-summarized produces the same answer
    /// twice (the original concern that drove the previous inversion).
    /// An "Auto + transcript too short for detection" session
    /// previously produced "match transcript settings" → now produces
    /// the same `nil` consistently. That's the right deterministic
    /// behaviour either way.
    nonisolated static func resolveSummaryLocaleHint(
        transcript: String,
        transcriptLocale: String,
        summaryLanguageOverride: String
    ) -> String? {
        // 1. Explicit picker wins. "Auto" intentionally falls through.
        if !summaryLanguageOverride.isEmpty,
           summaryLanguageOverride != SummaryLanguage.auto.id {
            return summaryLanguageOverride
        }
        // 2. Auto mode → content-driven detection.
        if let detected = LanguageDetector.detect(transcript) {
            return detected
        }
        // 3. Transcript locale frontmatter as last resort hint.
        let prefix = transcriptLocale
            .split(separator: "-")
            .first
            .map(String.init)?
            .lowercased()
        if let prefix, prefix != "auto", !prefix.isEmpty {
            return prefix
        }
        // 4. Model decides on its own.
        return nil
    }

    // MARK: - Internals

    private func makeSessionDirectory() throws -> URL {
        // Acquire and hold the security-scoped folder for the
        // entire recording lifetime. ticket.url is either the user-
        // picked folder (Obsidian vault, ~/Documents/Meetings, …)
        // or the app's container default. Released in stop()/reset().
        guard let ticket = SessionsFolder.acquireBase() else {
            throw NSError(
                domain: "app.essazanov.Daisy",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't resolve a writable sessions folder."]
            )
        }
        self.sessionsFolderTicket = ticket

        let fm = FileManager.default
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let safeStamp = stamp.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = ticket.url.appendingPathComponent("Daisy/Sessions/\(safeStamp)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Release the security-scoped folder ticket. Called from
    /// `stop()`, `reset()`, and the dictation finalize extension so we
    /// don't hold the user's folder open after a session is finalised.
    /// `internal` (not `private`) so `RecordingSession+Dictation` can
    /// tear the session down.
    func releaseSessionsFolderTicket() {
        sessionsFolderTicket?.release()
        sessionsFolderTicket = nil
    }
}
