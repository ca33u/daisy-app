//
//  DaisyWidget.swift
//  Daisy
//
//  Compact floating puck — 8 teardrop petals around a status-coloured
//  centre. Wispr-Flow-inspired aesthetic: solid dark surface, dense
//  glyph-free centre (colour communicates state), tight padding.
//
//  • Recording: petals follow the existing mirrored FFT bands.
//  • Preparing / Stopping / Summarizing: the B+ petals rotate together
//    at one revolution per 4.8 seconds, with a stationary status centre.
//  • Other states and Reduce Motion: a still B+ silhouette.
//

import SwiftUI
import AppKit

struct DaisyWidget: View {
    let session: RecordingSession
    /// Called by the right-click context menu when the user picks
    /// "Hide for N seconds". The panel controller owns the actual hide
    /// + restore timer. Defaults to a no-op for SwiftUI Previews.
    var onHideRequest: (TimeInterval) -> Void = { _ in }

    @Environment(\.openWindow) private var openWindow
    /// Honour System Settings → Accessibility → Display → Reduce Motion.
    /// Under reduce-motion we drop the petal rotation and audio motion and the celebration spring (instant settle).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Scales the whole daisy briefly when the session lands in
    /// `.finished` — the "celebration" pop that finishes the loader
    /// arc (flower rotates → bounce → settle into white).
    @State private var celebrationScale: CGFloat = 1.0
    @State private var loaderStartedAt = Date()

    /// Daisy shrinks in "passive" states (idle, finished) so it sits
    /// less prominently after recording is done. Full size during
    /// active work (recording / preparing / summarizing / failed).
    /// Driven EXPLICITLY (not a computed property) so the finished
    /// transition can SEQUENCE the celebration pop *before* the shrink —
    /// otherwise the spring pop and the shrink animate the same
    /// `scaleEffect` from two clocks at once and the daisy "celebrates
    /// while deflating". Initialised from the current status in onAppear.
    @State private var passiveScale: CGFloat = 0.80

    /// Passive states sit at 0.80 (was 0.66 — that deflated the finished
    /// daisy to ~a third of its size; 0.80 still recedes without looking
    /// like it shrank away).
    private static func targetPassiveScale(_ status: RecordingSession.Status) -> CGFloat {
        switch status {
        case .idle, .finished: return 0.80
        default: return 1.0
        }
    }

    /// True for the "loader" states whose petals rotate — those
    /// run at 60fps (see `body`); everything else at 30fps.
    /// Only the moments the widget really can't take a tap. Summaries
    /// are background work and show nothing here (Egor, 24.09: «обработка
    /// саммари в виджете не нужна — человек должен сразу запустить другую
    /// запись»).
    private static func isLoadingStatus(_ status: RecordingSession.Status) -> Bool {
        switch status {
        case .preparing, .stopping: return true
        default: return false
        }
    }

    // B+ uses a 100-unit canvas, matching the exported SVG exactly.
    private let petalCount = 8
    private static let petalReactiveGain: Float = 1.0
    private let canvasSize: CGFloat = 42.075
    private var maxPetalLength: CGFloat { canvasSize * 0.278 }
    /// The shortest a petal gets while recording — at silence it sits a
    /// little above this (the 0.12 floor). 0.72 until 24.09: on a real
    /// voice the bands run 0.35–0.9, which moved a petal between 82% and
    /// 97% of its length — Egor: «реакция на голос слабая». 0.5 nearly
    /// doubles the swing on the same signal. Only recording uses it;
    /// every other state draws the full silhouette (amplitude 1).
    private var basePetalLength: CGFloat { maxPetalLength * 0.5 }
    private var petalWidth: CGFloat { canvasSize * 0.20 }
    private var centerSize: CGFloat { canvasSize * 0.21 }
    private var petalGap: CGFloat { canvasSize * 0.037 }
    /// The B+ canvas is the disc, so at 1:1 the petal tips reach 84% of
    /// its diameter and the flower crowds the edge (Egor, 2026-09-23:
    /// «уменьшить всю композицию чуть-чуть»). One uniform scale for
    /// petals and centre together — the shape and its proportions are
    /// the SVG's and stay untouched.
    private let flowerScale: CGFloat = 0.85

    var body: some View {
        // Preserve one view tree across states. Only petals rotate while
        // loading; the centre keeps the recorder's existing status colour.
        let loading = Self.isLoadingStatus(session.status)
        let interval = loading ? 1.0 / 60.0 : 1.0 / 30.0
        let animating = !reduceMotion && (session.status == .recording || loading)
        return TimelineView(.animation(minimumInterval: interval, paused: !animating)) { context in
            let status = session.status
            let mode = session.currentMode
            let summaryGen = session.summaryGenerationState
            let bands = session.spectrumBands
            let rotation = loading && !reduceMotion
                ? context.date.timeIntervalSince(loaderStartedAt).truncatingRemainder(dividingBy: 4.8) / 4.8 * 360
                : 0
            let center = centerColor(for: status, mode: mode, summaryGen: summaryGen)

            ZStack {
                Circle()
                    // Widget backing disc — #1C1A17 (warm near-black,
                    // matches Daisy's dark surface; was a cooler #121216).
                    .fill(Color(red: 28.0 / 255, green: 26.0 / 255, blue: 23.0 / 255))

                ZStack {
                    ForEach(0..<petalCount, id: \.self) { i in
                        let petalAngle = Double(i) * 360.0 / Double(petalCount)
                        Petal(
                            amplitude: amplitudeFor(petalIndex: i, bands: bands, status: status, mode: mode, date: context.date),
                            angleDegrees: petalAngle,
                            color: petalColor(status: status),
                            width: petalWidth,
                            baseLength: basePetalLength,
                            maxLength: maxPetalLength,
                            centerSize: centerSize,
                            gap: petalGap,
                            reduceMotion: reduceMotion
                        )
                    }
                }
                .rotationEffect(.degrees(rotation))
                .scaleEffect(flowerScale)

                Circle()
                    .fill(center)
                    .frame(width: centerSize, height: centerSize)
                    .shadow(color: center.opacity(0.55), radius: 2.5, x: 0, y: 0)
                    .scaleEffect(flowerScale)
            }
        }
        .frame(width: canvasSize, height: canvasSize)
        // MAC-01: a badge, because a hue is not a message. Small, but
        // a shape that is not present in any healthy state — nothing
        // else on this widget is a triangle.
        .overlay(alignment: .topTrailing) {
            if systemAudioProblem != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: canvasSize * 0.26, weight: .bold))
                    .foregroundStyle(Color.daisyWarning)
                    .background(Circle().fill(Color.black).padding(-1))
                    .offset(x: canvasSize * 0.04, y: -canvasSize * 0.02)
                    .accessibilityHidden(true)
            }
        }
        // Combined scale: celebration pop × passive-state shrink. Both are
        // @State driven from `onChange` (handleStatusChange) so the finished
        // transition can sequence pop → settle instead of animating one
        // `scaleEffect` from two competing clocks.
        .scaleEffect(celebrationScale * passiveScale)
        // Shadow needs room — the panel is sized larger than canvasSize
        // (FloatingPanelController wraps the widget in a 64×64 ZStack;
        // was 80×80 pre-build-45 when canvasSize was 56) so this blur
        // isn't clipped against the panel edge.
        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
        .contentShape(Circle())
        .onTapGesture {
            togglePrimary()
        }
        .contextMenu { contextMenuItems }
        .onChange(of: session.status) { oldStatus, newStatus in
            if Self.isLoadingStatus(newStatus) && !Self.isLoadingStatus(oldStatus) {
                loaderStartedAt = Date()
            }
            handleStatusChange(newStatus)
        }
        .onAppear {
            loaderStartedAt = Date()
            passiveScale = Self.targetPassiveScale(session.status)
            // Lend the SwiftUI-only openWindow action to AppKit-side
            // bubble actions (morning brief's "Open") — it's the only
            // way to RECREATE the main window scene once closed. The
            // widget view lives as long as the floating panel, so the
            // captured action stays valid.
            // Same sequence the widget's own context-menu items use.
            WidgetBubbleCenter.shared.openMainWindow = {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .help(tooltip)
    }

    /// Handle a status change in one place: the passive-scale (sequenced
    /// behind the celebration on finish), the celebration pop, and the
    /// failure cue. Centralised so the two scale animations never overlap
    /// on the shared `scaleEffect`.
    private func handleStatusChange(_ status: RecordingSession.Status) {
        let target = Self.targetPassiveScale(status)
        if case .finished = status {
            // Celebrate at full size, THEN settle small. The shrink is
            // delayed past the pop so the two don't fight (previously both
            // ran at once and the daisy "celebrated while deflating").
            playCelebration()
            let shrink = Animation.easeInOut(duration: 0.35)
            withAnimation(reduceMotion ? nil : shrink.delay(0.55)) {
                passiveScale = target
            }
        } else {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                passiveScale = target
            }
        }
        // Failure has no visual settle of its own and (until now) no audio —
        // a lost recording deserves a distinct, gentle cue. Fired here so it
        // covers every path into `.failed`.
        if case .failed = status, session.settings.recordingSoundsEnabled {
            SoundEffects.playError()
        }
    }

    /// Celebration pop when the session reaches `.finished`. Reads as:
    /// flower was spinning → daisy "lands" → petals settle. Overshoot
    /// dialled to 1.10 (was 1.18) so it stays calm — Daisy is a quiet
    /// background tool, not a perky consumer app. Skipped under Reduce
    /// Motion (instant settle). The matching "done" sound is fired by the
    /// model the instant `.finished` is set, so it lands with this pop.
    private func playCelebration() {
        guard !reduceMotion else { celebrationScale = 1.0; return }
        withAnimation(.spring(response: 0.30, dampingFraction: 0.58)) {
            celebrationScale = 1.10
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation(.spring(response: 0.42, dampingFraction: 0.70)) {
                celebrationScale = 1.0
            }
        }
    }

    /// Confirmation for the destructive discard. The alert itself moved
    /// to `DiscardRecordingPrompt` when the sidebar grew its own
    /// "Stop & discard" button — one wording, one default button, one
    /// path into deleting a live recording.
    private func confirmAndDiscard() {
        DiscardRecordingPrompt.confirmAndDiscard(session)
    }

    // MARK: - Right-click context menu

    @ViewBuilder
    private var contextMenuItems: some View {
        // Primary actions adapt to the current state. Click-to-toggle
        // on the widget handles the pause/resume flow; the right-click
        // menu is where Stop & save lives because it's destructive and
        // shouldn't be a stray tap.
        switch session.status {
        case .recording:
            Button {
                Task { await session.pause() }
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            Button {
                Task { await session.stop() }
            } label: {
                Label("Stop & save", systemImage: "stop.fill")
            }
            Button(role: .destructive) {
                confirmAndDiscard()
            } label: {
                Label("Discard recording", systemImage: "trash")
            }
        case .paused:
            Button {
                Task { await session.resume() }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            Button {
                Task { await session.stop() }
            } label: {
                Label("Stop & save", systemImage: "stop.fill")
            }
            Button(role: .destructive) {
                confirmAndDiscard()
            } label: {
                Label("Discard recording", systemImage: "trash")
            }
        case .idle, .finished, .failed:
            Button {
                Task { await session.start() }
            } label: {
                // 2026-05-25 — "Start recording" → "Record" to match
                // the sidebar capsule + toolbar play button (see
                // RecordCapsule.swift label comment for the rationale).
                Label("Record", systemImage: "record.circle")
            }
        case .preparing, .stopping, .summarizing:
            EmptyView()
        }

        Divider()

        Button {
            copyLastTranscript()
        } label: {
            Label("Copy last transcript", systemImage: "doc.on.doc")
        }
        .disabled(!hasContent)

        Button {
            AppNavigation.shared.section = .library
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("Open Library…", systemImage: "books.vertical")
        }
        .keyboardShortcut("h", modifiers: [.command, .shift])

        Divider()

        // Flat, not a submenu. A nested `Menu` inside `.contextMenu` on a
        // non-activating panel draws its highlight in the wrong
        // appearance on macOS 27 (opaque white on a dark glass menu —
        // Egor, 2026-09-06), and it's system-drawn, so there's nothing to
        // fix on our side. Three rows in the parent menu cost two lines
        // and remove a hover step nobody wanted on a 60 pt widget.
        Button {
            onHideRequest(15 * 60)
        } label: {
            Label("Hide for 15 minutes", systemImage: "eye.slash")
        }
        Button("Hide for 1 hour") { onHideRequest(60 * 60) }
        Button("Hide for today") {
            // Hide until the next local midnight (reappears tomorrow),
            // not a fixed 24h window — matches the "for today" intuition.
            let nextMidnight = Calendar.current.startOfDay(
                for: Date().addingTimeInterval(24 * 60 * 60)
            )
            onHideRequest(nextMidnight.timeIntervalSinceNow)
        }

        Button {
            AppNavigation.shared.section = .settings
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()

        Button(role: .destructive) {
            NSApp.terminate(nil)
        } label: {
            Label("Quit Daisy", systemImage: "power")
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    private var hasContent: Bool {
        !session.displaySegments.isEmpty
    }

    private func copyLastTranscript() {
        // 2026-05-25 — route through MarkdownExporter instead of
        // building a one-off string here. Pre-fix this rendered
        // segments with the generic `source.displayLabel` ("you" /
        // "system") and skipped the new acoustic-echo dedup pass, so
        // the widget context-menu "Copy last transcript" produced a
        // different result than ContentView's footer Copy button
        // (which already goes through MarkdownExporter). Same path
        // now means: proper speaker labels (userDisplayName / Remote
        // A), echo dedup honoured, single source of truth for any
        // future transcript-shape change.
        MarkdownExporter.copyToClipboard(session: session)
    }

    // MARK: - Petal amplitude / colour (driven inside the single TimelineView)

    /// Compute the petal's amplitude (0…1) for the current status.
    /// During recording → spectrum bands (mirrored for symmetry).
    /// Processing and static states use the full B+ silhouette.
    /// The existing whole-widget passive scale still applies after capture.
    private func amplitudeFor(
        petalIndex: Int,
        bands: [Float],
        status: RecordingSession.Status,
        mode: RecordingSession.RecordingMode,
        date: Date
    ) -> Float {
        if reduceMotion { return 1 }
        switch status {
        case .recording:
            // 8 petals, mirrored across the vertical axis → the lower 4 of
            // the analyzer's 6 voice-tuned bands drive symmetric "blooming"
            // (petal i and petal 7-i share a band). The bands are already
            // dB-normalised + noise-gated + asymmetric-smoothed upstream in
            // SpectrumAnalyzer (fast attack / slow decay), so the petals are
            // a faithful read of the live spectrum, not raw FFT jitter.
            let half = petalCount / 2
            let bandIndex = petalIndex < half
                ? petalIndex
                : (petalCount - 1 - petalIndex)
            guard bandIndex < bands.count else { return 0.12 }
            // Per-mode "character" so the recording modes read as different
            // by MOTION, not only by the small centre dot. Kept near 1.0 so
            // petals stay a faithful read of the spectrum.
            //
            // Egor 2026-06-19 — dictation now shares meeting's gain
            // (`petalReactiveGain`) EXACTLY, instead of the old 0.92.
            //   Why: the capture→analyzer→spectrumBands→petal pipeline is
            //   byte-for-byte identical across all three modes (one
            //   CoreAudioMicRecorder, one SpectrumAnalyzer, fed
            //   unconditionally from the render workQueue — see
            //   RecordingSession.start()). So the ONLY thing that ever made
            //   dictation petals less reactive than meeting was this 0.92
            //   multiplier. It reads as a tiny "8% smaller" on paper, but
            //   it compounds badly at the low end: a steady solo dictation
            //   voice already normalises into a modest 0.2–0.5 band range
            //   (not the wide swings of a louder, multi-voice meeting), and
            //   the `max(0.12, …)` resting floor eats the bottom — shaving
            //   another 8% off the top collapses the *visible* swing above
            //   the floor, so the petals sat almost frozen (tester report).
            //   Routing dictation through the shared constant equalises its
            //   sensitivity to meeting by construction, and the two can no
            //   longer drift apart. Meeting is unchanged (it was already
            //   1.0 == petalReactiveGain), so this can't regress it.
            //   voiceNote keeps its deliberate +6% liveliness.
            let gain: Float
            switch mode {
            case .meeting, .dictation: gain = Self.petalReactiveGain
            case .voiceNote:           gain = Self.petalReactiveGain * 1.06
            }
            return max(0.12, min(1.0, bands[bandIndex] * gain))
        case .preparing, .stopping, .summarizing, .paused, .idle, .finished, .failed:
            return 1
        }
    }

    private func petalColor(status: RecordingSession.Status) -> Color {
        let cream = Color(red: 245.0 / 255, green: 241.0 / 255, blue: 231.0 / 255)
        switch status {
        case .paused: return cream.opacity(0.78)
        case .idle: return cream.opacity(0.72)
        default: return cream
        }
    }

    private func centerColor(
        for status: RecordingSession.Status,
        mode: RecordingSession.RecordingMode,
        summaryGen: RecordingSession.SummaryGenerationState
    ) -> Color {
        // System-audio failure during a live meeting → RED core, so the
        // user sees at a glance the other side isn't being captured
        // (Screen Recording denied / no audio reaching Daisy). Takes
        // priority over the normal recording hue while capturing.
        if status == .recording || status == .paused {
            switch session.systemAudioStatus {
            case .denied, .failed:
                return .daisyError
            default:
                break
            }
        }
        // "Summary cooking" indicator — when status is .finished but
        // the post-Stop detached task is still running summarize +
        // autoSend, fade the centre to amber and pulse the opacity
        // so the widget reads as "working in the background" without
        // taking over the orange recording signal. Deliberately in
        // the warm-amber family (matches the landing's
        // `--color-petal-center` and the in-app `daisyHomeAccent`)
        // so it's a calmer cousin of recording orange — never
        // confused with "still capturing".
        // No "summary cooking" colour any more (24.09): after Stop the
        // widget is simply ready for the next recording.
        switch status {
        // Recording — center hue encodes the active mode so the
        // user can tell at a peripheral glance which gesture they
        // triggered:
        //   • meetings   → macOS systemOrange (inherits the OS mic-active dot)
        //   • dictation  → vivid lilac (creative output, ⌘V-bound)
        //   • voiceNote  → pink-coral (intimate, personal capture)
        // All three live on the same volume / saturation so no mode
        // reads as "less important" than another — they're sibling
        // states of the same recording action.
        case .recording:
            switch mode {
            case .meeting:   return .daisyRecording
            case .dictation: return .daisyDictation
            case .voiceNote: return .daisyVoiceNote
            }
        // Paused = cool neutral gray. Deliberately OUT of the
        // warm orange/amber family — orange means "live capture",
        // so paused has to read as "not live" at a glance. Stays
        // visually distinct from idle (white) and finished (white)
        // by keeping the centre filled rather than ghostly.
        case .paused: return Color.daisyPaused
        // .preparing forks by whether Whisper still needs to download
        // or load — that path is multi-minute on first run, so we
        // pulse the centre amber (same hue as "summary cooking") to
        // tell the user "this is going to take a while, not stuck".
        // Stream-startup .preparing (model already loaded) stays
        // plain white — fast, not worth a special signal.
        case .preparing:
            // Static white core during Preparing. The rotating petals (the
            // "loader") is the only motion; the core stays calm. The old
            // Whisper-warmup amber pulse was removed here — a small core
            // fading 0.55↔0.95 (plus its shadow) *under* the spinning petals
            // read as a glitchy "loader + blinking core" combo, and snapped
            // to white when warmup finished mid-Preparing. The long first-run
            // model download is still signalled as text (the status/tooltip
            // WhisperEngine.state switch below), just not in the core.
            return Color.white.opacity(0.92)
        // After Stop: the resting centre — the widget is ready for the
        // next recording; summaries are background work (24.09).
        case .stopping, .summarizing, .finished: return Color.daisyCenterIdle
        case .failed: return .daisyError
        // The shared resting centre (DaisyPalette.centerIdle, white) —
        // the same on the phone, the watch and Windows (Egor, 23.09).
        case .idle: return Color.daisyCenterIdle
        }
    }

    // MARK: - Strings

    private var tooltip: String {
        if let problem = systemAudioProblem {
            return session.status == .paused
                ? String(localized: "\(problem) Click to resume · right-click for Stop & save")
                : String(localized: "\(problem) Click to pause")
        }
        switch session.status {
        case .idle: return String(localized: "Click to record")
        case .recording: return String(localized: "Click to pause")
        case .paused: return String(localized: "Click to resume · right-click for Stop & save")
        case .preparing:
            // First-record path on a fresh install spends most of its
            // wait in Whisper download/load (1-3 minutes for the 626 MB
            // model). Surface the real progress so the user knows the
            // app isn't hung.
            switch WhisperEngine.shared.state {
            case .downloading(let p):
                return String(localized: "Downloading transcription model… \(Int(p * 100))%")
            case .loading:
                let percent = Int((WhisperEngine.shared.loadProgress * 100).rounded())
                return String(localized: "Preparing model… about \(percent)%")
            case .notLoaded:
                return String(localized: "Setting up transcription model…")
            default:
                return String(localized: "Preparing…")
            }
        case .stopping: return String(localized: "Stopping…")
        case .summarizing: return String(localized: "Summarizing…")
        case .finished: return String(localized: "Done · click to record again")
        case .failed(let msg): return msg
        }
    }

    /// The other side of the meeting is not being captured — said in
    /// words, not only in the colour of the core.
    ///
    /// Colour audit MAC-01 (2026-09-23): `centerColor` turned the core
    /// red on `denied`/`failed` and nothing else changed — the widget
    /// went on calling itself an ordinary recording, so anyone who
    /// cannot separate red from orange, or who is listening to
    /// VoiceOver, learned about it after the meeting.
    ///
    /// Deliberately says nothing about the microphone: there is no
    /// live mic status to read here, and promising "your voice is
    /// still being recorded" without checking would be the same bug
    /// pointing the other way.
    private var systemAudioProblem: String? {
        guard session.status == .recording || session.status == .paused else { return nil }
        switch session.systemAudioStatus {
        case .denied:
            return String(localized: "System audio is not being recorded — Screen Recording permission is missing.")
        case .failed(let message):
            return String(localized: "System audio stopped being recorded: \(message)")
        case .disabled, .pending, .capturing:
            return nil
        }
    }

    private var accessibilityLabel: String {
        // The failure comes FIRST in the sentence: a screen reader
        // announces from the start, and "Recording" heard alone is
        // exactly the wrong takeaway.
        if let problem = systemAudioProblem {
            switch session.status {
            case .paused: return String(localized: "Daisy. \(problem) Paused. Tap to resume.")
            default: return String(localized: "Daisy. \(problem) Recording. Tap to pause.")
            }
        }
        switch session.status {
        case .idle: return String(localized: "Daisy. Start recording.")
        case .recording: return String(localized: "Daisy. Recording. Tap to pause.")
        case .paused: return String(localized: "Daisy. Paused. Tap to resume.")
        case .preparing: return String(localized: "Daisy. Preparing to record.")
        case .stopping: return String(localized: "Daisy. Stopping.")
        case .summarizing: return String(localized: "Daisy. Summarizing transcript.")
        case .finished: return String(localized: "Daisy. Recording finished.")
        case .failed: return String(localized: "Daisy. Recording failed.")
        }
    }

    private var accessibilityValue: String {
        switch session.status {
        case .failed(let msg): return msg
        default: return tooltip
        }
    }

    // MARK: - Actions

    private func togglePrimary() {
        switch session.status {
        case .recording:
            Task { await session.pause() }
        case .paused:
            Task { await session.resume() }
        case .preparing, .stopping, .summarizing:
            return
        default:
            Task { await session.start() }
        }
    }
}

// MARK: - B+ petal shape

/// Approved B+ outline. The full-length petal occupies y=8...35.8 in
/// the master 100-unit SVG. x=40...60 includes the curve's control points.
struct DaisyPetalShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - 40) / 20 * rect.width,
                    y: rect.minY + (y - 8) / 27.8 * rect.height)
        }
        var path = Path()
        path.move(to: p(50, 35.8))
        path.addCurve(to: p(43.4, 26.1), control1: p(46.75, 35.8), control2: p(44.9, 31.3))
        path.addCurve(to: p(42.25, 13.1), control1: p(42.05, 21.35), control2: p(40.15, 17.5))
        path.addCurve(to: p(50, 8), control1: p(43.8, 9.9), control2: p(46.65, 8))
        path.addCurve(to: p(57.75, 13.1), control1: p(53.35, 8), control2: p(56.2, 9.9))
        path.addCurve(to: p(56.6, 26.1), control1: p(59.85, 17.5), control2: p(57.95, 21.35))
        path.addCurve(to: p(50, 35.8), control1: p(55.1, 31.3), control2: p(53.25, 35.8))
        path.closeSubpath()
        return path
    }
}

// MARK: - Petal subview

private struct Petal: View, Equatable {
    let amplitude: Float
    let angleDegrees: Double
    let color: Color
    let width: CGFloat
    let baseLength: CGFloat
    let maxLength: CGFloat
    let centerSize: CGFloat
    let gap: CGFloat
    let reduceMotion: Bool

    var body: some View {
        let length = baseLength + (maxLength - baseLength) * CGFloat(amplitude)
        let offsetY = -(centerSize / 2 + length / 2 + gap)

        DaisyPetalShape()
            .fill(color)
            .frame(width: width, height: length)
            .offset(y: offsetY)
            .rotationEffect(.degrees(angleDegrees))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: amplitude)
    }
}

#Preview {
    DaisyWidget(session: RecordingSession(settings: AppSettings()))
        .padding(20)
}
