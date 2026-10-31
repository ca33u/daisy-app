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
    var skipFinalPassOnNextStop = false

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

    /// The language actually HEARD, as opposed to `localeIdentifier`,
    /// which is the setting and reads "auto" for most people. Snapped by
    /// the transcriber once it has enough committed text, nil until then
    /// (and nil for a session where the user pinned a language — there
    /// `localeIdentifier` already is the answer). Mic side first: it is
    /// the user's own language, which is what the voice corpus asks for.
    var detectedLanguage: String? {
        micTranscriber.detectedLanguage ?? systemTranscriber.detectedLanguage
    }
    private(set) var sessionDirectory: URL?
    private(set) var micArchiveURL: URL?
    private(set) var systemArchiveURL: URL?
    private(set) var startedAt: Date?

    // MARK: - Side notes (voice note layered over a live meeting)

    /// A wall-clock span the user marked as a side note WHILE a meeting
    /// was recording, via a tap of the Daisy key. On finalize the meeting
    /// segments overlapping each span are COPIED into their own note
    /// session in the Notes folder, together with a matching audio
    /// excerpt (mic + system, mixed) sliced from the meeting's own
    /// archive — i.e. the note is a clip of the meeting, snapped to the
    /// covered transcript-segment boundaries. The meeting stays whole
    /// ("excerpt" model, 2026-07-21) unless the person set side notes to
    /// cut (`sideNoteCutsFromMeeting`, backlog 34 K-3): then, once the
    /// final pass has rewritten a note from its full-quality lines,
    /// `segments` leaves those lines out (`cutSideNoteWindows`). Never
    /// before: a cut of lines the note doesn't have would lose them.
    /// Meeting-mode only.
    ///
    /// Both ends are on the recording's clock (`mediaNow`), the clock the
    /// segments' dates are on; wall-clock ends drifted past every pause
    /// and copied the wrong lines (found 21.10).
    struct SideNoteWindow: Sendable, Equatable {
        let start: Date
        var end: Date?
    }
    private(set) var sideNoteWindows: [SideNoteWindow] = []
    /// Side notes whose lines `segments` leaves out: only windows whose
    /// note was rewritten from the final pass (`finishSideNoteCuts`).
    var cutSideNoteWindows: [SideNoteWindow] = []

    /// A side note written at Stop, kept so the final pass can rewrite it
    /// from full-quality lines before its window is cut.
    struct WrittenSideNote {
        let window: SideNoteWindow
        let transcript: URL
        let start: Date
        let end: Date
        let meetingID: String
        let hasAudio: Bool
        let folderSlug: String
        /// The file's modification date as written: a later one means the
        /// person edited the note, and it is left alone (and not cut).
        let modified: Date?
    }
    var writtenSideNotes: [WrittenSideNote] = []

    /// True while a side-note window is open (started, not yet ended).
    /// Drives the recording-capsule / toast indication.
    var isCapturingSideNote: Bool {
        sideNoteWindows.last.map { $0.end == nil } ?? false
    }

    /// Whether an instant on the recording's clock falls inside any side-note window
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
            closeSideNote(String(localized: "Side note saved — it'll be split out when you stop."))
        } else {
            sideNoteWindows.append(SideNoteWindow(start: mediaNow, end: nil))
            // A plaque for as long as the window is open (spec 21.10): the
            // key is pressed from the meeting app, where an in-window toast
            // would never be seen.
            let plaque = WidgetBubbleContent(
                text: String(localized: "Side note · press to finish"),
                actionTitle: String(localized: "Finish"),
                autoDismiss: Self.sideNoteMaxLength,
                tag: Self.sideNoteTag,
                action: { [weak self] in
                    self?.closeSideNote(String(localized: "Side note saved — it'll be split out when you stop."))
                }
            )
            sideNotePlaque = plaque
            if !WidgetBubbleCenter.shared.show(plaque) {
                ToastCenter.shared.show(
                    String(localized: "Marking a side note… press the Daisy key again to end it."),
                    style: .info
                )
            }
            watchSideNote()
        }
    }

    nonisolated static let sideNoteTag = "side-note"
    /// The longest a side note stays open (spec 21.10).
    nonisolated static let sideNoteMaxLength: TimeInterval = 5 * 60
    /// A side note closes on its own after this long without speech.
    nonisolated static let sideNoteQuietLimit: TimeInterval = 60

    /// Ends the open side-note window and says so on the pill, where the
    /// plaque was. `message: nil` ends it quietly (Stop).
    func closeSideNote(_ message: String?) {
        sideNoteWatch?.cancel()
        sideNoteWatch = nil
        sideNotePlaque = nil
        guard isCapturingSideNote else { return }
        sideNoteWindows[sideNoteWindows.count - 1].end = mediaNow
        guard let message else {
            WidgetBubbleCenter.shared.dismiss(tag: Self.sideNoteTag)
            return
        }
        let shown = WidgetBubbleCenter.shared.show(
            WidgetBubbleContent(text: message, autoDismiss: 4, tag: Self.sideNoteTag)
        )
        if !shown { ToastCenter.shared.show(message, style: .success) }
    }

    /// Closes a forgotten side note: after a minute without speech, and
    /// at five minutes in any case. Speech is the microphone's RMS — the
    /// auto-stop gate's measure — so it works with live transcription
    /// off too. A pause is not quiet: the window waits it out, up to the
    /// five minutes.
    private func watchSideNote() {
        sideNoteWatch?.cancel()
        sideNoteWatch = Task { [weak self] in
            let opened = Date()
            var lastSpeech = opened
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, self.isCapturingSideNote else { return }
                let now = Date()
                // The pill has one slot: another message replaced the
                // plaque. Once that one has gone, the plaque comes back,
                // for the time the window has left.
                if WidgetBubbleCenter.shared.wasDisplacedAndFree(tag: Self.sideNoteTag), var plaque = self.sideNotePlaque {
                    plaque.autoDismiss = max(1, Self.sideNoteMaxLength - now.timeIntervalSince(opened))
                    _ = WidgetBubbleCenter.shared.show(plaque)
                }
                if self.status == .paused || self.recorder.lastMicRMSDB > Self.sideNoteSpeechFloorDB {
                    lastSpeech = now
                }
                if now.timeIntervalSince(opened) >= Self.sideNoteMaxLength {
                    self.closeSideNote(String(localized: "Side note saved — five minutes is the longest one runs."))
                    return
                }
                if now.timeIntervalSince(lastSpeech) >= Self.sideNoteQuietLimit {
                    self.closeSideNote(String(localized: "Side note saved after a minute of quiet."))
                    return
                }
            }
        }
    }

    /// The auto-stop gate's speech floor (`autoStopMicRMSFloorDB`).
    nonisolated static let sideNoteSpeechFloorDB: Float = -50

    @ObservationIgnored
    private var sideNoteWatch: Task<Void, Never>?
    @ObservationIgnored
    private var sideNotePlaque: WidgetBubbleContent?

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

    /// Spans (recording clock) of Daisy-key commands run during this
    /// meeting (K-3, «Команды во время встречи»): what was said to Daisy
    /// there is cut from the meeting like a moment's comment, and after
    /// the final pass its command-history entry gets the full-quality
    /// words — the live ones may have missed some.
    struct DaisyCommandSpan: Hashable {
        let span: DateInterval
        let entryID: UUID
    }
    var daisyCommandSpans: [DaisyCommandSpan] = []

    /// Dictations held over THIS recording (a meeting or a voice note),
    /// on its media clock: their spans are cut from its microphone lines
    /// (`DictationHolds`). Written to `dictation-holds.json` as each hold
    /// ends, so the final pass, the queue and a later retranscribe cut
    /// the same words.
    var dictationHolds: [DictationHold] = []
    /// The same holds on the live clock, for the live lines (in memory
    /// only — see THE CLOCKS in `DictationHolds`).
    var liveDictationHolds: [DictationHold] = []
    /// Where the dictation key went down over this recording; `nil` when
    /// no such hold is open. Cut live up to now, so the dictated words
    /// never show in the meeting's transcript.
    var openDictationHoldStart: DictationHoldMark?
    /// The final pass has replaced the live lines: the transcribers' lines
    /// are on the archives' timeline from here on, and so are the cuts.
    var linesAreOnArchiveTimeline = false

    // Re-exported recorder state.
    var elapsed: TimeInterval { recorder.elapsed }
    /// The recording's own clock as a date: `startedAt` plus media time.
    /// Segment dates are on this clock (`startedAt` + audio seconds), so
    /// spans compared with them are too — a wall-clock `Date()` runs ahead
    /// of them by every pause.
    var mediaNow: Date { mediaDate(elapsed) }
    func mediaDate(_ offset: TimeInterval) -> Date {
        (startedAt ?? Date()).addingTimeInterval(max(0, offset))
    }
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
    ///
    /// Lines that belong to something else are left out (backlog 34
    /// K-3): what was said to Daisy over a moment, and a side note's span
    /// when side notes are set to cut. Everything downstream — the live
    /// view, transcript.md, the summary, the stored session — reads the
    /// meeting from here; the side-note writer and the moment captions
    /// read `uncutSegments`.
    var segments: [TranscriptSegment] {
        let micV = micTranscriber.segmentsVersion
        let sysV = systemTranscriber.segmentsVersion
        let cuts = transcriptCutsKey
        if _segmentsCacheMicVersion == micV && _segmentsCacheSysVersion == sysV && _segmentsCacheCuts == cuts {
            return _segmentsCache
        }
        let merged = uncutSegments
        if cuts == nil {
            _segmentsCache = merged
        } else {
            let holds = DictationHoldCut.merged(cutDictationHolds, margin: DictationHoldCut.margin)
            _segmentsCache = merged.filter { !isCutFromMeeting($0, dictationSpans: holds) }
        }
        _segmentsCacheMicVersion = micV
        _segmentsCacheSysVersion = sysV
        _segmentsCacheCuts = cuts
        return _segmentsCache
    }
    @ObservationIgnored
    private var _segmentsCache: [TranscriptSegment] = []
    @ObservationIgnored
    private var _segmentsCacheCuts: Int? = nil

    /// Every line both transcribers hold, in time order, nothing cut.
    var uncutSegments: [TranscriptSegment] {
        (micTranscriber.segments + systemTranscriber.segments)
            .sorted(by: { $0.startedAt < $1.startedAt })
    }

    /// Identifies the spans currently cut from the meeting; `nil` when
    /// there are none (the common case: nothing is filtered at all).
    /// Part of every segment cache's key, so a new moment or a closed
    /// side note re-derives the transcript.
    var transcriptCutsKey: Int? {
        // Dictations cut from a meeting and from a voice note alike; the
        // rest belongs to meetings.
        let holds = cutDictationHolds
        let isMeeting = currentMode == .meeting
        let comments = isMeeting ? momentMarkers.filter { $0.commentStart != nil } : []
        let notes = isMeeting ? cutSideNoteWindows : []
        let commands = isMeeting ? daisyCommandSpans : []
        guard !comments.isEmpty || !notes.isEmpty || !commands.isEmpty || !holds.isEmpty else { return nil }
        var hasher = Hasher()
        for hold in holds {
            hasher.combine(hold)
        }
        for marker in comments {
            hasher.combine(marker.commentStart)
            hasher.combine(marker.commentEnd)
        }
        for command in commands {
            hasher.combine(command.span)
        }
        for window in notes {
            hasher.combine(window.start)
            hasher.combine(window.end)
        }
        return hasher.finalize()
    }

    /// The dictation spans cut from this recording: every finished hold,
    /// and an open one running on to the end of whatever is heard (it
    /// gets its real end at the release). Meetings and voice notes only.
    var cutDictationHolds: [DictationHold] {
        guard currentMode != .dictation else { return [] }
        let onTimeline = linesAreOnArchiveTimeline
        let closed = onTimeline ? dictationHolds : liveDictationHolds
        // An open hold counts only while the side dictation is actually
        // under way: a failed start whose key-up got lost would otherwise
        // hide every own-mic line until the next press (review 31.10).
        guard let open = openDictationHoldStart, sideDictationIsLive else { return closed }
        return closed + [DictationHold(startSec: onTimeline ? open.timeline : open.live, endSec: .greatestFiniteMagnitude)]
    }

    /// A dictation's line, a moment's comment, a command said to Daisy, or
    /// a cut side note's line (the same lines the note copied).
    /// `dictationSpans`: `cutDictationHolds`, already widened and merged.
    private func isCutFromMeeting(_ segment: TranscriptSegment, dictationSpans: [DictationHold]) -> Bool {
        if segment.source == .microphone, !dictationSpans.isEmpty,
           DictationHoldCut.isCut(start: segment.startSec, end: segment.endSec, by: dictationSpans) { return true }
        guard currentMode == .meeting else { return false }
        if momentMarkers.contains(where: { $0.owns(segment) }) { return true }
        if daisyCommandSpans.contains(where: { MomentMarker.isComment(segment, from: $0.span.start, to: $0.span.end) }) { return true }
        return cutSideNoteWindows.contains { Self.sideNote($0, covers: segment) }
    }

    /// The lines a side note copies: those that start inside its window.
    nonisolated static func sideNote(_ window: SideNoteWindow, covers segment: TranscriptSegment) -> Bool {
        segment.startedAt >= window.start && segment.startedAt <= (window.end ?? .distantFuture)
            && !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
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
        let cuts = transcriptCutsKey
        if _displayCacheMicVersion == micV && _displayCacheSysVersion == sysV && _displayCacheCuts == cuts {
            return _displayCache
        }
        let filtered = segments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        _displayCache = filtered
        _displayCacheMicVersion = micV
        _displayCacheSysVersion = sysV
        _displayCacheCuts = cuts
        return _displayCache
    }
    @ObservationIgnored
    private var _displayCacheCuts: Int? = nil
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
        let cuts = transcriptCutsKey
        if _dedupCacheMicVersion == micV && _dedupCacheSysVersion == sysV && _dedupCacheCuts == cuts {
            return _dedupCache
        }
        // `filteredQuietly`, not `filter`: `lastFilterWasSystemic` is the
        // render's to set, and `stop()` reads it in the gap between the
        // render and the headphones toast.
        let filtered = AcousticEchoDedup.filteredQuietly(all)
        _dedupCache = filtered
        _dedupCacheMicVersion = micV
        _dedupCacheSysVersion = sysV
        _dedupCacheCuts = cuts
        return filtered
    }
    @ObservationIgnored
    private var _dedupCacheCuts: Int? = nil
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
        persistedKindOverride ?? (currentMode == .voiceNote ? .note : .recording)
    }

    /// Set when the post-stop pipeline finds that the person moved this
    /// session between Library and Notes while it was running — the
    /// kind is otherwise derived from the recording mode, which by then
    /// no longer reflects where the session lives. Cleared on `reset()`.
    @ObservationIgnored
    var persistedKindOverride: SessionKind?

    /// Mode the next `start()` should adopt. Set by mode-specific
    /// entry points (`toggleVoiceNoteByHotkey`, etc.) right before
    /// they call `start()`, consumed inside `start()` after
    /// `reset()`. Same pattern as `pendingBoundMeeting` —
    /// `reset()` clears the live value, the pending channel
    /// survives the wipe.
    @ObservationIgnored
    // internal for RecordingSession+Hotkeys.swift
    var pendingMode: RecordingMode?

    /// Set when the dictation key is released while `start()` is still
    /// in `.preparing` — i.e. the person let go before the engine
    /// finished loading. Since 27.10 it cancels the start
    /// (`requestDictationStartCancel`): a model wait ends at once and the
    /// microphone never opens. Only a start that got past every check
    /// before the release landed (a Daisy-key hold let go before
    /// `.preparing`) still sees it in `startDictationHotkey` the moment
    /// `start()` returns, which then stops immediately.
    ///
    /// Without it the release was simply dropped (`stopDictationHotkey`
    /// only accepts `.recording`/`.paused`), and `start()` went on to
    /// open a microphone nobody was holding a key for: the macOS
    /// recording indicator on, no way to stop it, and the next press
    /// answering "Daisy is already recording" — the bug wearing another
    /// bug's face. First-ever dictation is the common case, where
    /// `ensureLoaded` can take minutes to pull a model
    /// (audit 2026-09-01).
    @ObservationIgnored
    // internal for RecordingSession+Hotkeys.swift
    var dictationReleasedWhilePreparing = false

    /// Ends the model wait `start()` is suspended in, when that start is a
    /// dictation (`awaitStartStep`). Set only for the duration of a wait.
    @ObservationIgnored
    private var cancelStartWait: (@MainActor () -> Void)?

    /// The dictation key came up (or came down again) while this start was
    /// still waiting for a speech model: the microphone isn't open yet, so
    /// there is nothing to transcribe — the start is dropped now instead of
    /// spinning until the model is ready and then stopping at once (field
    /// report 27.10: «иконка крутится … никак не могу её остановить»).
    /// Before `.preparing` the flag alone does it: the first model wait
    /// checks it, and with no wait `start()` checks it before the
    /// microphone opens.
    func requestDictationStartCancel() {
        dictationReleasedWhilePreparing = true
        cancelStartWait?()
    }

    /// A dictation held while the previous recording is still being
    /// finished runs HERE — a second session of its own, with its own
    /// microphone and transcriber — so it no longer cancels that
    /// finishing (Egor, 24.09: a dictation right after a meeting threw
    /// away the meeting's final pass and summary; the queue redid them
    /// a minute later). Made on first need, kept for the next one.
    /// The floating widget shows it while it dictates.
    var sideDictation: RecordingSession?
    /// The side dictation is dictating, or its start is queued or under way.
    var sideDictationIsLive: Bool {
        guard let side = sideDictation else { return false }
        return side.isDictating || side.pendingMode == .dictation || side.startingMode == .dictation
    }
    /// On a side dictation: the session whose recording (a meeting or a
    /// voice note) this dictation was held over — the dictation key during
    /// a recording (31.10). `nil` for one held while the previous
    /// recording finishes. Weak: the main session owns its side.
    weak var dictationHost: RecordingSession?
    /// This side dictation runs while its host still captures (recording
    /// or paused). It then keeps out of the host's way: the archive clock
    /// (`ArchiveOrigin`) stays the host's, no start sound (the host's
    /// microphone would record it, and over speakers the call hears it),
    /// no screenshots (the host takes them).
    var dictatesOverLiveRecording: Bool {
        guard isDictationSidecar, let host = dictationHost else { return false }
        return host.status == .recording || host.status == .paused
    }
    /// What this dictation's text is for: pasted (an ordinary dictation)
    /// or handed to the Daisy key (backlog 34). Set by every dictation
    /// start before `start()`, read and reset by `finishDictation`.
    var dictationPurpose: DictationPurpose = .paste
    /// A Daisy-key hold is what's capturing (the screenshot window's late
    /// hand-over takes only that, since K-3).
    var isDaisyKeyHold: Bool {
        if case .daisyKeyHold = dictationPurpose { return true }
        return false
    }
    /// This session IS such a side dictation: no auto-start/auto-stop
    /// listeners, no startup chores — the main session owns those.
    let isDictationSidecar: Bool

    /// Dictating right now, from key-down to paste.
    var isDictating: Bool {
        guard currentMode == .dictation else { return false }
        switch status {
        case .preparing, .recording, .paused, .stopping: return true
        case .idle, .finished, .failed, .summarizing: return false
        }
    }

    /// Where this session announces its live folder to the Library — a
    /// side dictation in a slot of its own, so the finishing meeting's
    /// folder keeps its protection while both are live.
    var liveDirName: String? {
        get { isDictationSidecar ? SessionStore.shared.sideRecordingDirName : SessionStore.shared.activeRecordingDirName }
        set {
            if isDictationSidecar { SessionStore.shared.sideRecordingDirName = newValue }
            else { SessionStore.shared.activeRecordingDirName = newValue }
        }
    }

    /// The session the widget should show: the side dictation while it
    /// runs, otherwise this one.
    var displaySession: RecordingSession {
        if let side = sideDictation, side.isDictating { return side }
        return self
    }

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
    /// The next start comes from the calendar (auto-start, or its prompt
    /// answered) — for the anonymous counts only (ImprovementStats).
    var nextStartFromCalendar = false
    /// The back-to-back meeting we've already asked about (its
    /// `localID`), so the 15 s calendar re-tick doesn't re-raise the
    /// «Next meeting — switch recording?» pill every time. Cleared with
    /// the rest of the pending state in `reset()`.
    private var rotationAskedFor: String?
    static let rotationAskBubbleTag = "autostart-rotate"

    /// Weak app-wide handle to the live session, set by `DaisyApp.init`.
    /// Lets the terminate handler (DaisyAppDelegate.applicationShouldTerminate)
    /// confirm + finalize an in-progress recording on Quit without plumbing
    /// the instance through the NSApplicationDelegateAdaptor. Weak so the
    /// app's `@State` reference remains the owner.
    static weak var current: RecordingSession?

    /// A recording is capturing (and transcribing live) right now — what the
    /// local summary model waits out on a Mac with 16 GB or less.
    static var isRecordingLive: Bool {
        switch current?.status {
        case .preparing, .recording, .paused: return true
        default: return false
        }
    }

    /// True while any part of the pipeline is holding audio: a live
    /// recording, a stop that's still finalizing, or a standalone
    /// re-transcription. Read by the memory-pressure handler, which must
    /// never pull a model out from under a decode in flight.
    static var isCapturingOrTranscribing: Bool {
        if SessionAudioProcessing.shared.isRunning { return true }
        guard let current else { return false }
        if current.summaryTask != nil { return true }
        if current.sideDictation?.isDictating == true { return true }
        switch current.status {
        case .preparing, .recording, .paused, .stopping, .summarizing: return true
        case .idle, .finished, .failed: return false
        }
    }

    init(settings: AppSettings, localeIdentifier: String? = nil, isDictationSidecar: Bool = false) {
        self.settings = settings
        self.isDictationSidecar = isDictationSidecar
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
        // The display came back and so did the loopback. The person was
        // told they'd lost the other side; tell them it's back, where
        // they are — the bubble, not the window.
        self.systemAudio.onCaptureRecovered = { [weak self] in
            guard let self, self.status == .recording else { return }
            self.log.notice("System audio capture recovered mid-session")
            WidgetBubbleCenter.shared.present(
                WidgetBubbleContent(
                    text: String(localized: "The other side is being recorded again."),
                    autoDismiss: 7
                ),
                notificationTitle: String(localized: "Daisy hears the other side again")
            )
        }

        // The mic recorder can decide to stop on its own — a route
        // change with nowhere to bind, a rebuild that failed, a unit
        // that never delivered a buffer. It used to keep that to
        // itself: nobody reads `recorder.state`, so the session stayed
        // `.recording` and the widget kept claiming a live recording
        // with a frozen clock while nothing was being captured
        // (audit 2026-09-01).
        self.recorder.onFellToPaused = { [weak self] reason in
            self?.handleMicFellToPaused(reason)
        }

        // A side dictation borrows everything app-wide from the main
        // session; answering the auto-start/auto-stop prompts too would
        // have two sessions acting on one tap.
        guard !isDictationSidecar else { return }

        // Preload the Whisper + diarization models so the first Record click
        // is instant. An XCTest bundle is hosted inside Daisy.app, however,
        // and must reach the test runner before app-startup model I/O begins.
        // Otherwise a slow or unavailable model volume can block every unit
        // test at "waiting for workers to materialize" without running one.
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isRunningTests {
            if settings.hasShownFirstRun {
                Task { await WhisperEngine.shared.ensureLoaded() }
            }
            // The diarizer is NOT preloaded any more. It's needed only
            // once a meeting with system audio is under way, and both
            // entry points (`makeBlockPass`, `diarizeFull`) load it
            // themselves — so preloading only ever meant hundreds of
            // megabytes resident on machines that never record
            // (audit 2026-09-01).
            MemoryPressureWatch.start()
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

        // A person who pressed Start in the preparation sheet while a
        // recording is running has already answered "switch?".
        await performStartFromMeeting(meeting, preparation: preparation, rotateWithoutAsking: userInitiated)
    }

    /// The actual calendar-bound start (and back-to-back rotation),
    /// bypassing the policy gate. Called directly by `startFromMeeting`
    /// in Always/Selective modes, and by `consumePendingAutoStartTrigger`
    /// when the user taps Record in Prompt mode.
    private func performStartFromMeeting(
        _ meeting: DaisyMeeting,
        preparation suppliedPreparation: MeetingPreparationSnapshot? = nil,
        rotateWithoutAsking: Bool = false
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
            // Back-to-back meetings: ASK before rotating (tester report,
            // 2026-09-15). Rotating silently ended the first call's
            // recording while the person was still on it — the only
            // notice was a toast in a window they weren't looking at —
            // and the next session collected the tail of the wrong
            // conversation. Tap the pill to switch; ✕ or ignore keeps
            // recording the current one. Asked once per meeting (the
            // calendar fires each event once; the latch is for the
            // preparation sheet's second press).
            //
            // The widget has ONE bubble slot, and the end-of-meeting
            // «Stop & save?» for the current meeting arrives at about
            // the same moment by construction. Whichever pill is up,
            // the trigger stays pending: answering «Stop & save» while a
            // next meeting waits starts that meeting right after the
            // stop (`startPendingCalendarMeetingIfLive`), so neither
            // order loses the second recording.
            if !rotateWithoutAsking {
                guard rotationAskedFor != meeting.localID else { return }
                rotationAskedFor = meeting.localID
                pendingAutoStartTrigger = .calendar(meeting)
                log.notice("Calendar fired \(meeting.title, privacy: .private) while still recording \(oldTitle, privacy: .private) — asking before rotating")
                if autoStopWarned {
                    log.info("End-of-meeting ask is already up — the next meeting waits behind it")
                    return
                }
                let text = String(localized: "Next meeting — switch recording?")
                let shown = WidgetBubbleCenter.shared.show(WidgetBubbleContent(
                    text: text,
                    actionTitle: String(localized: "Switch"),
                    actionSymbol: "arrow.triangle.2.circlepath",
                    autoDismiss: 30,
                    tag: Self.rotationAskBubbleTag,
                    action: { [weak self] in
                        Task { @MainActor [weak self] in
                            await self?.consumePendingAutoStartTrigger()
                        }
                    }
                ))
                if !shown {
                    AutoStartPromptNotification.post(subject: meeting.title)
                }
                return
            }
            log.warning("Rotating sessions: \(oldTitle, privacy: .private) → \(meeting.title, privacy: .private) (user confirmed)")
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
        // toggle in Settings → General → Notifications — and on the
        // recording having actually started: `start()` can refuse (model
        // can't load, mic denied) or fail, and its own bubble says so.
        // `show` replaces whatever bubble is up, so announcing
        // "Recording started" here unconditionally would paint over
        // that explanation with a claim that nothing is recording.
        if settings.notifyOnAutoStart, status == .recording {
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

    /// After a stop that the person confirmed while a back-to-back
    /// meeting was waiting behind the ask: start that meeting now, if
    /// it is still in progress. This is what the silent rotation used
    /// to do — minus the part where it cut the first call short.
    var hasPendingLiveCalendarMeeting: Bool {
        if case .calendar(let meeting)? = pendingAutoStartTrigger { return Date() < meeting.endDate }
        return false
    }

    func startPendingCalendarMeetingIfLive() async {
        guard case .calendar(let meeting)? = pendingAutoStartTrigger,
              Date() < meeting.endDate else { return }
        pendingAutoStartTrigger = nil
        WidgetBubbleCenter.shared.dismiss(tag: Self.rotationAskBubbleTag)
        AutoStartPromptNotification.cancel()
        log.notice("Starting the meeting that waited behind the end-of-meeting ask: \(meeting.title, privacy: .private)")
        await performStartFromMeeting(meeting, rotateWithoutAsking: true)
    }

    /// User tapped "Record" on the prompt — start whatever was pending.
    /// No-op (with a cancel of any stray banner) if the trigger is gone
    /// or we're somehow already recording, so a stale tap can't double-
    /// start or rotate unexpectedly.
    private func consumePendingAutoStartTrigger() async {
        AutoStartPromptNotification.cancel()
        WidgetBubbleCenter.shared.dismiss(tag: Self.autoStartAskBubbleTag)
        WidgetBubbleCenter.shared.dismiss(tag: Self.rotationAskBubbleTag)
        guard let trigger = pendingAutoStartTrigger else { return }
        pendingAutoStartTrigger = nil
        nextStartFromCalendar = true
        switch trigger {
        case .calendar(let meeting):
            // Re-use the full calendar path (binding, auto-stop arming,
            // back-to-back rotation) — just bypassing the prompt gate.
            // The person tapped: if we're still recording, that tap IS
            // the answer to «switch?», so rotate without asking again.
            await performStartFromMeeting(meeting, rotateWithoutAsking: true)
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
        let message = String(localized: "The microphone is set to “\(deviceName)” — a virtual audio device. If the recording comes out empty, pick your microphone in \(SettingsRow.microphone.path).")
        _ = WidgetBubbleCenter.shared.show(
            WidgetBubbleContent(text: message, autoDismiss: 12, tag: Self.virtualInputBubbleTag)
        )
        ToastCenter.shared.showAction(
            message,
            actionLabel: String(localized: "Open audio settings"),
            style: .warning,
            duration: .seconds(12)
        ) {
            AppNavigation.shared.openInSettings(.meetings, row: .microphone)
        }
    }

    /// Tag for the virtual-input bubble, so it can never be withdrawn by
    /// another prompt's `dismiss(tag:)`.
    private static let virtualInputBubbleTag = "virtual-input-warning"

    /// B-2 (19.10): once per headset, at the start of a meeting, when the
    /// SYSTEM default input — not necessarily Daisy's microphone — is a
    /// Bluetooth headset: that is what the call app takes, and what flips
    /// the headset into 16 kHz headset mode (user log B, WH-1000XM4). The
    /// remedy is in System Settings → Sound → Input, so the button opens it.
    private func hintIfSystemInputIsBluetoothHeadset() {
        guard currentMode == .meeting else { return }
        let deviceID = AudioInputDevices.systemDefaultInputID()
        guard deviceID != 0 else { return }
        // `isBluetooth` looks inside an aggregate too; the label is for the log.
        let transport = AudioInputDevices.isBluetooth(deviceID) ? "bluetooth" : AudioInputDevices.transportLabel(deviceID)
        let uid = AudioInputDevices.uid(for: deviceID) ?? ""
        let defaults = UserDefaults.standard
        let shown = Set(defaults.stringArray(forKey: BluetoothInputHint.shownKey) ?? [])
        guard BluetoothInputHint.shouldShow(transport: transport, uid: uid, shown: shown) else { return }
        let name = AudioInputDevices.name(for: deviceID) ?? "Bluetooth"
        log.notice("System default input is a Bluetooth headset (\(name, privacy: .public), \(transport, privacy: .public)) — one-time hint to pick the built-in microphone")
        let message = String(localized: "To keep your headphones from switching to headset mode during the call, pick the built-in microphone in System Settings → Sound → Input.")
        let open = String(localized: "Open System Settings")
        // A recording mostly starts from a hotkey, the widget or the
        // calendar with the window closed, and the toast lives in the
        // window: the pill carries it there, a notification when there
        // is no pill — as the virtual-input and low-disk warnings do.
        // Only then is the headset marked as told.
        WidgetBubbleCenter.shared.present(
            WidgetBubbleContent(text: message, actionTitle: open, autoDismiss: 15, tag: Self.bluetoothInputBubbleTag,
                                action: { BluetoothInputHint.openSoundSettings() }),
            notificationTitle: String(localized: "Headphones as the microphone")
        )
        ToastCenter.shared.showAction(message, actionLabel: open, style: .info, duration: .seconds(12)) {
            BluetoothInputHint.openSoundSettings()
        }
        defaults.set(Array(shown.union([uid])).sorted(), forKey: BluetoothInputHint.shownKey)
    }

    private static let bluetoothInputBubbleTag = "bluetooth-input-hint"

    /// Set when `start()` already warned about a closed lid, so the
    /// silence watchdog 10 s later doesn't repeat the same toast.
    @ObservationIgnored
    var clamshellWarned = false

    /// Set when `start()` already warned that this session records no
    /// audio because the disk is nearly full.
    ///
    /// `CaptureProblemNotification` is a single slot — one request id,
    /// one bubble tag — so these warnings have to queue by severity
    /// rather than by arrival. The order, worst first:
    ///
    ///   1. clamshell — nothing is being recorded at all;
    ///   2. low disk — the transcript survives, the audio is never written;
    ///   3. mic-only — half the conversation is captured.
    ///
    /// Each one refuses to post over a worse one already shown.
    @ObservationIgnored
    var lowDiskWarned = false

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

    /// What `start()` decides before it touches any state: go ahead, or
    /// refuse — and why. Pure, so the refusals can be tested without a
    /// microphone, a model on disk, or a network.
    ///
    /// The only two refusals are the ones where waiting cannot help. A
    /// model that is merely not loaded yet — the first seconds after
    /// launch, a cold reload after memory pressure, a download in
    /// flight — is NOT a refusal: `start()` waits for it further down,
    /// with the explainer toast and the cold-start retries. Refusing
    /// there is what 1.0.7.71 did, and it meant a calendar auto-start a
    /// minute after the Mac booted silently recorded nothing.
    nonisolated enum StartPreflight: Equatable {
        case proceed
        /// Onboarding was never completed — not finished, not skipped.
        case onboardingIncomplete
        /// The speech model isn't on disk and there's no network to
        /// fetch it. Nothing `start()` could wait for would change that.
        case modelCannotLoad
        /// Whisper can't decode on this Mac at all (Intel —
        /// `WhisperEngine.runsOnThisMac`). Not a repair: Settings can't fix
        /// it, so it's said, not sent there.
        case macUnsupported

        static func decide(
            hasShownFirstRun: Bool,
            whisperState: WhisperEngine.LoadState,
            modelIsCached: Bool,
            isOnline: Bool,
            whisperRequired: Bool = true,
            whisperRunsHere: Bool = true
        ) -> StartPreflight {
            guard hasShownFirstRun else { return .onboardingIncomplete }
            guard whisperRequired else { return .proceed }
            if !whisperRunsHere { return .macUnsupported }
            if case .ready = whisperState { return .proceed }
            if !modelIsCached && !isOnline { return .modelCannotLoad }
            return .proceed
        }
    }

    /// `start()` is past its guards and yielding the Whisper engine from
    /// a stored-audio job (up to 2 s) — `status` is still `.idle`, so
    /// this is what keeps a second press out.
    /// Readable by `SessionAudioProcessing.recordingOrFinalizeIsActive`:
    /// `start()` nils `summaryTask` on its way in, which the queue
    /// observes as "the finalize is over" — and from that moment until
    /// `.preparing` this is what says a recording is coming (review
    /// 20.10).
    private(set) var isStarting = false
    /// The mode that start is going to be, from the moment it took its
    /// pending intent until `.preparing`: `stopDictationHotkey` reads
    /// `pendingMode == .dictation` to tell a release during a start from
    /// a stray one, and the intent is no longer there by then.
    private(set) var startingMode: RecordingMode?

    /// Drop everything a hotkey or calendar trigger queued for this
    /// start. A refused start must not leave `.dictation` pending for
    /// the next Record click to pick up.
    private func clearPendingStart() {
        pendingMode = nil
        pendingBoundMeeting = nil
        pendingFolderHint = nil
        pendingMeetingPreparation = nil
    }

    /// The speech model can't be used and won't become usable on its
    /// own: say so where the user is (toast in-app, a bubble +
    /// notification when the trigger came from a hotkey or the calendar
    /// with no window in front), and open the screen that repairs it.
    private func presentSpeechModelUnavailable() {
        let message = String(localized: "The speech model is not ready. Open \(SettingsRow.meetingModel.path) to prepare or repair it.")
        ToastCenter.shared.show(message, style: .warning)
        WidgetBubbleCenter.shared.present(WidgetBubbleContent(text: message),
            notificationTitle: String(localized: "Prepare Daisy"))
        AppNavigation.shared.openInSettings(.meetings, row: .meetingModel)
    }

    /// Whisper can't run on this Mac (`WhisperEngine.runsOnThisMac`): where
    /// the person is — toast in the window, the pill (or a notification)
    /// for a key pressed in another app. Nothing to open: no setting fixes it.
    private func presentWhisperUnsupportedOnThisMac() {
        let message = WhisperEngineError.unsupportedMac.localizedDescription
        ToastCenter.shared.show(message, style: .warning)
        WidgetBubbleCenter.shared.present(WidgetBubbleContent(text: message),
            notificationTitle: String(localized: "Daisy"))
    }

    static var dictationNeedsFastEngineMessage: String {
        String(localized: "Dictation can’t start: on an Intel Mac it needs Faster or Apple dictation ready. Check \(SettingsRow.dictationEngine.path).")
    }

    /// A dictation refused on an Intel Mac: Whisper can't run there, and
    /// the dictation engine that can wasn't ready. Says which row fixes it,
    /// with a button; a screenshot note claimed at key-down gets its pill
    /// back, and a Daisy-key press doesn't leave its bookkeeping behind.
    private func refuseDictationOnUnsupportedMac() {
        if let pending = pendingScreenshotNote {
            pendingScreenshotNote = nil
            ScreenshotNoteCapture.shared.restorePending(pending)
        }
        let purpose = dictationPurpose
        dictationPurpose = .paste
        switch purpose {
        case .daisyKeyTap(let token):
            // A tap needs no speech model: it still fixes the layout.
            DaisyKeyController.shared.tapCaptureFinished(token: token, on: self)
            return
        case .daisyKeyHold(let token):
            // Refused at key-down, before a tap is known: the key's
            // release decides — a tap fixes the layout, a hold says why.
            DaisyKeyController.shared.startRefused(token: token)
            return
        case .paste:
            break
        }
        var content = WidgetBubbleContent(text: Self.dictationNeedsFastEngineMessage)
        content.actionTitle = String(localized: "Open Settings")
        content.action = { AppNavigation.shared.openInSettings(.dictation, row: .dictationEngine) }
        WidgetBubbleCenter.shared.present(content, notificationTitle: String(localized: "Daisy"))
    }

    /// The same words on the widget's pill, with the way to Settings as a
    /// button instead of opening it — for a moment the person is in another
    /// app and didn't ask for a window (a dictation's release, a dictation
    /// start they let go of).
    func presentSpeechModelNotReadyPill() {
        var content = WidgetBubbleContent(
            text: String(localized: "The speech model is not ready. Open \(SettingsRow.meetingModel.path) to prepare or repair it.")
        )
        content.actionTitle = String(localized: "Open Settings")
        content.action = { AppNavigation.shared.openInSettings(.meetings, row: .meetingModel) }
        WidgetBubbleCenter.shared.present(content, notificationTitle: String(localized: "Prepare Daisy"))
    }

    func start() async {
        let fromCalendar = nextStartFromCalendar
        nextStartFromCalendar = false
        // One microphone, one recording: a meeting can wait the seconds
        // a side dictation takes.
        if let side = sideDictation, side.isDictating {
            clearPendingStart()
            ToastCenter.shared.show(String(localized: "Finish the dictation first."), style: .info)
            return
        }
        let whisperState = WhisperEngine.shared.state
        // The cache check reads a dozen files; a ready model doesn't
        // need it (the decision is `.proceed` either way), and that's
        // the state nearly every start sees.
        let modelIsCached = whisperState == .ready
            || WhisperEngine.cachedModelFolder(variant: WhisperEngine.shared.modelID) != nil
        let preflight = StartPreflight.decide(
            // The tour records for real (dictation, the Daisy key, a
            // meeting) before first run is marked done.
            hasShownFirstRun: settings.hasShownFirstRun || OnboardingTourController.shared.isActive,
            whisperState: whisperState,
            modelIsCached: modelIsCached,
            isOnline: NetworkMonitor.shared.isOnline,
            // A dictation on Parakeet or Apple's engine may not need Whisper
            // at all; whether it does is decided after `.preparing`
            // (`dictationModelPlan`), where a Whisper that can't load
            // still refuses it the same way.
            whisperRequired: !(pendingMode == .dictation && settings.dictationEngine != .whisper),
            whisperRunsHere: WhisperEngine.runsOnThisMac
        )
        switch preflight {
        case .proceed:
            break
        case .onboardingIncomplete:
            clearPendingStart()
            ToastCenter.shared.show(String(localized: "Finish preparing Daisy before recording."), style: .info)
            return
        case .modelCannotLoad:
            clearPendingStart()
            log.error("Start refused — speech model not cached and offline")
            presentSpeechModelUnavailable()
            return
        case .macUnsupported:
            let wasDictation = pendingMode == .dictation
            clearPendingStart()
            log.error("Start refused — Whisper can't decode on this Mac (x86_64)")
            if wasDictation {
                refuseDictationOnUnsupportedMac()
            } else {
                presentWhisperUnsupportedOnThisMac()
            }
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

        guard status == .idle || status == .finished || isFailed else {
            // A hotkey pressed mid-recording queued `.dictation`; it must
            // not lie in wait for the next Record click.
            clearPendingStart()
            return
        }

        // Stored-audio transcription temporarily owns the shared Whisper
        // engine and can load a second CoreML graph. Until 19.10 Record
        // was refused while it ran («Wait for stored audio processing to
        // finish») — the person whose meeting was starting saw a
        // sentence that named nothing they had asked for and gave no
        // time (user log A: a 70-minute meeting's final pass, after the
        // next recording had already been queued behind it). Now the
        // recording wins: the job is stopped — it writes to hidden
        // staging and commits at the end, so nothing half-done lands and
        // the model it loaded is released — its owner keeps it for after
        // the recording, and a toast names it. An audio export is a few
        // seconds of disk work without Whisper and runs alongside.
        // The wait below is the first routine suspension before
        // `.preparing`; a second press in it must not start a second
        // recorder (review 19.10) — it's a double-click, ignored, and
        // whatever it queued for itself goes (its screenshot claim back
        // to the pill, as `failFast` does).
        guard !isStarting else {
            log.info("Start ignored: another start is in flight (\(String(describing: self.pendingMode), privacy: .public) pending)")
            clearPendingStart()
            if let p = pendingScreenshotNote {
                pendingScreenshotNote = nil
                ScreenshotNoteCapture.shared.restorePending(p)
            }
            return
        }
        isStarting = true
        // What this start was asked to be — taken now, before the first
        // suspension, so a different trigger landing during the wait
        // (a dictation hotkey over a Record click, a calendar meeting
        // over a voice note) can't rewrite it under us. Applied after
        // `reset()` below, which would erase it if applied here.
        let intent = (mode: pendingMode, meeting: pendingBoundMeeting,
                      folderHint: pendingFolderHint, preparation: pendingMeetingPreparation)
        clearPendingStart()
        startingMode = intent.mode
        let processing = SessionAudioProcessing.shared
        defer {
            isStarting = false
            startingMode = nil
            processing.yieldToRecordingEnded()
            // A start that bailed after the yield gives the queue its
            // turn back now rather than at the next minute's poll.
            ImportTranscriptionQueue.shared.kick()
        }
        if processing.isRunning, !processing.isExporting, let yielded = processing.yieldToRecording() {
            // Whisper checks for cancellation between speech spans and
            // the job between blocks, so it often unwinds within the two
            // seconds — not always (one long span, a file copy). Past
            // that, start anyway: a live pass takes priority inside the
            // engine, and the final pass is on its way out.
            let deadline = ContinuousClock.now + .seconds(2)
            while processing.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if processing.isRunning {
                log.warning("Stored-audio job still unwinding 2 s after yielding to the recording — starting anyway")
            } else {
                log.info("Stored-audio job stopped for the recording")
            }
            if let notice = SessionAudioProcessing.interruptionNotice(for: yielded) {
                ToastCenter.shared.show(notice, style: .info, duration: .seconds(5))
            }
        }

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
                clearPendingStart()
                showMicBlockedToast()
                return
            }
        case .denied, .restricted:
            log.error("Mic permission is \(SystemPermissions.micAuthorizationDescription(), privacy: .public) — refusing to start a silent recording")
            clearPendingStart()
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
        lowDiskWarned = false
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
        if let m = intent.meeting {
            boundMeeting = m
            // Auto-suggest client tag from attendee domains. The
            // user can override in SessionDetailView; this just
            // pre-fills with a sensible guess so most meetings end
            // up tagged without any manual work.
            if tag.isEmpty, let suggested = TagSuggestion.suggest(from: m.attendeeEmails) {
                tag = suggested
            }
        }
        if let preparation = intent.preparation {
            meetingPreparationSnapshot = preparation
            // Explicit preparation wins over automatic folder/tag hints.
            folder = FolderStore.shared.existingFolder(slug: preparation.projectSlug) ?? .inbox
            tag = preparation.tag
        }
        if let hint = intent.folderHint {
            if meetingPreparationSnapshot == nil, folder == .inbox { folder = hint }
        }
        if let mode = intent.mode {
            currentMode = mode
        } else {
            currentMode = .meeting
        }
        // A voice note nobody filed goes to the default notes project
        // (Settings → Projects; Inbox unless set).
        if currentMode == .voiceNote, folder == .inbox, meetingPreparationSnapshot == nil {
            folder = FolderStore.shared.existingFolder(slug: FolderStore.shared.defaultNoteFolderSlug) ?? .inbox
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

        // The system's input is a Bluetooth headset: the call app will
        // flip it to headset mode, see `BluetoothInputHint`. After the
        // mode pickup above — a meeting's concern, not a dictation's.
        hintIfSystemInputIsBluetoothHeadset()

        status = .preparing

        // What this start waits for before the microphone opens. A
        // meeting, a voice note and a Whisper dictation need Whisper; a
        // dictation on Parakeet or Apple's engine needs only its own
        // engine (field report 27.10: a dictation on a ready Parakeet sat
        // behind a meeting model that couldn't load — the widget spun for
        // a minute and the start was refused). Whisper stays the
        // fallback: a Parakeet that can't load, or an Apple model that
        // isn't installed, sends this dictation to Whisper as before.
        // Parakeet is NOT preloaded at launch (Whisper is), so the first
        // dictation after a launch usually finds it `.notLoaded`: a cached
        // load is a few seconds and worth waiting for, a first-ever
        // ~600 MB download is not (`DictationModelGate`).
        var needsWhisper = true
        if currentMode == .dictation {
            switch await dictationModelPlan() {
            case .none:
                needsWhisper = false
            case .loadParakeet:
                guard await awaitStartStep({ await ParakeetEngine.shared.ensureLoaded() }, whisper: false) else {
                    await abandonDictationStart(waitedForWhisper: false)
                    return
                }
                if ParakeetEngine.shared.isReady {
                    needsWhisper = false
                } else if case .failed(let reason) = ParakeetEngine.shared.state {
                    log.warning("Parakeet unavailable for this dictation — Whisper fallback: \(reason, privacy: .public)")
                }
            case .whisper:
                break
            }
        }

        // A fast-engine dictation that turned out to need Whisper after all
        // (Parakeet downloading or failed, Apple's model not installed) on
        // a Mac where Whisper can't run: said plainly, not «repair it».
        if needsWhisper && !WhisperEngine.runsOnThisMac {
            if dictationPurpose == .paste {
                await failFast(Self.dictationNeedsFastEngineMessage)
            } else {
                // A Daisy-key press, likely still held: no failure state —
                // a tap still has its layout fix to do. Back to idle.
                dictationReleasedWhilePreparing = false
                await unwindStart()
                status = .idle
            }
            refuseDictationOnUnsupportedMac()
            return
        }

        if needsWhisper {
            // First-record explainer toast.
            //
            // If Whisper isn't yet `.ready`, the user is about to wait
            // 1-3 minutes while the 626 MB model downloads + CoreML loads.
            // The widget centre + tooltip surface the live progress, but
            // a one-shot toast at the moment of click gives the user a
            // concrete "how long" so they don't think the app is hung.
            // Skip the toast when prewarm has already finished — most
            // sessions land in `.ready` here, and a "model is loading"
            // toast on a sub-second startup would be noise. A dictation
            // gets the caption over the widget instead (`awaitStartStep`):
            // it's started from another app, where a window toast is
            // invisible.
            if currentMode != .dictation {
                switch WhisperEngine.shared.state {
                case .notLoaded, .downloading, .loading:
                    ToastCenter.shared.show(
                        String(localized: "Setting up transcription model — first run only, about 1–3 minutes"),
                        style: .info
                    )
                case .ready, .failed:
                    break
                }
            }

            // Make sure Whisper is ready before we tap the mic — otherwise the
            // user sees "Recording…" with nothing happening. A failure exits
            // through `failFast(_:)`, a dictation let go of through
            // `abandonDictationStart` — both unwind the same way
            // (`unwindStart`), so nothing half-started is left behind.
            if !WhisperEngine.shared.isReady {
                guard await awaitStartStep({ await WhisperEngine.shared.ensureLoaded() }) else {
                    await abandonDictationStart(waitedForWhisper: true)
                    return
                }
            }
            // Cold-restart race: the very first model load right after an app
            // restart can briefly land not-ready or transiently failed, which
            // surfaced as a red "Try again" button that just works on the second
            // tap (Egor 2026-06-16). Auto-do that retry — up to twice, letting
            // the in-flight load settle between attempts (a second ensureLoaded
            // re-runs performLoad once the first task has cleared). Only the
            // not-ready path pays this; a warm engine skips it entirely.
            var whisperRetries = 0
            while !WhisperEngine.shared.isReady && whisperRetries < 2 {
                // A hard `.failed` after a completed load is a broken model or
                // a CoreML refusal, and repeating a full large-v3 load twice
                // more just triples the wait under "1–3 minutes". One retry
                // covers the cold-restart race; the second only ever ran for
                // deterministic failures.
                if case .failed = WhisperEngine.shared.state, whisperRetries >= 1 { break }
                whisperRetries += 1
                guard await awaitStartStep({
                    try? await Task.sleep(for: .milliseconds(300))
                    await WhisperEngine.shared.ensureLoaded()
                }) else {
                    await abandonDictationStart(waitedForWhisper: true)
                    return
                }
            }
            if case .failed(let msg) = WhisperEngine.shared.state {
                // We waited and retried; it still can't load. This is the
                // "loading is impossible" case (no disk, offline with no
                // cache, a broken download) — the one refusal worth pointing
                // at the repair screen, and worth a notification for a
                // calendar auto-start nobody is watching.
                await failFast(String(localized: "Whisper model failed to load: \(msg)"))
                presentSpeechModelUnavailable()
                return
            }
            guard WhisperEngine.shared.isReady else {
                await failFast(String(localized: "Whisper model isn't ready yet — try again in a moment."))
                return
            }
        }

        // The dictation key came up before `.preparing` (the stored-audio
        // yield, the microphone prompt) and no model wait was needed to
        // notice: drop the start before the microphone opens. Only the
        // dictation key — a Daisy-key hold let go here still runs as
        // before (start, then stop), where a silent hold over a selection
        // is the rewrite gesture.
        if currentMode == .dictation, dictationReleasedWhilePreparing, dictationPurpose == .paste {
            await abandonDictationStart(waitedForWhisper: nil)
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
        daisyCommandSpans = []
        dictationHolds = []
        liveDictationHolds = []
        openDictationHoldStart = nil
        linesAreOnArchiveTimeline = false

        // Tell SessionStore which visible folder is live. Refresh can show it,
        // but interrupted-recording recovery and every bulk-delete path must
        // leave the open `.caf` descriptors alone until Stop finishes.
        liveDirName = dir?.lastPathComponent

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
            let message = String(
                format: String(localized: "Low disk space (%.1f GB free) — recording transcript only this session, no audio. Free up space to record audio again."),
                freeGB
            )
            ToastCenter.shared.show(message, style: .warning, duration: .seconds(6))
            // …and again through the channel that works when the main
            // window is closed, which is nearly always: recording starts
            // from a hotkey, the widget or a calendar auto-start, and
            // `ToastOverlay` lives inside the window. Four meetings were
            // recorded silently at 0.4 GB free before anyone noticed
            // (field report 2026-07-27) — the warning was there, it just
            // had nowhere to appear.
            //
            // Yields to the clamshell warning raised moments earlier in
            // this same `start()`: they share one slot, and "Daisy can't
            // hear you" outranks "this one has no audio file". See
            // `lowDiskWarned`.
            lowDiskWarned = true
            if !clamshellWarned {
                CaptureProblemNotification.post(
                    title: String(localized: "Recording without audio"),
                    body: message
                )
            }
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
        // commits during the meeting. A dictation's tier comes from its
        // engine, not from this setting — see `liveTier(mode:…)`.
        let tier = Self.liveTier(
            mode: currentMode,
            setting: settings.liveTranscriptionTier,
            dictationEngine: settings.dictationEngine,
            nemotronLive: settings.dictationUseNemotronLive
        )
        // Per recording, like the tier: the transcribers outlive any one
        // session, and a Speakers toggle must reach the next recording.
        // Never for dictation: the paste would wait on a diarizer for a
        // text that has one speaker.
        micTranscriber.diarizationEnabled = currentMode != .dictation && settings.diarizeMicrophone
        systemTranscriber.diarizationEnabled = settings.diarizeRemoteSpeakers
        let micAudio = recorder.buffers
        // EXPERIMENTAL (dark): streaming Nemotron live preview for
        // dictation — replaces the Whisper live timer for this session
        // only; the pasted final text is unchanged. See NemotronLiveEngine.
        micTranscriber.dictationNemotronLive =
            currentMode == .dictation && settings.dictationUseNemotronLive
        // Live word-by-word caption for dictation — the native-macOS-
        // dictation experience (Egor, 2026-08-29), rendered on the
        // widget's caption pill. The flag below routes the live path
        // through AppleSpeechLiveEngine; the sink carries the running
        // text out and is armed for EVERY dictation session, because
        // either streaming engine can be the one driving (Nemotron
        // outranks Apple in `Transcriber.startLivePath`). Both are
        // no-ops unless a streaming path actually starts — a Whisper
        // fallback keeps today's behaviour: live timer, no caption,
        // unchanged paste.
        micTranscriber.dictationAppleLive =
            currentMode == .dictation && settings.dictationEngine == .appleSpeech
        // NB: written as if/else, not `?:` — the ternary over an optional
        // @MainActor closure fails to type-check on the Xcode 27 beta
        // compiler ("failed to produce diagnostic for expression").
        if currentMode == .dictation {
            micTranscriber.onDictationLiveText = { text in
                WidgetBubbleCenter.shared.updateLiveCaption(text)
            }
        } else {
            micTranscriber.onDictationLiveText = nil
        }
        micTranscriber.start(consuming: micAudio, startedAt: nowStarted, tier: tier)
        // A dictation held over a live recording is a second capture on
        // the same microphone (its own AUHAL unit — CoreAudio shares an
        // input device between units, and Daisy takes no hog mode and
        // writes no device property), not one of the recording's tracks.
        let overLiveRecording = dictatesOverLiveRecording
        // The common clock every archive aligns to, before any track
        // starts — the host's, while it records.
        if !overLiveRecording { ArchiveOrigin.mark() }
        do {
            try recorder.start(
                archiveURL: micArchive,
                preferredDeviceUID: settings.selectedMicDeviceUID,
                noiseSuppressionEnabled: settings.microphoneNoiseSuppressionEnabled,
                alignsToArchiveOrigin: !overLiveRecording
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
                // Warm the diarizer HERE rather than at app start: this
                // is the first moment we know speaker separation will
                // actually be wanted. Loading it in the app's `init`
                // meant hundreds of megabytes resident on machines that
                // never record; loading it lazily on the first live tick
                // would put a synchronous `initialize(models:)` ten
                // seconds into the meeting instead (review find,
                // 2026-09-02). This lands in the gap before anyone has
                // spoken.
                if settings.diarizeRemoteSpeakers {
                    Task { await DiarizationEngine.shared.ensureLoaded() }
                }
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
        // Ollama as the provider and not answering right now (after a
        // restart it isn't running, and the launch-time check may have
        // given up before it came up): ask again now, which starts it.
        // `stop()` reads the cached availability and must not wait 20 s
        // for a launch, so it has to be settled before the meeting ends
        // (review 28.10).
        if currentMode == .meeting, settings.autoSummarize,
           summarizer.providerKind == .ollama, summarizer.availability != .available {
            Task { [summarizer] in await summarizer.refreshAvailability() }
        }
        // The recording's own log excerpt, kept in its folder from here
        // on (B-3): the Info lines a report sent hours later has lost.
        // Not for dictation — seconds long, and its folder is a sidecar.
        if currentMode != .dictation, let dir {
            Task { await SessionDiagnosticsLog.shared.begin(directory: dir, recordingStartedAt: nowStarted) }
        }
        if currentMode == .meeting { ImprovementStats.record(.recordingStarted(fromCalendar: fromCalendar)) }
        installThermalDowngrade(startedTier: tier)
        if settings.recordingSoundsEnabled, !overLiveRecording {
            if case .daisyKeyHold(let token) = dictationPurpose {
                // A Daisy-key capture purrs once it's a hold: a tap's
                // half-second, or ⌃⌥ that turned out to be ⌃⌥⌘R, makes no
                // sound (22.10).
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(DaisyKeyController.tapThreshold))
                    guard let self, self.dictationPurpose == .daisyKeyHold(token), self.status == .recording else { return }
                    SoundEffects.playStart(for: .dictation)
                }
            } else {
                SoundEffects.playStart(for: currentMode)
            }
        }

        // Optional screenshots.
        if settings.screenshotsEnabled, !overLiveRecording, let dir {
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
        ImprovementStats.record(.recordingMicOnly)
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
        // one bubble tag — so posting here would REPLACE a warning
        // raised moments earlier in the same `start()`. On a docked Mac
        // with the lid shut and Screen Recording off, that would swap
        // "Daisy can't hear you" for "recording your voice only", which
        // is worse than useless: it isn't recording a voice at all. The
        // same goes for the low-disk warning — losing the audio file
        // entirely outranks losing one side of it. The in-app toast
        // above still fires either way. See `lowDiskWarned`.
        guard !clamshellWarned, !lowDiskWarned else { return }
        CaptureProblemNotification.post(
            title: String(localized: "Recording your voice only"),
            body: notificationBody
        )
    }

    /// The recorder stopped capturing and put itself on pause. Bring the
    /// session's own state in line — otherwise the widget, the capsule
    /// and the elapsed clock all keep saying "recording" over a
    /// microphone that isn't running — and tell the person, through the
    /// channel that works with the main window closed.
    private func handleMicFellToPaused(_ reason: MicPauseReason) {
        guard status == .recording else { return }
        log.warning("Mic recorder fell to paused (\(String(describing: reason), privacy: .public)) — pausing the session to match")
        // Go through the real `pause()`, not just `status = .paused`.
        // Pause is seven things — silence monitor, both transcribers,
        // screenshots, system audio, the disk monitor — and setting the
        // status alone left all of them running against a microphone
        // that had stopped, then handed `resume()` an unbalanced state
        // (review find, 2026-09-02). `recorder.pause()` inside it is a
        // no-op: the recorder is already paused, which is why we're here.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await pause()
            // Dictation has no Resume button and the person is looking
            // at another app's window; the hold ending will stop the
            // session on its own, so the meeting copy would just be
            // wrong there.
            guard currentMode != .dictation else { return }
            // The silence watchdog has its own, more specific message
            // (digital silence names the permission or the closed lid),
            // and two prompts about one event is worse than one.
            guard reason != .silenceAlreadyAnnounced else { return }
            let message = String(
                localized: "The microphone stopped delivering audio — recording is paused. Reconnect it and press Resume, or stop and save what's recorded."
            )
            WidgetBubbleCenter.shared.present(
                WidgetBubbleContent(text: message, tag: "mic-fell-to-paused"),
                notificationTitle: String(localized: "Recording is paused")
            )
            ToastCenter.shared.show(message, style: .warning, duration: .seconds(12))
        }
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
            return String(localized: "Audio recording is off in \(SettingsRow.audioStorage.path), and the live transcript came out empty, so no summary was made. There's no audio file to fall back on in this mode.")
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
        // How long each track's pause held the main actor (24.10: a
        // dialog drew late right after a pause, and the log could not
        // say whether the pause itself was the wait).
        let pauseStarted = Date()
        recorder.pause()
        let micPaused = Date()
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
        let systemPaused = Date()
        // Both tracks have stopped: the shared pause moment they pad to.
        // Not a dictation over a live recording — the marks are that
        // recording's, and the dictation's own mic falling to paused (a
        // route change) would freeze its timeline (review 31.10).
        if !dictatesOverLiveRecording { ArchiveOrigin.markPause() }
        micTranscriber.pause()
        systemTranscriber.pause()
        screenshots.stop()
        silenceMonitor.pause()
        status = .paused
        // Pause cue removed — it fired mid-capture (leak window) and the
        // widget colour already signals paused (gray). See SoundEffects.
        log.info("Session paused after \(self.elapsed, privacy: .public)s (mic \(Int(micPaused.timeIntervalSince(pauseStarted) * 1000), privacy: .public) ms, system audio \(Int(systemPaused.timeIntervalSince(micPaused) * 1000), privacy: .public) ms)")
    }

    /// Resume a paused session. Audio capture restarts; the existing
    /// audio archive is appended to so the .caf file ends up as one
    /// continuous recording (gaps are simply absent, not silent).
    func resume() async {
        guard status == .paused else { return }
        // Neither track has restarted yet: the shared resume moment.
        if !dictatesOverLiveRecording { ArchiveOrigin.markResume() }
        do {
            try recorder.resume()
        } catch {
            // Stay PAUSED, don't fail. `.failed` is a dead end for a
            // session that already has an hour of audio on disk and a
            // live transcript in memory: `stop()` only accepts
            // `.recording`/`.paused`, so nothing could save it, and the
            // widget's "Try again" is `start()`, which resets and walks
            // away from the directory. Paused keeps the file open, the
            // elapsed clock intact, and both Resume and Stop & save
            // available. The likely trigger is mundane — the Mac woke up
            // before CoreAudio republished the device, or the USB
            // interface was unplugged during sleep (audit 2026-09-01).
            log.error("Resume mic failed: \(error.localizedDescription, privacy: .public) — staying paused so the session can still be saved")
            let message = String(
                localized: "Couldn't restart the microphone — the recording is paused, not lost. Try Resume, or stop and save what's recorded."
            )
            // Both channels: a paused recording is usually noticed from
            // outside the app, and the widget is where the person will
            // look for the Resume button.
            WidgetBubbleCenter.shared.present(
                WidgetBubbleContent(text: message, tag: "resume-failed"),
                notificationTitle: String(localized: "Recording is paused")
            )
            ToastCenter.shared.show(message, style: .warning, duration: .seconds(12))
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
        liveDirName = nil
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

    /// A long note that opens with «(заметка) в проект Лендинг …» goes to
    /// that project (Egor 22.10), as a held note does. Only a note nobody
    /// filed by hand — still in the default notes project or Inbox. Run at
    /// Stop on the live lines, and again on the final pass's — live
    /// transcription may be off, behind, or mishear the name, so at Stop
    /// only a match acts; «no such project» waits for the final words.
    /// The words stay in the note. Said the way the held note says it: a
    /// toast and the widget's pill with Open, once.
    func fileNoteBySpokenProject(final: Bool) {
        guard currentMode == .voiceNote, meetingPreparationSnapshot == nil, !spokenProjectAnswered,
              folder == .inbox || folder.slug == FolderStore.shared.defaultNoteFolderSlug else { return }
        let opening = segments.filter { $0.source == .microphone }
            .sorted { $0.startSec < $1.startSec }
            .prefix(3).map(\.text).joined(separator: " ")
        guard let route = DaisyKeyFolderRoute.opening(opening, folders: DaisyKeyController.folders()) else { return }
        let target = route.folderSlug.flatMap { FolderStore.shared.existingFolder(slug: $0) }
        guard target != nil || final else { return }
        spokenProjectAnswered = true
        let id = sessionDirectory?.lastPathComponent
        let open: (label: String, run: @MainActor () -> Void)? = id.map { id in
            (String(localized: "Open"), { @MainActor in AppNavigation.shared.openInLibrary(id) })
        }
        if let target {
            log.info("Voice note filed into the project its first words named")
            folder = target
            DaisyKeyController.shared.tell(String(localized: "Note saved to \(target.name)"), style: .success, action: open)
        } else {
            DaisyKeyController.shared.tell(route.ambiguous
                ? String(localized: "Several projects match — saved to \(folder.name)")
                : String(localized: "No such project — saved to \(folder.name)"),
                action: open.map { (String(localized: "Move"), $0.run) })
        }
    }
    /// The note's spoken project has been acted on or answered — the final
    /// pass doesn't say it again.
    var spokenProjectAnswered = false

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
        // meetings/voice notes (no caption was ever shown) — except one
        // stopped while a side dictation's caption is up, which stays.
        if sideDictation?.isDictating != true {
            WidgetBubbleCenter.shared.hideLiveCaption()
        }
        // A dictation held over a recording: its span ends here, whichever
        // way this stop came (the key's release closes it first; the
        // widget's Stop on the dictation doesn't go through the key). And
        // the recording stopping under a dictation still held ends that
        // dictation's span at the recording's last moment.
        if isDictationSidecar {
            dictationHost?.closeDictationHold()
        } else {
            // Kept only while that dictation still runs: an open span
            // with no dictation behind it (its start was refused and the
            // key-up was lost) is no reason to cut the meeting.
            closeDictationHold(keep: sideDictation?.isDictating == true)
        }
        // …and cut the sink in the same breath. The transcriber keeps
        // streaming until `stopCapture()` far below (after the audio
        // teardown awaits), and a streaming engine landing one more
        // result in that window would re-open the pill we just closed —
        // stale text hanging over the inline final pass. Apple's cadence
        // made this a near-miss; Nemotron's 560 ms chunks would hit it
        // almost every time (review find, 2026-08-31).
        micTranscriber.onDictationLiveText = nil
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
        closeSideNote(nil)
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
            ToastCenter.shared.showAction(
                String(localized: "Nothing was transcribed this session — check \(SettingsRow.microphone.path). The recording was kept, not discarded"),
                actionLabel: String(localized: "Open audio settings"),
                style: .warning,
                duration: .seconds(8)
            ) {
                AppNavigation.shared.openInSettings(.meetings, row: .microphone)
            }
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
        log.notice("post-stop stop_capture: \(ms(t_stopCapture), privacy: .public)ms")
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
        // Everything since the last five-minute capture, the summary
        // line above included, goes to the folder's diagnostics.log; the
        // finalize task adds its own lines when it ends. Off the main
        // actor, and nothing below waits for it. `diagnosticsSince` is
        // the finalize capture's fallback window: normally the cursor
        // this capture leaves is later and wins, but if this one failed
        // the finalize's starts here rather than at its own end.
        let diagnosticsSince = Date()
        if currentMode != .dictation, let dir = sessionDirectory {
            Task { await SessionDiagnosticsLog.shared.end(directory: dir) }
        }
        // Before the capture checks below, so a warning they raise isn't
        // covered by this note's one.
        fileNoteBySpokenProject(final: false)

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
            // What was said over each Daisy-key moment, from the live
            // lines; the final pass refines it.
            resolveMomentComments()
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
        // `ownSpeechChunks(inTranscript:)`, which reads the
        // already-deduped transcript on disk.
        //
        // Meetings only, matching what the switch promises and what
        // `backfillFromMeetings` collects; a voice note is left out in
        // both paths rather than counted in one of them.
        //
        // Grouped into blocks rather than fed as one string: own speech
        // on a call can honestly change language halfway through (starts
        // in Russian, continues in English), and one blob would be filed
        // under one language. On auto-detect each block is classified on
        // its own and the session-wide `detectedLanguage` is only the
        // fallback where the detector stays silent. With a pinned
        // session locale that locale wins for every block — deliberately:
        // the ASR was decoding that one language, so that is what the
        // text is.
        if currentMode == .meeting, VoiceProfileStore.shared.includesMeetings {
            let ownLines = dedupedSegments
                .filter { $0.source == .microphone }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            VoiceProfileStore.shared.appendMeetingSpeech(
                VoiceSpeechBlocks.group(ownLines),
                language: VoiceCorpusClassifier.normalized(localeIdentifier),
                transcriberHint: detectedLanguage
            )
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
        //
        // `|| capturedAnyAudio`: with live transcription off a meeting
        // has no segments at Stop by design — its words come from the
        // final pass over the archives. Asking for segments here meant
        // such a meeting never got its summary, and its card offered
        // Summarize over a transcript of screenshot links (31.10). If the
        // final pass hears nothing, `Summarizer.summarize` says so and
        // writes nothing.
        let willSummarize = settings.autoSummarize
            && summarizer.availability == .available
            && (!segments.isEmpty || capturedAnyAudio)
            && currentMode == .meeting
            && !captureLikelyFailed

        guard let dir = sessionDirectory else {
            // No session dir — shouldn't happen post-capture, but
            // bail cleanly. transcript.md never landed, no summary
            // can run, no auto-send needed.
            releaseSessionsFolderTicket()
            liveDirName = nil
            status = .finished
            if settings.recordingSoundsEnabled { SoundEffects.playFinished() }
            return
        }
        let sessionID = dir.lastPathComponent
        // Summaries are on but the provider isn't usable (Apple
        // Intelligence switched off, a missing key): finalize won't even
        // try, and that used to be silent. Keep and say why (07.10.2026).
        if settings.autoSummarize, currentMode == .meeting, !segments.isEmpty || capturedAnyAudio, !captureLikelyFailed,
           case .unavailable(let reason) = summarizer.availability {
            SummaryFailureNote.announce(
                SummaryFailureNote.write(message: reason, provider: summarizer.providerKind.shortName, in: dir)
            )
            // Once per install, at the widget: who should write it.
            ContextTips.shared.summaryProviderMissing()
        }

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
        switch currentMode {
        case .meeting: ImprovementStats.record(.recordingSaved(seconds: max(0, durSec)))
        case .voiceNote: ImprovementStats.record(.voiceNoteSaved)
        case .dictation: break
        }
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
        // «Process later, on a charger» (Settings → General): on battery
        // or in Low Power Mode a meeting keeps its live transcript now and
        // gets its final pass, speakers and summary from the queue once
        // the Mac is on power — or at once from «Process now». The
        // `.recording` marker stays, which keeps the audio safe from the
        // retention sweep until the queued job replaces the transcript.
        if currentMode == .meeting, settings.deferProcessingOnBattery, PowerState.shared.isConstrained,
           queueDeferredUntilPower(sessionID: sessionID, directory: dir, title: titleSnapshot) {
            // The transcribers keep their segments: the finished panel,
            // Send to Notion/Claude and «Summarize now» read them. Their
            // buffers go at the next start()'s reset, as after a rotation.
            ticketSnapshot?.release()
            if SessionStore.shared.activeRecordingDirName == sessionID {
                SessionStore.shared.activeRecordingDirName = nil
            }
            if willSummarize {
                summaryGenerationState = .idle
                await SessionStore.shared.finishGenerating(sessionID)
            }
            return
        }
        summaryTask = Task { [weak self] in
            // Release the live-folder marker when the pipeline is done —
            // not before (the finalize task still rewrites transcript.md
            // and can purge audio) and not never, which is what shipped:
            // it used to be cleared ONLY in `discard()`, so after the
            // first recording of the day the flag stayed armed for the
            // rest of the run. It gates the two mechanisms that repair a
            // crash — interrupted-recording recovery
            // (`SessionStore.swift:268`) and quit-finalize
            // (`QuitFinalizeRecovery.swift:84`, which answers "finish the
            // current recording first" while nothing is recording) —
            // plus renaming the last session and bulk-delete
            // (audit 2026-09-01).
            //
            // Guarded by identity: a back-to-back meeting may already
            // have announced ITS folder while this task was finishing,
            // and clearing that would hand the next session's live
            // directory to the sweepers. The rotation-stop path above
            // returns without spawning this task at all and needs no
            // clear of its own for the same reason — the incoming
            // `start()` reassigns the flag moments later.
            defer {
                ticketSnapshot?.release()
                if SessionStore.shared.activeRecordingDirName == sessionID {
                    SessionStore.shared.activeRecordingDirName = nil
                }
            }
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
            // The final pass, the summary and the auto-send — or the
            // bail that queued them — are the lines a "no summary" report
            // is about. Captured whichever way finalize ended.
            await SessionDiagnosticsLog.shared.captureWindow(directory: dir, from: diagnosticsSince, reason: "finalize")
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
        ImprovementStats.record(.recordingFailed)
        await unwindStart()
        status = .failed(message)
    }

    /// What `start()` waits for when it is a dictation (`DictationModelGate`).
    private func dictationModelPlan() async -> DictationModelGate.Plan {
        let engine = settings.dictationEngine
        let parakeet = ParakeetEngine.shared
        let isDownloading: Bool = { if case .downloading = parakeet.state { return true }; return false }()
        let failedRecently: Bool = {
            guard case .failed = parakeet.state, let at = parakeet.lastFailureAt else { return false }
            return Date().timeIntervalSince(at) < ParakeetEngine.failureBackoff
        }()
        let needsDiskCheck = engine == .parakeet && !parakeet.isReady && !isDownloading && !failedRecently
            && WhisperEngine.runsOnThisMac
        var appleSpeechReady = false
        if engine == .appleSpeech, #available(macOS 26, *) {
            let localeID = settings.dictationLocale.isEmpty
                ? settings.defaultTranscriptionLocale
                : settings.dictationLocale
            if localeID != "auto", !localeID.isEmpty {
                appleSpeechReady = await AppleSpeechLiveEngine.availability(locale: Locale(identifier: localeID)) == .ready
            }
        }
        return DictationModelGate.plan(
            engine: engine,
            parakeet: .init(isReady: parakeet.isReady, isDownloading: isDownloading,
                            hasCompleteModel: needsDiskCheck && ParakeetEngine.hasCompleteModel(),
                            failedRecently: failedRecently),
            appleSpeechReady: appleSpeechReady,
            whisperRunsHere: WhisperEngine.runsOnThisMac
        )
    }

    /// One wait inside `start()` — a model load, a retry — that a
    /// dictation can walk away from. Returns false when the dictation was
    /// cancelled (`requestDictationStartCancel`); the step itself runs on
    /// in its own task, so a model that's loading keeps loading for the
    /// next press. A meeting's or a voice note's wait is not cancellable
    /// here and returns true when the step is done.
    ///
    /// While a dictation waits, the caption over the widget says what
    /// for and how far along (`DictationModelGate.waitCaption`) — after a
    /// short delay, so a warm engine answering at once flashes nothing.
    private func awaitStartStep(
        _ step: @escaping @MainActor () async -> Void,
        whisper: Bool = true
    ) async -> Bool {
        let cancellable = currentMode == .dictation
        if cancellable && dictationReleasedWhilePreparing { return false }
        var captionTask: Task<Void, Never>?
        if cancellable {
            captionTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                while !Task.isCancelled {
                    let engine = WhisperEngine.shared
                    WidgetBubbleCenter.shared.updateLiveCaption(
                        DictationModelGate.waitCaption(whisper: whisper ? engine.state : nil,
                                                       loadProgress: engine.loadProgress,
                                                       parakeet: whisper ? nil : ParakeetEngine.shared.state)
                    )
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
        await StartStepGate.wait(for: step) { cancel in
            if cancellable { cancelStartWait = cancel }
        }
        cancelStartWait = nil
        if let captionTask {
            captionTask.cancel()
            WidgetBubbleCenter.shared.hideLiveCaption()
        }
        return !(cancellable && dictationReleasedWhilePreparing)
    }

    /// A dictation start dropped while it waited for a model: everything a
    /// failed start unwinds, but back to idle and without a failure — the
    /// person let go of the key. A Daisy-key tap still fixes the layout
    /// (its capture is thrown away anyway); a hold or a dictation says why
    /// nothing was written.
    /// `waitedForWhisper`: which engine the start was waiting for (nil —
    /// none, the key came up before any wait). The pill promises «it'll
    /// work once ready» only while that engine really is on its way; a
    /// model that failed gets the way to repair it; a ready one — an
    /// accidental tap — says nothing.
    private func abandonDictationStart(waitedForWhisper: Bool?) async {
        log.info("Dictation start cancelled before the microphone opened — any model load goes on in the background")
        let purpose = dictationPurpose
        dictationPurpose = .paste
        dictationReleasedWhilePreparing = false
        await unwindStart()
        status = .idle
        switch purpose {
        case .daisyKeyTap(let token):
            DaisyKeyController.shared.tapCaptureFinished(token: token, on: self)
            return
        case .daisyKeyHold(let token):
            DaisyKeyController.shared.holdAbandoned(token: token)
        case .paste:
            break
        }
        enum Wait { case onItsWay, failed, ready }
        let wait: Wait = {
            switch waitedForWhisper {
            case .none:
                return .ready
            case .some(true):
                switch WhisperEngine.shared.state {
                case .ready: return .ready
                case .failed: return .failed
                case .notLoaded, .downloading, .loading: return .onItsWay
                }
            case .some(false):
                switch ParakeetEngine.shared.state {
                case .ready: return .ready
                // Whisper takes the next one if Parakeet can't — so it's
                // Whisper's state that says what the next press meets.
                case .failed:
                    switch WhisperEngine.shared.state {
                    case .ready: return .ready
                    case .failed: return .failed
                    case .notLoaded, .downloading, .loading: return .onItsWay
                    }
                case .notLoaded, .downloading, .loading: return .onItsWay
                }
            }
        }()
        switch wait {
        case .onItsWay:
            _ = WidgetBubbleCenter.shared.show(WidgetBubbleContent(
                text: String(localized: "I’ve cancelled it — the speech model is still getting ready. Dictation will work once it’s done."),
                autoDismiss: 6
            ))
        case .failed:
            presentSpeechModelNotReadyPill()
        case .ready:
            break
        }
    }

    /// Everything a start that didn't make it to recording leaves behind.
    private func unwindStart() async {
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
        // A start that failed after the directory was announced would
        // otherwise leave the folder marked live forever — see the note
        // in `reset()`. Identity-guarded for the same reason.
        if liveDirName == sessionDirectory?.lastPathComponent {
            liveDirName = nil
        }
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
        daisyCommandSpans = []
        dictationHolds = []
        liveDictationHolds = []
        openDictationHoldStart = nil
        linesAreOnArchiveTimeline = false
        micArchiveURL = nil
        systemArchiveURL = nil
        startedAt = nil
    }

    // MARK: - Thermal / low-power auto-downgrade

    /// The live tier a recording starts with. Meetings and voice notes
    /// take the person's setting.
    ///
    /// A dictation used to force `.full`: Whisper re-decoded up to 30 s of
    /// the hold every 2 s (latency audit 31.10, item 4). Nothing ever read
    /// those windows: no caption shows Whisper text (`onDictationLiveText`
    /// fires from the streaming engines only), the paste comes from the
    /// fast engine over the captured buffer or from a Whisper final pass
    /// that replaces every live line (`fullReplace`, and its keep-the-live-
    /// lines guard skips `.dictationFinal`), and `stop()` cancels the
    /// window in flight for that reason. So a dictation runs no live
    /// Whisper — unless a streaming engine drives its live caption: Apple's
    /// (engine `.appleSpeech`) or the Nemotron preview. Those start from
    /// `Transcriber.startLivePath`, which only a non-off tier reaches.
    static func liveTier(mode: RecordingMode, setting: LiveTranscriptionTier,
                         dictationEngine: DictationEngine, nemotronLive: Bool) -> LiveTranscriptionTier {
        guard mode == .dictation else { return setting }
        return nemotronLive || dictationEngine == .appleSpeech ? .full : .off
    }

    /// Watch thermal state + Low Power Mode while a Full-tier session runs
    /// and silently drop live transcription Full→Lite under pressure,
    /// auto-restoring when it clears. The final pass on Stop stays full
    /// quality and the user's saved tier is never modified (runtime override).
    private func installThermalDowngrade(startedTier: LiveTranscriptionTier) {
        removeThermalDowngrade()
        startedLiveTier = startedTier
        // Only Full sessions have headroom to shed; Lite/Off/Apple are
        // already light. (A dictation is Full only with a streaming
        // caption engine, and short — harmless.)
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
        // Read before the cancel below nils it: whether a finalize was
        // in flight decides who owns the live-folder marker (see the
        // clause further down).
        let finalizeWasRunning = summaryTask != nil
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
        // Unless it's the side dictation's, still running over this one.
        if sideDictation?.isDictating != true {
            WidgetBubbleCenter.shared.hideLiveCaption()
        }
        // Defensive: the rotation flag is normally consumed at the top
        // of stop(), but a reset() between set and consume (husk
        // cleanup path) must not leave it armed for a later stop.
        skipFinalPassOnNextStop = false
        persistedKindOverride = nil
        // Belt for the live-folder marker, same reasoning as the caption
        // above: `stop()` clears it when its finalize task ends, but
        // `stop()` has early returns (husk cleanup, dictation, missing
        // directory) that never spawn one, and dictation finishes
        // through here. A marker left armed disables crash recovery for
        // the rest of the run.
        //
        // Two guards, both earned. Identity: `start()` calls reset()
        // before announcing its own directory, and a back-to-back
        // meeting must not have its live folder handed to the sweepers.
        // Finalize-in-flight: cancellation isn't instant (the streaming
        // pass only checks between ~15-minute blocks) while the
        // `.recording` marker on disk lives until Stage 3 — clearing the
        // flag in that window would let `SessionStore.scanRoots` classify
        // the folder as quit-saved and offer a SECOND finalize pass over
        // it. In that case the finalize task's own `defer` clears the
        // flag when it actually finishes.
        if !finalizeWasRunning,
           liveDirName == sessionDirectory?.lastPathComponent {
            liveDirName = nil
        }
        recorder.reset()
        micTranscriber.reset()
        systemTranscriber.reset()
        screenshots.stop()
        silenceMonitor.stop()
        cancelAutoStop()
        removeThermalDowngrade()
        releaseSessionsFolderTicket()
        // The summarizer is app-wide and a side dictation never
        // summarizes: its teardown must not wipe the state (a result, an
        // error) of the recording it ran beside.
        if !isDictationSidecar { summarizer.clear() }
        sessionDirectory = nil
        momentMarkers = []
        daisyCommandSpans = []
        dictationHolds = []
        liveDictationHolds = []
        openDictationHoldStart = nil
        linesAreOnArchiveTimeline = false
        micArchiveURL = nil
        systemArchiveURL = nil
        // `micOnlyCause` is deliberately NOT cleared here — the
        // post-stop re-render of transcript.md still has to write
        // `daisy_mic_only:`, and reset() runs before that. It is zeroed
        // at the top of the next `start()` instead.
        startedAt = nil
        if isCapturingSideNote { WidgetBubbleCenter.shared.dismiss(tag: Self.sideNoteTag) }
        sideNoteWatch?.cancel()
        sideNoteWatch = nil
        sideNotePlaque = nil
        sideNoteWindows = []
        cutSideNoteWindows = []
        writtenSideNotes = []
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
        spokenProjectAnswered = false
        tag = ""
        currentMode = .meeting
        // Drop any unanswered Prompt-mode trigger + retract its banner —
        // starting/resetting supersedes a pending ask.
        pendingAutoStartTrigger = nil
        rotationAskedFor = nil
        // The asks are the recording's, global: a side dictation's reset
        // must not take down «next meeting — switch?» from the meeting it
        // dictates over (review 31.10).
        if !isDictationSidecar {
            WidgetBubbleCenter.shared.dismiss(tag: Self.rotationAskBubbleTag)
            AutoStartPromptNotification.cancel()
            WidgetBubbleCenter.shared.dismiss(tag: Self.autoStartAskBubbleTag)
        }
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
        // Named by the second, so two sessions started within one — a
        // dictation over a recording that began a moment ago, a rotation —
        // must not share a folder: the dictation's teardown deletes its
        // folder, which would take the recording with it (review 31.10).
        // No await between the check and the create, so on the main actor
        // nothing can claim the name in between.
        let sessionsRoot = ticket.url.appendingPathComponent("Daisy/Sessions", isDirectory: true)
        var dir = sessionsRoot.appendingPathComponent(safeStamp, isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: dir.path) {
            dir = sessionsRoot.appendingPathComponent("\(safeStamp)-\(suffix)", isDirectory: true)
            suffix += 1
        }
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

/// What `RecordingSession.awaitStartStep` suspends on: it resumes when the
/// step finishes or when the cancel handed out is called, whichever comes
/// first — the other finds it already open. A cancelled step runs on in
/// its own task (a model keeps loading for the next press).
final class StartStepGate {
    private var continuation: CheckedContinuation<Void, Never>?

    private func open() {
        continuation?.resume()
        continuation = nil
    }

    static func wait(
        for step: @escaping @MainActor () async -> Void,
        cancelHandle: (@escaping @MainActor () -> Void) -> Void
    ) async {
        let gate = StartStepGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.continuation = continuation
            cancelHandle { gate.open() }
            Task { @MainActor in
                await step()
                gate.open()
            }
        }
    }
}
