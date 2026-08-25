//
//  DaisyWidget.swift
//  Daisy
//
//  Compact floating puck — 8 teardrop petals around a status-coloured
//  centre. Wispr-Flow-inspired aesthetic: solid dark surface, dense
//  glyph-free centre (colour communicates state), tight padding.
//
//  • Recording / Finished / Failed / Idle — petals are amplitude-driven
//    (FFT bands, mirrored across petals for symmetric blooming).
//  • Preparing / Stopping / Summarizing — a "shimmer" sweep rotates
//    around the daisy while the petals gently "breathe" (a soft per-
//    petal length wave); opacity follows the sweep. Pure black-and-
//    white during summarizing.
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
    /// Under reduce-motion we drop the rotating comet shimmer (a static
    /// ring instead) and the celebration spring (instant settle).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Scales the whole daisy briefly when the session lands in
    /// `.finished` — the "celebration" pop that finishes the loader
    /// arc (shimmer rotates → bounce → settle into white).
    @State private var celebrationScale: CGFloat = 1.0

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

    /// True for the "loader" states whose comet shimmer rotates — those
    /// run at 60fps (see `body`); everything else at 30fps.
    private static func isShimmerStatus(_ status: RecordingSession.Status) -> Bool {
        switch status {
        case .preparing, .stopping, .summarizing: return true
        default: return false
        }
    }

    // Geometry: build 45 shrank everything 20% (×0.8 off the original
    // 7/18/7/10/56); then +10% per request; then −15% per request
    // (2026-06-05) → net ×0.748 of original. Petal/center/canvas scale
    // together to preserve proportions; `passiveScale` still applies on
    // top, so passive (idle/finished) shrinks proportionally relative to
    // this active baseline. Panel container in FloatingPanelController.swift
    // is sized to match (70.4 → 59.84, same ×0.85) so shadow padding stays
    // proportional, well clear of the .shadow(radius:6, y:3) blur extent.
    private let petalCount = 8
    /// Reactive-petal amplitude gain shared by meeting AND dictation, so the
    /// two modes drive the petals with IDENTICAL sensitivity (Egor 2026-06-19
    /// — see `amplitudeFor`). 1.0 == a faithful 1:1 read of the analyzer's
    /// already-normalised/gated/smoothed bands. voiceNote scales OFF this
    /// (×1.06) so its small deliberate liveliness can never silently diverge.
    private static let petalReactiveGain: Float = 1.0
    private let basePetalLength: CGFloat = 5.236  // was 6.16, −15%
    private let maxPetalLength: CGFloat = 13.464  // was 15.84, −15%
    private let petalWidth: CGFloat = 5.236       // was 6.16, −15%
    private let centerSize: CGFloat = 7.48        // was 8.8, −15%
    private let canvasSize: CGFloat = 42.075      // was 49.5, −15%
    private let petalGap: CGFloat = 0.425         // was 0.5, −15%

    var body: some View {
        // One TimelineView wraps everything so the view tree is stable
        // across status transitions (recording → stopping → summarizing).
        // Status only changes computed values per petal (amplitude +
        // colour), never the view identity — that fixed the "petals
        // fall apart" flicker we used to get on stop.
        //
        // Frame cadence is status-driven: the continuously-ROTATING comet
        // (preparing / stopping / summarizing) runs at 60fps so it doesn't
        // stair-step on a 120Hz ProMotion display; everything else
        // (audio-reactive recording, static states) stays at 30fps to keep
        // redraw cheap. Sweep + amplitude derive from wall-clock / live
        // bands (not accumulated in the timeline), so swapping the interval
        // never jumps the animation. Reduce-Motion → 30fps (comet is static).
        let shimmering = Self.isShimmerStatus(session.status)
        let interval = (!reduceMotion && shimmering) ? 1.0 / 60.0 : 1.0 / 30.0
        return TimelineView(.animation(minimumInterval: interval, paused: false)) { context in
            let status = session.status
            let mode = session.currentMode
            let summaryGen = session.summaryGenerationState
            let bands = session.spectrumBands
            let sweep = Self.computeSweep(from: context.date)
            let center = centerColor(for: status, mode: mode, summaryGen: summaryGen)

            ZStack {
                Circle()
                    // Widget backing disc — #1C1A17 (warm near-black,
                    // matches Daisy's dark surface; was a cooler #121216).
                    .fill(Color(red: 28.0 / 255, green: 26.0 / 255, blue: 23.0 / 255))

                ForEach(0..<petalCount, id: \.self) { i in
                    let petalAngle = Double(i) * 360.0 / Double(petalCount)
                    Petal(
                        amplitude: amplitudeFor(petalIndex: i, bands: bands, status: status, mode: mode, date: context.date),
                        angleDegrees: petalAngle,
                        color: petalColor(petalAngle: petalAngle, sweep: sweep, status: status),
                        width: petalWidth,
                        baseLength: basePetalLength,
                        maxLength: maxPetalLength,
                        centerSize: centerSize,
                        gap: petalGap
                    )
                }

                Circle()
                    .fill(center)
                    .frame(width: centerSize, height: centerSize)
                    .shadow(color: center.opacity(0.55), radius: 2.5, x: 0, y: 0)
            }
        }
        .frame(width: canvasSize, height: canvasSize)
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
        .onChange(of: session.status) { _, newStatus in
            handleStatusChange(newStatus)
        }
        .onAppear {
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
            withAnimation(reduceMotion ? shrink : shrink.delay(0.55)) {
                passiveScale = target
            }
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
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
    /// shimmer was spinning → daisy "lands" → petals settle. Overshoot
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

        Menu {
            Button("Hide for 15 minutes") { onHideRequest(15 * 60) }
            Button("Hide for 1 hour")     { onHideRequest(60 * 60) }
            Button("Hide for today") {
                // Hide until the next local midnight (reappears tomorrow),
                // not a fixed 24h window — matches the "for today" intuition.
                let nextMidnight = Calendar.current.startOfDay(
                    for: Date().addingTimeInterval(24 * 60 * 60)
                )
                onHideRequest(nextMidnight.timeIntervalSinceNow)
            }
        } label: {
            Label("Hide…", systemImage: "eye.slash")
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
    /// During processing → fixed mid-length so the daisy reads as a
    /// steady "loader" puck while Whisper / the LLM chews.
    /// Idle / finished / failed → smaller settled position.
    private func amplitudeFor(
        petalIndex: Int,
        bands: [Float],
        status: RecordingSession.Status,
        mode: RecordingSession.RecordingMode,
        date: Date
    ) -> Float {
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
        case .preparing, .stopping, .summarizing:
            // Gentle "breathing": each petal eases its length in/out on a
            // slow sine, offset by petal index so a soft wave travels
            // around the ring — reads as a living flower, not 8 static
            // spokes. Reduce Motion → a calm fixed mid-length (no pulsing).
            if reduceMotion { return 0.55 }
            let t = date.timeIntervalSinceReferenceDate
            let cycle = 2.4   // seconds per full breath
            let phase = t * (2 * Double.pi / cycle)
                + Double(petalIndex) * (2 * Double.pi / Double(petalCount))
            return Float(0.52 + 0.13 * sin(phase))
        case .paused:
            // Paused reads as "held" — petals settled, not animating
            // with the (now-zero) spectrum bands.
            return 0.30
        case .idle, .finished, .failed:
            return 0.30
        }
    }

    /// Compute the petal's colour for the current status. During
    /// processing the colour shimmers (sweep-driven opacity) so the
    /// daisy reads as a loader. Other states use static near-white.
    private func petalColor(
        petalAngle: Double,
        sweep: Double,
        status: RecordingSession.Status
    ) -> Color {
        switch status {
        case .preparing, .stopping, .summarizing:
            // Reduce Motion: no rotating comet — a calm, uniform ring.
            if reduceMotion { return Color.white.opacity(0.82) }
            let opacity = Self.shimmerOpacity(petalAngle: petalAngle, sweep: sweep)
            return Color.white.opacity(opacity)
        case .recording:
            return Color(white: 0.97)
        case .paused:
            // Slightly dimmer than recording so paused reads as
            // "still here, but quiet".
            return Color.white.opacity(0.78)
        case .idle:
            return Color.white.opacity(0.72)
        case .finished, .failed:
            return Color(white: 0.92)
        }
    }

    /// Continuously-advancing sweep angle (0…360) for shimmer + any
    /// future time-driven effects. Pulls `t` into a small range before
    /// multiplying by the angular rate so Double precision doesn't
    /// degrade on a 25-year-old timestamp.
    private static func computeSweep(from date: Date) -> Double {
        let cyclePeriod: Double = 360.0 / 220.0   // ~1.636 s/rev
        let raw = date.timeIntervalSinceReferenceDate
        let phase = raw.truncatingRemainder(dividingBy: cyclePeriod) / cyclePeriod
        return phase * 360.0
    }

    /// Smooth comet pulse — every petal is always clearly visible
    /// (baseline 0.55 so they read on the black puck), with a peak
    /// brightening as the sweep crosses each petal and a gentle 120°
    /// trailing fade behind.
    private static func shimmerOpacity(petalAngle: Double, sweep: Double) -> Double {
        var delta = (sweep - petalAngle).truncatingRemainder(dividingBy: 360)
        if delta < 0 { delta += 360 }
        let trailDeg = 120.0
        let baseline = 0.55
        let peak = 1.0
        if delta < trailDeg {
            // Eased (not linear) falloff so the trail reads as light
            // tapering off, not a hard gradient wipe.
            let t = 1 - delta / trailDeg
            return baseline + (peak - baseline) * pow(t, 1.4)
        }
        return baseline
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
        // `--color-petal-center` and the in-app `daisyCenterIdle`)
        // so it's a calmer cousin of recording orange — never
        // confused with "still capturing".
        if case .finished = status, summaryGen == .generating {
            // "Summary cooking" → STATIC warm amber. The opacity sin-pulse
            // was removed: a centre blinking 0.55↔0.95 under the (now
            // static) petals re-introduced exactly the "loader + blinking
            // core" glitch we deliberately removed from .preparing. The
            // amber HUE (a calm cousin of recording orange) plus the
            // "Generating summary…" tooltip carry the signal — no blink.
            return Color.daisyCenterIdle
        }
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
            // Static white core during Preparing. The petal shimmer (the
            // "loader") is the only motion; the core stays calm. The old
            // Whisper-warmup amber pulse was removed here — a small core
            // fading 0.55↔0.95 (plus its shadow) *under* the spinning petals
            // read as a glitchy "loader + blinking core" combo, and snapped
            // to white when warmup finished mid-Preparing. The long first-run
            // model download is still signalled as text (the status/tooltip
            // WhisperEngine.state switch below), just not in the core.
            return Color.white.opacity(0.92)
        // Finished + processing → plain white. The "done" celebration
        // is the scale-pop animation, not a colour change.
        case .stopping, .summarizing, .finished: return Color.white.opacity(0.92)
        case .failed: return .daisyError
        case .idle: return Color.white.opacity(0.55)
        }
    }

    // MARK: - Strings

    private var tooltip: String {
        // Surface the post-Stop summary phase even though status is
        // already `.finished` — the user just hit Stop and is
        // wondering "is anything still happening?".
        if case .finished = session.status,
           session.summaryGenerationState == .generating {
            return String(localized: "Generating summary…")
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

    private var accessibilityLabel: String {
        if case .finished = session.status,
           session.summaryGenerationState == .generating {
            return String(localized: "Daisy. Recording finished. Summary still generating in the background.")
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

// MARK: - Daisy petal shape (traced from the brand logomark)

/// Single petal traced VERBATIM from the brand logomark
/// (`daisy_logo.svg` on the web; same shape as
/// the favicon / app icon / in-app DaisyMark). We use the "Top" cardinal
/// petal — it's symmetric left-right, so it rotates cleanly into all 8
/// positions and can be length-scaled per petal (audio bloom + loader
/// breathing), which the asymmetric per-direction logo paths can't.
///
/// Native space is the petal's bounding box inside the 41×41 logo:
/// x∈[18,23], y∈[4.36792,14.4453], apex (tip) at the top, rounded base at
/// the bottom. `p(_:_:)` affine-maps that box into `rect`, so the petal
/// fills whatever width/length the widget asks for, tip pointing outward
/// from the centre (matches `Petal`'s offset/rotate). Replaces the old
/// generic teardrop, which read as a flat "lozenge"/"sausage" when the
/// loader drew all eight at one length.
struct DaisyPetalShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Logo-native bounding box of the "Top" petal.
        let bx: CGFloat = 18, bw: CGFloat = 5
        let by: CGFloat = 4.36792, bh: CGFloat = 10.07738
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + (x - bx) / bw * rect.width,
                y: rect.minY + (y - by) / bh * rect.height
            )
        }
        var path = Path()
        path.move(to: p(18, 7.38827))
        path.addCurve(to: p(19.32, 4.36792), control1: p(18, 5.69685), control2: p(18.6726, 4.82008))
        path.addCurve(to: p(21.68, 4.36792), control1: p(20.0225, 3.87736), control2: p(20.9775, 3.87736))
        path.addCurve(to: p(23, 7.38827), control1: p(22.3274, 4.82008), control2: p(23, 5.69685))
        path.addCurve(to: p(21.2918, 14.4453), control1: p(23, 9.7848), control2: p(22.0998, 12.5378))
        path.addCurve(to: p(19.7082, 14.4453), control1: p(20.9785, 15.1849), control2: p(20.0215, 15.1849))
        path.addCurve(to: p(18, 7.38827), control1: p(18.9002, 12.5378), control2: p(18, 9.7848))
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

    var body: some View {
        let length = baseLength + (maxLength - baseLength) * CGFloat(amplitude)
        let offsetY = -(centerSize / 2 + length / 2 + gap)

        DaisyPetalShape()
            .fill(color)
            .frame(width: width, height: length)
            .offset(y: offsetY)
            .rotationEffect(.degrees(angleDegrees))
            .animation(.easeOut(duration: 0.10), value: amplitude)
    }
}

#Preview {
    DaisyWidget(session: RecordingSession(settings: AppSettings()))
        .padding(20)
}
