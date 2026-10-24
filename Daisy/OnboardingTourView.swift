//
//  OnboardingTourView.swift
//  Daisy
//
//  The first-run tour's window (Onboarding 2.0): one scene per step,
//  centred, a rounded heading and a line or two — the approved
//  prototype's `.scene`s. The script and every side effect live in
//  `OnboardingTourController`; this file draws the window and the one
//  piece of AppKit the tour needs beyond the bubble, the flower that
//  flies from the window to the widget on step 3.
//
//  While Daisy speaks from the widget (steps 3, 6, 7) the window steps
//  aside — a touch smaller and fainter, as in the prototype — so the eye
//  goes to the widget.
//

import AppKit
import SwiftUI

struct OnboardingTourView: View {
    @Bindable var session: RecordingSession
    @Bindable var settings: AppSettings
    @Bindable private var tour = OnboardingTourController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            scene
                .id(tour.tour.step)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(stepsAside ? 0.96 : 1)
                .opacity(stepsAside ? 0.92 : 1)
            if showsSkipTour {
                Button(OnboardingCopy.text(.skipTour)) { tour.skipTour() }
                    .buttonStyle(DaisyButtonStyle(tone: .quiet, shape: .capsule))
                    .controlSize(.small)
                    .padding(.top, 14)
                    .padding(.trailing, 16)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: tour.tour.step)
        .animation(reduceMotion ? nil : .spring(duration: 0.6), value: stepsAside)
        .background(Color.daisyBgPrimary)
        .onAppear { tour.attach(settings: settings, session: session) }
        .onChange(of: session.isDictating) { _, listening in tour.setListening(listening) }
        .onChange(of: settings.dictationHotkey) { _, _ in tour.refreshBubble() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            SystemPermissions.shared.refresh()
        }
    }

    /// Daisy speaks from the widget; the window gives her the stage.
    private var stepsAside: Bool {
        switch tour.tour.step {
        case .widget, .daisyKey: true
        case .meeting:
            if case .showing = tour.meeting { false } else { true }
        default: false
        }
    }

    /// «Пропустить тур» in the corner of every step but the first (which
    /// has it beside «Поехали») and the last.
    private var showsSkipTour: Bool {
        tour.tour.step != .hello && tour.tour.step != .done
    }

    @ViewBuilder
    private var scene: some View {
        switch tour.tour.step {
        case .hello: HelloScene()
        case .you: YouScene(settings: settings)
        case .widget: WidgetScene()
        case .dictation: PracticeScene(session: session, settings: settings, isStyle: false)
        case .style: PracticeScene(session: session, settings: settings, isStyle: true)
        case .daisyKey: DaisyKeyScene(session: session)
        case .meeting: MeetingScene()
        case .models: ModelsScene()
        case .done: DoneScene()
        }
    }
}

// MARK: - Shared pieces

private struct TourHeading: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.largeTitle, design: .rounded).weight(.semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TourLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(Color.daisyTextSecondary)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .frame(maxWidth: 420)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The centred column every scene sits in.
private struct SceneColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 14) {
            content
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension ButtonStyle where Self == DaisyButtonStyle {
    static var tourPrimary: DaisyButtonStyle { DaisyButtonStyle(tone: .primary, shape: .capsule) }
    static var tourGhost: DaisyButtonStyle { DaisyButtonStyle(tone: .quiet, shape: .capsule) }
}

/// A choice card — the prototype's `.card`: bold title, a quiet line.
private struct TourCard: View {
    let title: String
    let detail: String
    var isPicked = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.daisyTextPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.daisyTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .padding(14)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(Color.daisyBgSidebar, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isPicked ? Color.daisyAccent : Color.daisyDivider, lineWidth: isPicked ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// One permission the step needs, with the one line that says why.
private struct TourPermissionRow: View {
    let icon: String
    let why: String
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.daisyAccent)
                .frame(width: 22)
            Text(why)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button(OnboardingCopy.text(.allow), action: action)
                    .buttonStyle(.tourPrimary)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 460)
        .background(Color.daisyBgSidebar, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.daisyDivider, lineWidth: 1))
    }
}

// MARK: - 1 Hello

private struct HelloScene: View {
    @State private var shown = false
    @State private var leaving = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SceneColumn {
            TourBloom(size: 84)
                .scaleEffect(leaving ? 0.2 : 1)
                .opacity(leaving ? 0 : 1)
                .padding(.bottom, 6)
            VStack(spacing: 10) {
                Text(OnboardingCopy.text(.helloTitle))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .rising(shown, delay: 0)
                TourLine(text: OnboardingCopy.text(.helloLine))
                    .rising(shown, delay: 0.8)
            }
            HStack(spacing: 10) {
                Button(OnboardingCopy.text(.go)) {
                    // One move per press: a double click mustn't skip «Ты».
                    guard !leaving else { return }
                    withAnimation(reduceMotion ? nil : .easeIn(duration: 0.35)) { leaving = true }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 350))
                        OnboardingTourController.shared.next()
                    }
                }
                .buttonStyle(.tourPrimary)
                .keyboardShortcut(.defaultAction)
                Button(OnboardingCopy.text(.skipTour)) {
                    OnboardingTourController.shared.skipTour()
                }
                .buttonStyle(.tourGhost)
            }
            .padding(.top, 8)
        }
        .onAppear { shown = true }
    }
}

private extension View {
    /// The prototype's line-by-line `rise`: up 6 pt and in, after a delay.
    func rising(_ shown: Bool, delay: Double) -> some View {
        modifier(Rising(shown: shown, delay: delay))
    }
}

private struct Rising: ViewModifier {
    let shown: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 6)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.5).delay(delay), value: shown)
    }
}

/// The Daisy mark opening petal by petal (the prototype's `.bloom`): eight
/// petals of the widget's shape grow out one after another around the
/// brand-amber core.
struct TourBloom: View {
    let size: CGFloat
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let count = 8

    var body: some View {
        let length = size * 0.278
        let width = size * DaisyPetalShape.boxWidth / 100
        let core = size * 0.21
        let gap = size * 0.037
        ZStack {
            ForEach(0..<Self.count, id: \.self) { i in
                DaisyPetalShape()
                    .fill(Color.daisyTextPrimary)
                    .frame(width: width, height: length)
                    .scaleEffect(open || reduceMotion ? 1 : 0, anchor: .bottom)
                    .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.6).delay(0.05 * Double(i + 1)), value: open)
                    .offset(y: -(core / 2 + length / 2 + gap))
                    .rotationEffect(.degrees(Double(i) * 360 / Double(Self.count)))
            }
            Circle()
                .fill(Color.daisyAccent)
                .frame(width: core, height: core)
        }
        .frame(width: size, height: size)
        .onAppear { open = true }
        .accessibilityHidden(true)
    }
}

// MARK: - 2 You

private struct YouScene: View {
    @Bindable var settings: AppSettings
    @State private var picked: OnboardingTour.Path?

    var body: some View {
        SceneColumn {
            TourHeading(text: OnboardingCopy.text(.youTitle))
            TextField(OnboardingCopy.text(.youPlaceholder), text: $settings.userDisplayName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
                .padding(.bottom, 10)
            TourLine(text: OnboardingCopy.text(.youPurpose))
            HStack(alignment: .top, spacing: 12) {
                TourCard(title: OnboardingCopy.text(.youFullTitle),
                         detail: OnboardingCopy.text(.youFullDetail),
                         isPicked: picked == .full) { pick(.full) }
                TourCard(title: OnboardingCopy.text(.youDictationTitle),
                         detail: OnboardingCopy.text(.youDictationDetail),
                         isPicked: picked == .dictationOnly) { pick(.dictationOnly) }
            }
            .frame(maxWidth: 460)
        }
    }

    /// The card lights up, then the tour moves on (the prototype's 350 ms).
    private func pick(_ path: OnboardingTour.Path) {
        guard picked == nil else { return }
        picked = path
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            OnboardingTourController.shared.choosePath(path)
        }
    }
}

// MARK: - 3 Widget

private struct WidgetScene: View {
    var body: some View {
        SceneColumn {
            TourHeading(text: OnboardingCopy.text(.widgetTitle))
            TourLine(text: OnboardingCopy.text(.widgetLine))
        }
    }
}

// MARK: - 4 Dictation, 5 Style

/// The practice field and the key: dictation (4) asks for anything, style
/// (5) gives a passage to read. The real pipeline fills the field —
/// `DictationPaste.practiceSink` hands the text over.
private struct PracticeScene: View {
    @Bindable var session: RecordingSession
    @Bindable var settings: AppSettings
    let isStyle: Bool
    @Bindable private var tour = OnboardingTourController.shared
    @FocusState private var focused: Bool

    var body: some View {
        SceneColumn {
            TourHeading(text: OnboardingCopy.text(isStyle ? .styleTitle : .dictationTitle))
            if isStyle {
                // Plain, a size up — a text to read, not a warning (Egor 24.10).
                Text(OnboardingCopy.text(.stylePassage))
                    .font(.system(size: 17, design: .rounded))
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            practiceField
            if isStyle {
                styleCounter
            }
            HStack(spacing: 16) {
                WhatsNewKeycaps(caps: WhatsNewKeycaps.caps(for: tour.dictationKey), down: session.isDictating)
                if !isStyle { keyPicker }
            }
            .padding(.top, 4)
            ModelProgressLine()
        }
        .onAppear { focused = true }
    }

    private var practiceField: some View {
        TextEditor(text: $tour.practiceText)
            .font(.system(size: 15))
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 150)
            .background(Color.daisyBgSidebar, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.daisyDivider, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if tour.practiceText.isEmpty {
                    Text(isStyle ? OnboardingCopy.stylePlaceholder(tour.dictationKey)
                                 : OnboardingCopy.text(.dictationPlaceholder))
                        .font(.system(size: 15))
                        .foregroundStyle(Color.daisyTextTertiary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
    }

    /// «27 / 300 слов до профиля стиля» and the bar under it.
    private var styleCounter: some View {
        let progress = TourHooks.styleProgress(tour.styleLocale)
        let fraction = progress.threshold > 0 ? min(1, Double(progress.words) / Double(progress.threshold)) : 0
        return VStack(spacing: 6) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(Color.daisyAccent)
            Text(OnboardingCopy.styleCounter(words: progress.words, threshold: progress.threshold))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Color.daisyTextSecondary)
        }
    }

    /// fn / right ⌘ / right ⌥ / ⌃Space, bound to the real setting.
    private var keyPicker: some View {
        var options = OnboardingCopy.dictationKeys
        if settings.dictationHotkey.keyCode != nil,
           !options.contains(where: { $0.choice == settings.dictationHotkey }) {
            options.append((settings.dictationHotkey, settings.dictationHotkey.displayLabel))
        }
        return Picker(selection: $settings.dictationHotkey) {
            ForEach(options, id: \.choice) { option in
                Text(option.name).tag(option.choice)
            }
        } label: {
            Text(OnboardingCopy.text(.dictationKeyLabel))
        }
        .pickerStyle(.menu)
        .fixedSize()
    }
}

/// Under the practice field while the standard model is still on its way:
/// a dictation started now waits for it, and this says how long.
private struct ModelProgressLine: View {
    @Bindable private var whisper = WhisperEngine.shared
    private var preparation: ModelPreparation { OnboardingTourController.shared.preparation }

    var body: some View {
        if preparation.isRunning, !whisper.isReady {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                if case .downloading(let progress) = whisper.state {
                    Text("\(Int(progress * Double(whisper.activeModelSizeMB))) / \(whisper.activeModelSizeMB) MB")
                } else {
                    Text(preparation.stage)
                }
            }
            .font(.caption)
            .foregroundStyle(Color.daisyTextSecondary)
        }
    }
}

// MARK: - 6 Daisy key

private struct DaisyKeyScene: View {
    @Bindable var session: RecordingSession
    @Bindable private var tour = OnboardingTourController.shared
    @Bindable private var permissions = SystemPermissions.shared

    var body: some View {
        SceneColumn {
            TourHeading(text: OnboardingCopy.text(.daisyKeyTitle))
            TourLine(text: OnboardingCopy.text(.daisyKeyLine))
            WhatsNewKeycaps(caps: WhatsNewKeycaps.caps(for: tour.daisyKey), down: session.isDictating)
                .padding(.top, 6)
            if permissions.accessibility != .granted {
                TourPermissionRow(icon: "keyboard",
                                  why: OnboardingCopy.text(.daisyKeyAccessWhy),
                                  isBusy: false) {
                    tour.requestAccessibilityAgain()
                }
                .padding(.top, 8)
            }
        }
    }
}

// MARK: - 7 Meeting

private struct MeetingScene: View {
    @Bindable private var tour = OnboardingTourController.shared
    @Bindable private var store = SessionStore.shared

    var body: some View {
        if case .showing(let id) = tour.meeting {
            shown(id)
        } else {
            SceneColumn {
                TourHeading(text: OnboardingCopy.text(.meetingTitle))
                TourLine(text: OnboardingCopy.text(.meetingLine))
                if tour.needsMeetingAccess {
                    TourPermissionRow(icon: "speaker.wave.2",
                                      why: OnboardingCopy.text(.meetingAccessWhy),
                                      isBusy: tour.isAskingMeetingAccess) {
                        tour.askMeetingAccess()
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    TourCard(title: OnboardingCopy.text(.meetingDemoTitle),
                             detail: OnboardingCopy.text(.meetingDemoDetail)) { tour.showDemo() }
                    TourCard(title: OnboardingCopy.text(.meetingSelfTitle),
                             detail: OnboardingCopy.text(.meetingSelfDetail)) { tour.recordMeeting() }
                }
                .frame(maxWidth: 460)
                .disabled(tour.meeting != .choosing)
            }
        }
    }

    /// The meeting itself — the demo, or the person's own 20 seconds —
    /// as the Library shows it, with «Дальше» under it.
    @ViewBuilder
    private func shown(_ id: String?) -> some View {
        VStack(spacing: 0) {
            if let id, let stored = store.sessions.first(where: { $0.id == id }) {
                SessionDetailView(initialSession: stored)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SceneColumn {
                    TourHeading(text: OnboardingCopy.text(.meetingTitle))
                }
            }
            Divider()
            HStack {
                Spacer()
                Button(OnboardingCopy.text(.next)) { tour.next() }
                    .buttonStyle(.tourPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }
}

// MARK: - 8 Models

private struct ModelsScene: View {
    @Bindable private var tour = OnboardingTourController.shared
    @Bindable private var whisper = WhisperEngine.shared

    var body: some View {
        SceneColumn {
            TourHeading(text: OnboardingCopy.text(.modelsTitle))
            TourLine(text: OnboardingCopy.text(.modelsLine))
            modelRow
            ImprovementConsentRow()
                .frame(maxWidth: 460)
            HStack(spacing: 10) {
                if tour.modelsReady {
                    Button(OnboardingCopy.text(.next)) { tour.next() }
                        .buttonStyle(.tourPrimary)
                        .keyboardShortcut(.defaultAction)
                } else {
                    // Never parked here (no network, no disk): the model
                    // finishes in the background, the first recording waits.
                    Button(OnboardingCopy.text(.skipStep)) { tour.next() }
                        .buttonStyle(.tourGhost)
                }
            }
            .padding(.top, 6)
        }
    }

    private var preparation: ModelPreparation { tour.preparation }

    private var fraction: Double {
        if tour.modelsReady { return 1 }
        if case .downloading(let progress) = whisper.state { return progress }
        return 0
    }

    /// The prototype's `.dl` row: name, size, a bar.
    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(OnboardingCopy.text(.modelsStandard))
                    .font(.callout)
                Spacer(minLength: 8)
                Group {
                    if case .downloading(let progress) = whisper.state, !tour.modelsReady {
                        Text("\(Int(progress * Double(whisper.activeModelSizeMB))) / \(whisper.activeModelSizeMB) MB")
                    } else if tour.modelsReady {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.daisySuccess)
                    } else {
                        Text(verbatim: "\(whisper.activeModelSizeMB) MB")
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Color.daisyTextSecondary)
            }
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(Color.daisyAccent)
            if preparation.isRunning, !whisper.isDownloading {
                Text(preparation.stage)
                    .font(.caption)
                    .foregroundStyle(Color.daisyTextSecondary)
            }
            if let error = preparation.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.daisyWarningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button("Download and check") { tour.retryPreparation() }
                    .controlSize(.small)
                    .disabled(preparation.isRunning)
            } else if let notice = preparation.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(Color.daisyTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: 460)
        .background(Color.daisyBgSidebar, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.daisyDivider, lineWidth: 1))
    }
}

private extension WhisperEngine {
    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }
}

// MARK: - 9 Done

private struct DoneScene: View {
    @Bindable private var tour = OnboardingTourController.shared

    var body: some View {
        SceneColumn {
            TourBloom(size: 84)
                .padding(.bottom, 6)
            TourHeading(text: OnboardingCopy.text(.doneTitle))
            TourLine(text: OnboardingCopy.doneLine(tour.daisyKey))
            HStack(spacing: 10) {
                Button(OnboardingCopy.text(.doneOpen)) { tour.finish() }
                    .buttonStyle(.tourPrimary)
                    .keyboardShortcut(.defaultAction)
                Button(OnboardingCopy.text(.again)) { tour.restart() }
                    .buttonStyle(.tourGhost)
            }
            .padding(.top, 8)
        }
    }
}

// MARK: - The flight to the widget

/// Step 3: the flower leaves the window and lands where the widget lives
/// (the prototype's `.widget.fly`, 0.9 s). Plain AppKit in a borderless
/// panel, like the bubble — SwiftUI content there never painted on
/// macOS 27 beta (see `TourBubble`). Under Reduce Motion it doesn't fly.
@MainActor
enum TourFlight {
    static let duration: TimeInterval = 0.9

    static func fly(from start: NSRect, to widgetFrame: NSRect, completion: @escaping @MainActor () -> Void) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            completion()
            return
        }
        // The widget panel keeps ~9 pt of shadow room around its disc.
        let target = widgetFrame.insetBy(dx: 9, dy: 9)
        let panel = NSPanel(contentRect: start, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = TourFlightView(frame: NSRect(origin: .zero, size: start.size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        } completionHandler: {
            MainActor.assumeIsolated {
                completion()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    panel.animator().alphaValue = 0
                } completionHandler: {
                    MainActor.assumeIsolated { panel.orderOut(nil) }
                }
            }
        }
    }
}

/// The widget's look in miniature: the dark disc and the white mark.
private final class TourFlightView: NSView {
    private let disc = CALayer()
    private let mark = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        disc.backgroundColor = NSColor(red: 28 / 255, green: 26 / 255, blue: 23 / 255, alpha: 1).cgColor
        layer?.addSublayer(disc)
        let image = NSImage(named: "DaisyMark") ?? NSImage()
        image.isTemplate = true
        mark.image = image
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.contentTintColor = .white
        addSubview(mark)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.frame = bounds
        disc.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
        mark.frame = bounds.insetBy(dx: bounds.width * 0.2, dy: bounds.height * 0.2)
    }
}
