//
//  RecordCapsule.swift
//  Daisy
//
//  Liquid Glass record-button that lives in the sidebar of MainView.
//  Replaces the giant Start/Stop button that used to dominate
//  HomeView. The capsule shape reads as a system control (similar to
//  Voice Memos / iOS Control Center), and the colour transition from
//  cool accent → system orange does the heavy lifting visually —
//  "you're now recording" without needing a textbook explanation.
//
//  States:
//   • idle / finished / failed → accent-tinted capsule, "Record"
//   • recording                → orange capsule, "Stop · 01:23"
//   • preparing/stopping       → dimmed capsule with hourglass
//   • summarizing              → dimmed capsule with sparkles
//

import SwiftUI

/// Shared pill-button geometry — the record button and onboarding's
/// Back/Continue actions both read as the app's "big action" idiom, so
/// they share one source for padding/font instead of two hand-tuned
/// copies drifting apart. Capsule shape gives the radius for free (a
/// capsule is always fully round) — nothing to name for that part.
enum DaisyCapsuleMetrics {
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 14
    static let font: Font = .callout.weight(.medium)
}

struct RecordCapsule: View {
    @Bindable var session: RecordingSession
    @Bindable var settings: AppSettings

    var body: some View {
        Button(action: handleTap) {
            // 2026-05-25 — HStack spacing 8 → 6 to match the implicit
            // icon-to-text spacing of `Label(systemImage:)` rows in
            // `List(.sidebar)`. Pre-fix the icon-to-text gap inside
            // the capsule was visibly wider than inside the Home /
            // Library / Connections / Settings / About rows above,
            // so even with matching outer width the internal rhythm
            // looked off.
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.callout.weight(.semibold))
                Text(label)
                    .font(DaisyCapsuleMetrics.font)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if session.status == .recording || session.status == .paused {
                    Text(formatTime(session.elapsed))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.white)
                } else if let label = hotkeyLabel {
                    // Idle: show the configured global record hotkey as a
                    // chip (mirrors the popover Record button) so the
                    // shortcut is discoverable in the main window too.
                    Text(label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(foreground.opacity(0.55))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.06)))
                }
            }
            // 2026-05-25 — horizontal padding bumped 8 → 12 per Egor's
            // sidebar pass. Pre-bump the 8pt inset (chosen to
            // compensate the Capsule curve so the icon aligned with
            // the sidebar row chip x-position) made the play/pause
            // glyph sit too close to the left curve and the timer
            // too close to the right curve — text "breathed" less
            // than the equivalent padding in the row chips above.
            // 12pt restores air around both ends; the icon x drifts
            // ~4pt inward of the sidebar row chip but the capsule
            // now reads as a self-contained pill rather than an
            // over-stretched one. Stop & save below got the same
            // bump for matched-pair rhythm.
            .padding(.horizontal, DaisyCapsuleMetrics.horizontalPadding)
            // 2026-05-25 — bumped vertical padding 8 → 14 (+6 each
            // side = +12pt total height) per Egor's eyeball pass on
            // the sidebar. Previously the capsule felt tight against
            // the row labels above it; with the bigger touch target
            // the Record button now reads as the unambiguous primary
            // action of the sidebar, matches the visual weight of
            // the brand mark + Daisy pill above.
            .padding(.vertical, DaisyCapsuleMetrics.verticalPadding)
            .frame(maxWidth: .infinity)
            .foregroundStyle(foreground)
            .background(
                Capsule(style: .continuous)
                    .fill(fill)
                    // Hover sits INSIDE the background, on top of the
                    // capsule's own fill: `fill` is a real colour, and
                    // tinting over the label would wash out the glyph and
                    // the timer instead of lighting the button.
                    //
                    // White ink, not `.primary`: this capsule is dark in
                    // BOTH colour schemes, so in light mode `.primary`
                    // would be 5% black on near-black — invisible — and
                    // while recording it would dim the orange rather than
                    // lift it. Disabled means nothing will happen on
                    // click, so nothing lights.
                    .daisyHover(
                        Capsule(style: .continuous),
                        isEnabled: !isDisabled,
                        ink: .white
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(stroke, lineWidth: 0.5)
            )
            .daisyGlass(in: Capsule(style: .continuous))
            .animation(.easeInOut(duration: 0.18), value: session.status)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .disabled(isDisabled)
        .help(helpText)
    }

    // MARK: - Action

    private func handleTap() {
        // Sidebar capsule mirrors the widget: tap toggles
        // pause/resume during an active session. Stop & save is the
        // dedicated Stop button in the popover / kebab — not here.
        switch session.status {
        case .recording:
            Task { await session.pause() }
        case .paused:
            Task { await session.resume() }
        case .idle, .finished, .failed:
            Task { await session.start() }
        case .preparing, .stopping, .summarizing:
            return
        }
    }

    // MARK: - Style per state

    /// Configured global record hotkey label, or nil if disabled — shown
    /// as a chip on the idle button, mirroring the popover Record button.
    private var hotkeyLabel: String? {
        let choice = settings.recordHotkey
        guard choice.keyCode != nil else { return nil }
        return choice.label
    }

    private var icon: String {
        switch session.status {
        case .recording:                              return "pause.fill"
        case .paused:                                  return "play.fill"
        // Summarizing = sparkles (the AI step), matching the popover
        // record button; preparing/stopping stay the neutral hourglass.
        case .summarizing:                             return "sparkles"
        case .preparing, .stopping:                    return "hourglass"
        default:                                       return "record.circle"
        }
    }

    private var label: String {
        // 2026-05-25 — idle / finished label changed "Start" → "Record"
        // to match the verb used everywhere else in the app (toolbar
        // play button, dock badge title, hotkey hint "⌘⇧R"). "Start"
        // is generic — start what? — and Daisy's three modes (meeting,
        // voice note, dictation) are all variants of "record". The
        // recording-state labels (Pause / Resume / Stop) stay as
        // standard media verbs once a session is in flight.
        switch session.status {
        case .recording:    return String(localized: "Pause")
        case .paused:       return String(localized: "Resume")
        case .preparing:    return String(localized: "Preparing…")
        case .stopping:     return String(localized: "Stopping…")
        case .summarizing:  return String(localized: "Summarizing…")
        case .finished:     return String(localized: "Record")
        case .failed:       return String(localized: "Try again")
        case .idle:         return String(localized: "Record")
        }
    }

    private var fill: Color {
        switch session.status {
        // Colour signals the state the user is currently in. Orange is a
        // literal live-microphone signal; paused stays neutral.
        case .recording:                              return .daisyRecording
        case .paused:                                  return .daisyPaused
        case .preparing, .stopping, .summarizing:     return Color.gray.opacity(0.40)
        case .failed:                                  return .daisyError
        // Idle / finished Start is charcoal; orange begins only when the
        // microphone is actually live.
        default:                                       return .daisyRecordIdle
        }
    }

    /// Every capsule fill state uses white ink, including charcoal idle.
    private var foreground: Color { .white }

    private var stroke: Color {
        Color.white.opacity(0.12)
    }

    private var isDisabled: Bool {
        switch session.status {
        case .preparing, .stopping, .summarizing:     return true
        default:                                       return false
        }
    }

    private var helpText: String {
        switch session.status {
        case .recording:    return String(localized: "Pause (Space)")
        case .paused:       return String(localized: "Resume (Space)")
        case .idle:         return String(localized: "Start a new recording (Space)")
        case .finished:     return String(localized: "Record again (Space)")
        case .failed:       return String(localized: "Try recording again")
        default:            return ""
        }
    }

    private func formatTime(_ s: TimeInterval) -> String {
        let total = Int(s.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}
