//
//  DaisyWidget.swift
//  Daisy
//
//  Compact floating puck — 8 teardrop petals around a status-coloured
//  centre. Wispr-Flow-inspired aesthetic: solid dark surface, dense
//  glyph-free centre (colour communicates state), tight padding.
//
//  The flower is the upright B+ mark at rest and during capture (A, the
//  same outline as Assets.xcassets/DaisyMark.imageset/daisy_logo.svg), and
//  softly bent petals (B) while loading. The −11.25° turn tried on
//  2026-10-09 was dropped the same day; the bent loading petals stayed.
//
//  • Recording / dictation / voice note: straight petals follow mirrored FFT bands.
//  • Preparing / Stopping: the petals rotate together clockwise, one
//    revolution per 4.8 seconds, with a stationary status centre.
//  • Other states and Reduce Motion: the still, upright A mark.
//

import SwiftUI
import AppKit

struct DaisyWidget: View {
    private let owner: RecordingSession
    /// Called by the right-click context menu when the user picks
    /// "Hide for N seconds". The panel controller owns the actual hide
    /// + restore timer. Defaults to a no-op for SwiftUI Previews.
    var onHideRequest: (TimeInterval) -> Void = { _ in }

    init(session: RecordingSession, onHideRequest: @escaping (TimeInterval) -> Void = { _ in }) {
        self.owner = session
        self.onHideRequest = onHideRequest
    }

    /// What the flower shows: a dictation held while the last recording
    /// is still finishing runs on a side session, and the flower follows
    /// it while it dictates.
    private var session: RecordingSession { owner.displaySession }

    @Environment(\.openWindow) private var openWindow
    /// Honour System Settings → Accessibility → Display → Reduce Motion.
    /// Under reduce-motion we drop the petal rotation and audio motion and the celebration spring (instant settle).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Scales the whole daisy briefly when the session lands in
    /// `.finished` — the "celebration" pop that finishes the loader
    /// arc (flower rotates → bounce → settle into the ready sage).
    @State private var celebrationScale: CGFloat = 1.0
    @State private var loaderStartedAt = Date()
    @State private var loaderStartOffset: Double = 0
    @State private var restingOffset: Double = 0
    @State private var landingStartOffset: Double = 0
    @State private var landingStartedAt: Date?
    @State private var landingDuration: TimeInterval = Self.minimumLandingDuration

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

    /// Keep the displayed phase through state changes. Equal petals have
    /// equivalent rest poses every 45 degrees; land in the nearest one.
    private func rotationOffset(at date: Date, loading: Bool) -> Double {
        guard !reduceMotion else { return 0 }
        if loading {
            return loaderStartOffset + max(0, date.timeIntervalSince(loaderStartedAt)) * Self.spinDegreesPerSecond
        }
        guard let start = landingStartedAt else { return restingOffset }
        let progress = min(1, max(0, date.timeIntervalSince(start) / landingDuration))
        let eased = 1 - pow(1 - progress, 3)
        return landingStartOffset + (restingOffset - landingStartOffset) * eased
    }

    private func updateRotation(from old: RecordingSession.Status, to new: RecordingSession.Status) {
        let wasLoading = Self.isLoadingStatus(old)
        let loading = Self.isLoadingStatus(new)
        guard wasLoading != loading else { return }
        let now = Date()
        let offset = rotationOffset(at: now, loading: wasLoading)
        if loading {
            loaderStartOffset = offset
            loaderStartedAt = now
            landingStartedAt = nil
        } else {
            landingStartOffset = offset
            // Land FORWARD on the next equivalent pose (every 45°), and
            // take as long as a cubic ease-out needs to start at the
            // spin's own speed: the nearest pose could be up to 22.5°
            // behind, and a fixed 0.20 s ease started at up to ~340°/s —
            // a visible reverse snap (review find, 2026-10-09).
            let target = (offset / 45).rounded(.up) * 45
            restingOffset = target
            landingDuration = max(Self.minimumLandingDuration, 3 * (target - offset) / Self.spinDegreesPerSecond)
            landingStartedAt = reduceMotion ? nil : now
        }
    }

    // The mark uses a 100-unit canvas, matching the exported SVG exactly.
    private let petalCount = 8
    /// The whole mark's resting orientation, and where the loader's
    /// rotation starts from.
    /// Upright (Egor, 2026-10-09: the turned mark is out; the bent loading
    /// petals stay).
    private static let orientationDegrees: Double = 0
    /// One revolution per 4.8 s, clockwise.
    private static let spinDegreesPerSecond: Double = 360 / 4.8
    /// The A↔B shape change, and the shortest landing.
    private static let minimumLandingDuration: TimeInterval = 0.20
    /// 1.3 (was 1.0): on a loud voice the petals stopped short of half
    /// their swing (Egor, 2026-10-09).
    private static let petalReactiveGain: Float = 1.3
    private let canvasSize: CGFloat = 42.075
    private var maxPetalLength: CGFloat { canvasSize * 0.278 }
    /// The shortest a petal gets while recording — at silence it sits a
    /// little above this (the 0.12 floor). 0.72 until 24.09: on a real
    /// voice the bands run 0.35–0.9, which moved a petal between 82% and
    /// 97% of its length — Egor: «реакция на голос слабая». 0.5 nearly
    /// doubles the swing on the same signal. Only recording uses it;
    /// every other state draws the full silhouette (amplitude 1).
    private var basePetalLength: CGFloat { maxPetalLength * 0.5 }
    /// A shared 24-unit box centred on the base contains both A and B.
    private var petalWidth: CGFloat { canvasSize * DaisyPetalShape.boxWidth / 100 }
    private var centerSize: CGFloat { canvasSize * 0.21 }
    private var petalGap: CGFloat { canvasSize * 0.037 }
    /// The canvas is the disc, so at 1:1 the petal tips reach 84% of
    /// its diameter and the flower crowds the edge (Egor, 2026-09-23:
    /// «уменьшить всю композицию чуть-чуть»). One uniform scale for
    /// petals and centre together — the shape and its proportions are
    /// the SVG's and stay untouched.
    private let flowerScale: CGFloat = 0.85

    var body: some View {
        // Preserve one view tree across states. Only petals rotate while
        // loading; the centre keeps the recorder's existing status colour.
        let loading = Self.isLoadingStatus(session.status)
        let interval = loading || landingStartedAt != nil ? 1.0 / 60.0 : 1.0 / 30.0
        let animating = !reduceMotion && (session.status == .recording || loading || landingStartedAt != nil)
        return TimelineView(.animation(minimumInterval: interval, paused: !animating)) { context in
            let status = session.status
            let mode = session.currentMode
            let bands = session.spectrumBands
            // Positive degrees turn clockwise in SwiftUI.
            let rotation = Self.orientationDegrees + rotationOffset(at: context.date, loading: loading)
            let center = centerColor(for: status, mode: mode)

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
                            curvature: loading && !reduceMotion ? 1 : 0,
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
            updateRotation(from: oldStatus, to: newStatus)
            handleStatusChange(newStatus)
        }
        .task(id: landingStartedAt) {
            guard landingStartedAt != nil else { return }
            do {
                try await Task.sleep(for: .seconds(landingDuration))
            } catch { return }
            guard !Task.isCancelled else { return }
            landingStartedAt = nil
        }
        .onChange(of: reduceMotion) { _, _ in
            loaderStartedAt = Date()
            loaderStartOffset = 0
            restingOffset = 0
            landingStartedAt = nil
        }
        .onAppear {
            // Shown again mid-load: carry on from the angle it had.
            loaderStartOffset = rotationOffset(at: Date(), loading: Self.isLoadingStatus(session.status))
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
    /// Processing and static states use the full silhouette.
    /// The existing whole-widget passive scale still applies after capture.
    /// Which spectrum band drives a petal: its distance from the top petal,
    /// so mirror-image petals left and right of vertical share one.
    static func bandIndex(forPetal petal: Int, petalCount: Int) -> Int {
        min(petal, petalCount - petal)
    }

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
            // 8 petals, mirrored across the VERTICAL axis: petal 0 is on top
            // and petal 4 at the bottom, each on its own band; the side
            // pairs (1,7), (2,6), (3,5) share one. The lower 5 of the
            // analyzer's 6 voice-tuned bands are used. Until 2026-10-09 the
            // pairs were (i, 7−i), which mirrors across an axis 22.5° off
            // vertical — the flower breathed lopsided and read as swaying
            // left and right. The bands are already dB-normalised +
            // noise-gated + asymmetric-smoothed upstream in SpectrumAnalyzer
            // (fast attack / slow decay), so the petals are a faithful read
            // of the live spectrum, not raw FFT jitter.
            let bandIndex = Self.bandIndex(forPetal: petalIndex, petalCount: petalCount)
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
            //   longer drift apart. (The shared gain was 1.0 then; 1.3 since
            //   2026-10-09, for both.)
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
        // Cream in every state but pause, where the petals go grey and the
        // centre keeps its orange (Egor's state sheet, 2026-10-09; the
        // colours live in DaisyPalette's petal-mark state group).
        status == .paused ? Color.daisyMarkPausedPetal : Color.daisyMarkPetal
    }

    private func centerColor(
        for status: RecordingSession.Status,
        mode: RecordingSession.RecordingMode
    ) -> Color {
        // System-audio failure during a live meeting → RED core, so the
        // user sees at a glance the other side isn't being captured
        // (Screen Recording denied / no audio reaching Daisy). Takes
        // priority over the normal recording hue while capturing.
        if status == .recording || status == .paused {
            switch session.systemAudioStatus {
            case .denied, .failed:
                return Color.daisyMarkError
            default:
                break
            }
        }
        switch status {
        case .recording:
            switch mode {
            case .meeting:   return Color.daisyMarkMeeting
            case .dictation: return Color.daisyMarkDictation
            case .voiceNote: return Color.daisyMarkVoiceNote
            }
        // Paused keeps the meeting's orange in the centre; the petals go
        // grey instead (see `petalColor`).
        case .paused: return Color.daisyMarkPaused
        case .preparing:
            return Color.white.opacity(0.92)
        case .idle, .stopping, .summarizing, .finished: return Color.daisyMarkReady
        case .failed: return Color.daisyMarkError
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

// MARK: - Petal shape

/// Selected original A (curvature 0) and shallow-bend B (curvature 1).
/// A is static and reactive during capture; B is only the loading shape.
/// The common partition preserves both endpoint curves exactly and pairs
/// points by original arc position, rather than unrelated contour angles.
struct DaisyPetalShape: Shape {
    static let boxMinX: CGFloat = 38
    static let boxWidth: CGFloat = 24
    var curvature: CGFloat = 0

    var animatableData: CGFloat {
        get { curvature }
        set { curvature = newValue }
    }

    func path(in rect: CGRect) -> Path {
        func p(_ sx: CGFloat, _ sy: CGFloat, _ cx: CGFloat, _ cy: CGFloat) -> CGPoint {
            let x = sx + (cx - sx) * curvature
            let y = sy + (cy - sy) * curvature
            return CGPoint(x: rect.minX + (x - Self.boxMinX) / Self.boxWidth * rect.width,
                           y: rect.minY + (y - 8) / 27.8 * rect.height)
        }
        var path = Path()
        path.move(to: p(50, 35.8, 50, 35.8))
        path.addCurve(to: p(48.905223016, 35.6179142212, 48.9587157186, 35.6325883262), control1: p(49.6161187377, 35.8, 49.6479174255, 35.8), control2: p(49.2517698544, 35.7372173533, 49.2958502464, 35.7424234202))
        path.addCurve(to: p(47.9222190019, 35.100287233, 47.9995296847, 35.1598057105), control1: p(48.5605083872, 35.4992418505, 48.6215811908, 35.5227532322), control2: p(48.2334080605, 35.3246450676, 48.2993793142, 35.3606596241))
        path.addCurve(to: p(47.0969652386, 34.3535248034, 47.1663321134, 34.4554769299), control1: p(47.6339301276, 34.8924397339, 47.6996800552, 34.958951797), control2: p(47.3592968891, 34.6418854697, 47.4221826726, 34.7193375782))
        path.addCurve(to: p(46.4103931019, 33.4761478598, 46.4593541881, 33.601353766), control1: p(46.8582625912, 34.0911376522, 46.9104815541, 34.1916162817), control2: p(46.6297452542, 33.7974480435, 46.6762778181, 33.903509204))
        path.addCurve(to: p(45.8291339612, 32.5251636437, 45.8560093469, 32.6585546593), control1: p(46.209191292, 33.1814337308, 46.2424305582, 33.2991983279), control2: p(46.0157006683, 32.8634892699, 46.0427870343, 32.9829945294))
        path.addCurve(to: p(45.3258630704, 31.5304680708, 45.3308750389, 31.6636859766), control1: p(45.6555976715, 32.2104677648, 45.6692316595, 32.3341147893), control2: p(45.4880518966, 31.8781382716, 45.4953198087, 32.0014388478))
        path.addCurve(to: p(44.8809273768, 30.5082423491, 44.8634823599, 30.636975417), control1: p(45.1729674554, 31.2027189256, 45.1664302691, 31.3259331054), control2: p(45.0248324841, 30.8613367127, 45.0114525802, 30.9831033045))
        path.addCurve(to: p(44.4803119862, 29.4677949474, 44.4387988622, 29.5897620339), control1: p(44.7436956989, 30.1715223197, 44.7155121397, 30.2908475296), control2: p(44.6103106715, 29.8241512265, 44.574549388, 29.9414215556))
        path.addCurve(to: p(44.1137750147, 28.4148291291, 44.0457917486, 28.5287725423), control1: p(44.355129948, 29.1246422049, 44.3030483365, 29.2381025122), control2: p(44.2330879625, 28.7731577708, 44.1725100367, 28.8842094428))
        path.addCurve(to: p(43.7735678868, 27.3530485075, 43.6756219867, 27.458410863), control1: p(43.9979251417, 28.0669010261, 43.9190734606, 28.1733356417), control2: p(43.884648184, 27.7125202577, 43.7961751842, 27.81635491))
        path.addCurve(to: p(43.4535984764, 26.2849858195, 43.3188684979, 26.3823907153), control1: p(43.6649275319, 27.0014727603, 43.5550687892, 27.1004668159), control2: p(43.5583883956, 26.6450272277, 43.4368606706, 26.7415594534))
        path.addCurve(to: p(43.4, 26.1, 43.2577353498, 26.1962484711), control1: p(43.4356817688, 26.2234268765, 43.2984872762, 26.3203501789), control2: p(43.4178161964, 26.1617628142, 43.2781124976, 26.2583018439))
        path.addCurve(to: p(43.1401577644, 25.2149856194, 42.9638299426, 25.3046360797), control1: p(43.315180878, 25.8015623484, 43.1601439098, 25.8990587929), control2: p(43.2281906416, 25.5066774293, 43.062498126, 25.6017535648))
        path.addCurve(to: p(42.8117502339, 24.1494784336, 42.6020681024, 24.2278316411), control1: p(43.0315690183, 24.8551831351, 42.8445597868, 24.9454802957), control2: p(42.9213938655, 24.5002390545, 42.7237957021, 24.5865988416))
        path.addCurve(to: p(42.4791476291, 23.0852687541, 42.2360973505, 23.151246435), control1: p(42.699570189, 23.7906035803, 42.4803405027, 23.8690644406), control2: p(42.5879465414, 23.4361079794, 42.3576493881, 23.5104114938))
        path.addCurve(to: p(42.1562049254, 22.0181005046, 41.8775135297, 22.0715200638), control1: p(42.3677253249, 22.7259699885, 42.1145453129, 22.7920813761), control2: p(42.2592656201, 22.3705060516, 41.9941323522, 22.4324042053))
        path.addCurve(to: p(41.8590011447, 20.9435172873, 41.5421287851, 20.9846810808), control1: p(42.0505934886, 21.6569729549, 41.7608947072, 21.7106359222), control2: p(41.9506516191, 21.2990570583, 41.6480700228, 21.34854481))
        path.addCurve(to: p(41.6063076863, 19.8576769754, 41.2484519396, 19.8875586239), control1: p(41.7651337101, 20.57937726, 41.4361875475, 20.6208173516), control2: p(41.679963648, 20.2177297022, 41.3371297566, 20.2551810055))
        path.addCurve(to: p(41.4196794561, 18.7586686016, 41.0172694373, 18.7791416676), control1: p(41.5310912889, 19.489996365, 41.1597741227, 19.5199362423), control2: p(41.4678820228, 19.1239788758, 41.0814762796, 19.1503278251))
        path.addCurve(to: p(41.3224539387, 17.6483281716, 40.8703816963, 17.6620921527), control1: p(41.3707909813, 18.388160072, 40.953062595, 18.4079555101), control2: p(41.3373393263, 18.0183790276, 40.9029467534, 18.0351916122))
        path.addCurve(to: p(41.3367883642, 16.5339960697, 40.8278598572, 16.5438323777), control1: p(41.3075368675, 17.2774896584, 40.8378166392, 17.2889926932), control2: p(41.3112651848, 16.9063801839, 40.8228023667, 16.9155576721))
        path.addCurve(to: p(41.4786896137, 15.4287602675, 40.9042304545, 15.4362520871), control1: p(41.3619325777, 16.167141082, 40.8329173478, 16.1721070832), control2: p(41.4082292419, 15.7990490251, 40.8580466014, 15.8020915154))
        path.addCurve(to: p(41.7531916425, 14.3488118438, 41.1054275009, 14.3536482509), control1: p(41.5467441338, 15.0711149265, 40.9504143077, 15.0704126588), control2: p(41.6373404056, 14.7114203354, 41.0176527604, 14.7087493701))
        path.addCurve(to: p(42.1531890579, 13.3087057988, 41.4291193998, 13.3101402841), control1: p(41.86304527, 14.0049755654, 41.1932022413, 13.9985471318), control2: p(41.9956066539, 13.6585192817, 41.3015132694, 13.6500081822))
        path.addCurve(to: p(42.25, 13.1, 41.5105672786, 13.100876996), control1: p(42.1844675587, 13.2392713885, 41.4554502129, 13.2400104396), control2: p(42.2167318427, 13.1697047105, 41.4826025732, 13.1702497912))
        path.addCurve(to: p(42.6682422323, 12.320464115, 41.8687756953, 12.3186732958), control1: p(42.3803752597, 12.8308381736, 41.6181269807, 12.834050756), control2: p(42.5199480306, 12.5708738584, 41.7377043237, 12.5729623241))
        path.addCurve(to: p(43.2885553732, 11.3946869105, 42.418484844, 11.3924049341), control1: p(42.860674338, 11.9955230606, 42.0339246276, 11.9982710522), control2: p(43.0677921373, 11.686670595, 42.2173212596, 11.6886634115))
        path.addCurve(to: p(44.01246006, 10.5475635542, 43.0747867028, 10.5465648053), control1: p(43.5157792404, 11.0941583299, 42.6196484284, 11.0961464567), control2: p(43.7574588976, 10.8115003066, 42.8385789652, 10.8132371425))
        path.addCurve(to: p(44.8359468063, 9.7970068, 43.8341512965, 9.7981213985), control1: p(44.2734104769, 10.2774690774, 43.3109944404, 10.2798924681), control2: p(44.5483112393, 10.0269796074, 43.5644793787, 10.0294571079))
        path.addCurve(to: p(45.7505216511, 9.1607213068, 44.6898719883, 9.1639202782), control1: p(45.1280923427, 9.563428144, 44.1038232142, 9.566785689), control2: p(45.433375164, 9.3510145748, 44.3896821112, 9.3545496302))
        path.addCurve(to: p(46.7428845128, 8.6543386143, 45.6308631511, 8.6586893123), control1: p(46.0697241377, 8.9691944042, 44.9900618653, 8.9732909262), control2: p(46.4009446083, 8.8000755359, 45.3045827224, 8.8042682808))
        path.addCurve(to: p(47.7954893681, 8.2893515552, 46.6419007354, 8.2932247965), control1: p(47.0835416374, 8.5091484215, 45.9571435799, 8.5131103437), control2: p(47.4348379193, 8.3871650708, 46.2951835804, 8.3909750519))
        path.addCurve(to: p(48.8881000625, 8.0714683869, 47.7047904631, 8.0732406867), control1: p(48.1510119513, 8.1929290567, 46.9886178904, 8.195474541), control2: p(48.5156255116, 8.1199938374, 47.3440121998, 8.1221093219))
        path.addCurve(to: p(50, 8, 48.8, 8), control1: p(49.2516266874, 8.0241086595, 48.0655687265, 8.0243720514), control2: p(49.6226411517, 8, 48.4317309438, 8))
        path.addCurve(to: p(51.1118999375, 8.0714683869, 49.9078387527, 8.0732406867), control1: p(50.3773588483, 8, 49.1682690562, 8), control2: p(50.7483733126, 8.0241086595, 49.5386449513, 8.0243720514))
        path.addCurve(to: p(52.2045106319, 8.2893515552, 51.0084609992, 8.2932247965), control1: p(51.4843744884, 8.1199938374, 50.277032554, 8.1221093219), control2: p(51.8489880487, 8.1929290567, 50.6450442615, 8.195474541))
        path.addCurve(to: p(53.2571154872, 8.6543386143, 52.08152002, 8.6586893123), control1: p(52.5651620807, 8.3871650708, 51.3718777368, 8.3909750519), control2: p(52.9164583626, 8.5091484215, 51.7306995046, 8.5131103437))
        path.addCurve(to: p(54.2494783489, 9.1607213068, 53.1068857066, 9.1639202782), control1: p(53.5990553917, 8.8000755359, 52.4323405353, 8.8042682808), control2: p(53.9302758623, 8.9691944042, 52.7751597983, 8.9732909262))
        path.addCurve(to: p(55.1640531937, 9.7970068, 54.0662751075, 9.7981213985), control1: p(54.566624836, 9.3510145748, 53.438611615, 9.3545496302), control2: p(54.8719076573, 9.563428144, 53.7592441689, 9.566785689))
        path.addCurve(to: p(55.98753994, 10.5475635542, 54.9447692546, 10.5465648053), control1: p(55.4516887607, 10.0269796074, 54.3733060462, 10.0294571079), control2: p(55.7265895231, 10.2774690774, 54.6667353697, 10.2798924681))
        path.addCurve(to: p(56.7114446268, 11.3946869105, 55.7315155796, 11.3924049341), control1: p(56.2425411024, 10.8115003066, 55.2228031394, 10.8132371425), control2: p(56.4842207596, 11.0941583299, 55.4854415856, 11.0961464567))
        path.addCurve(to: p(57.3317577677, 12.320464115, 56.4189753411, 12.3186732958), control1: p(56.9322078627, 11.686670595, 55.9775895737, 11.6886634115), control2: p(57.139325662, 11.9955230606, 56.2070991155, 11.9982710522))
        path.addCurve(to: p(57.75, 13.1, 56.8893594428, 13.100876996), control1: p(57.4800519694, 12.5708738584, 56.5871320896, 12.5729623241), control2: p(57.6196247403, 12.8308381736, 56.7441818031, 12.834050756))
        path.addCurve(to: p(57.8468109421, 13.3087057988, 57.0001737319, 13.3101402841), control1: p(57.7832681573, 13.1697047105, 56.9271045262, 13.1702497912), control2: p(57.8155324413, 13.2392713885, 56.9640471042, 13.2400104396))
        path.addCurve(to: p(58.2468083575, 14.3488118438, 57.4662426922, 14.3536482509), control1: p(58.0043933461, 13.6585192817, 57.1752529877, 13.6500081822), control2: p(58.13695473, 14.0049755654, 57.3311685902, 13.9985471318))
        path.addCurve(to: p(58.5213103863, 15.4287602675, 57.8080031905, 15.4362520871), control1: p(58.3626595944, 14.7114203354, 57.6013167941, 14.7087493701), control2: p(58.4532558662, 15.0711149265, 57.7155493957, 15.0704126588))
        path.addCurve(to: p(58.6632116358, 16.5339960697, 58.0206469752, 16.5438323777), control1: p(58.5917707581, 15.7990490251, 57.9004569854, 15.8020915154), control2: p(58.6380674223, 16.167141082, 57.9711319735, 16.1721070832))
        path.addCurve(to: p(58.6775460613, 17.6483281716, 58.1079826707, 17.6620921527), control1: p(58.6887348152, 16.9063801839, 58.070161977, 16.9155576721), control2: p(58.6924631325, 17.2774896584, 58.0985169924, 17.2889926932))
        path.addCurve(to: p(58.5803205439, 18.7586686016, 58.0830578179, 18.7791416676), control1: p(58.6626606737, 18.0183790276, 58.1174483491, 18.0351916122), control2: p(58.6292090187, 18.388160072, 58.1080246904, 18.4079555101))
        path.addCurve(to: p(58.3936923137, 19.8576769754, 57.965235373, 19.8875586239), control1: p(58.5321179772, 19.1239788758, 58.0580909453, 19.1503278251), control2: p(58.4689087111, 19.489996365, 58.0175808589, 19.5199362423))
        path.addCurve(to: p(58.1409988553, 20.9435172873, 57.7762491208, 20.9846810808), control1: p(58.320036352, 20.2177297022, 57.9128898871, 20.2551810055), control2: p(58.2348662899, 20.57937726, 57.8487090018, 20.6208173516))
        path.addCurve(to: p(57.8437950746, 22.0181005046, 57.5372025988, 22.0715200638), control1: p(58.0493483809, 21.2990570583, 57.7037892397, 21.34854481), control2: p(57.9494065114, 21.6569729549, 57.623050363, 21.7106359222))
        path.addCurve(to: p(57.5208523709, 23.0852687541, 57.2670620095, 23.151246435), control1: p(57.7407343799, 22.3705060516, 57.4513548346, 22.4324042053), control2: p(57.6322746751, 22.7259699885, 57.3603981828, 22.7920813761))
        path.addCurve(to: p(57.1882497661, 24.1494784336, 56.9820680794, 24.2278316411), control1: p(57.4120534586, 23.4361079794, 57.1737258362, 23.5104114938), control2: p(57.300429811, 23.7906035803, 57.0780101413, 23.8690644406))
        path.addCurve(to: p(56.8598422356, 25.2149856194, 56.6940987449, 25.3046360797), control1: p(57.0786061345, 24.5002390545, 56.8861260174, 24.5865988416), control2: p(56.9684309817, 24.8551831351, 56.7899575885, 24.9454802957))
        path.addCurve(to: p(56.6, 26.1, 56.4558444701, 26.1962484711), control1: p(56.7718093584, 25.5066774293, 56.6147979517, 25.6017535648), control2: p(56.684819122, 25.8015623484, 56.5357090294, 25.8990587929))
        path.addCurve(to: p(56.5464015236, 26.2849858195, 56.4057067374, 26.3823907153), control1: p(56.5821838036, 26.1617628142, 56.439168705, 26.2583018439), control2: p(56.5643182312, 26.2234268765, 56.422459124, 26.3203501789))
        path.addCurve(to: p(56.2264321132, 27.3530485075, 56.1082956904, 27.458410863), control1: p(56.4416116044, 26.6450272277, 56.3087228317, 26.7415594534), control2: p(56.3350724681, 27.0014727603, 56.2103042785, 27.1004668159))
        path.addCurve(to: p(55.8862249853, 28.4148291291, 55.7900218778, 28.5287725423), control1: p(56.115351816, 27.7125202577, 56.0062871024, 27.81635491), control2: p(56.0020748583, 28.0669010261, 55.9006884794, 28.1733356417))
        path.addCurve(to: p(55.5196880138, 29.4677949474, 55.4414338723, 29.5897620339), control1: p(55.7669120375, 28.7731577708, 55.6793552761, 28.8842094428), control2: p(55.644870052, 29.1246422049, 55.5636206958, 29.2381025122))
        path.addCurve(to: p(55.1190726232, 30.5082423491, 55.0537367607, 30.636975417), control1: p(55.3896893285, 29.8241512265, 55.3192470489, 29.9414215556), control2: p(55.2563043011, 30.1715223197, 55.1906079823, 30.2908475296))
        path.addCurve(to: p(54.6741369296, 31.5304680708, 54.6159938798, 31.6636859766), control1: p(54.9751675159, 30.8613367127, 54.916865539, 30.9831033045), control2: p(54.8270325446, 31.2027189256, 54.7717621623, 31.3259331054))
        path.addCurve(to: p(54.1708660388, 32.5251636437, 54.1133441685, 32.6585546593), control1: p(54.5119481034, 31.8781382716, 54.4602255973, 32.0014388478), control2: p(54.3444023285, 32.2104677648, 54.293792409, 32.3341147893))
        path.addCurve(to: p(53.5896068981, 33.4761478598, 53.5256340259, 33.601353766), control1: p(53.9842993317, 32.8634892699, 53.9328959279, 32.9829945294), control2: p(53.790808708, 33.1814337308, 53.7384326351, 33.2991983279))
        path.addCurve(to: p(52.9030347614, 34.3535248034, 52.8280540707, 34.4554769299), control1: p(53.3702547458, 33.7974480435, 53.3128354168, 33.903509204), control2: p(53.1417374088, 34.0911376522, 53.0817014913, 34.1916162817))
        path.addCurve(to: p(52.0777809981, 35.100287233, 51.9991975591, 35.1598057105), control1: p(52.6407031109, 34.6418854697, 52.5744066501, 34.7193375782), control2: p(52.3660698724, 34.8924397339, 52.2982457344, 34.958951797))
        path.addCurve(to: p(51.094776984, 35.6179142212, 51.0411972466, 35.6325883262), control1: p(51.7665919395, 35.3246450676, 51.7001493837, 35.3606596241), control2: p(51.4394916128, 35.4992418505, 51.3782139489, 35.5227532322))
        path.addCurve(to: p(50, 35.8, 50, 35.8), control1: p(50.7482301456, 35.7372173533, 50.7041805442, 35.7424234202), control2: p(50.3838812623, 35.8, 50.3520825745, 35.8))
        path.closeSubpath()
        return path
    }
}

// MARK: - Petal subview

private struct Petal: View, Equatable {
    let amplitude: Float
    let angleDegrees: Double
    let curvature: CGFloat
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

        // Shorten along the radial axis, anchored at the base. No local tilt.
        // The shape's own animation sits closest to it: when amplitude and
        // curvature change together (recording ↔ stopping), the inner
        // modifier wins, and the A↔B morph must keep its 0.20 s ease.
        DaisyPetalShape(curvature: curvature)
            .fill(color)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.20), value: curvature)
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
