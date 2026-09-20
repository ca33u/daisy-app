//
//  DaisyButtonStyles.swift
//  DaisyDesign — moved from daisy-app/Daisy/DaisyButtonStyles.swift @ 1.0.7.72 (backlog 5 E-1), shared by the Mac and the phone.
//
//  The app's button vocabulary. Four tones, one file — so a button's
//  weight is chosen by naming its role, not by hand-picking a fill at
//  the call site.
//
//  2026-09-19 (Egor): buttons are BLACK AND GRAY. Amber is a signal
//  colour — it means "a microphone is live" — and a Save / Share /
//  Import button is not a live microphone. Before this file, prominent
//  actions were `.borderedProminent` + `.tint(Color.daisyAccent)`, and
//  container-level `.tint(...)` leaked the same amber into every plain
//  and bordered button inside the pane (the Share-analytics sheet had
//  three orange buttons in a row, none of them a signal).
//
//  No new hex values live here. Each tone reuses tokens that were
//  already in `DaisyColors.swift`:
//
//    primary      daisyControlFill / daisyControlLabel  — the
//                 high-contrast ink pair the Home banners already used
//                 for their CTA: near-black on light, paper on dark.
//    secondary    daisySelectionBackground + daisySelectionBorder —
//                 the neutral surface used by selected rows and chips.
//    quiet        no fill; ink text, neutral surface on press.
//    destructive  daisyDestructiveControl — the one place a warm fill
//                 is still correct, because it is a warning.
//
//  `PreparationCapsuleButtonStyle` (MeetingPreparationSheet) had already
//  arrived at this primary/neutral pairing by hand; this generalises it.
//

import DaisyPalette
import SwiftUI

// MARK: - Tone

public enum DaisyButtonTone: Equatable, Sendable {
    /// The one action the sheet or pane exists for. Solid ink.
    case primary
    /// A real alternative to the primary action. Neutral gray surface.
    case secondary
    /// Dismiss, Cancel, "not now". No fill until hovered or pressed.
    case quiet
    /// Deletes something the user cannot get back.
    case destructive
}

public enum DaisyButtonShape: Equatable, Sendable {
    /// Sheet footers, toolbars, settings rows — macOS's own idiom.
    case roundedRect
    /// The app's "big action" pill: Record, onboarding Continue.
    case capsule
}

// MARK: - Style

public struct DaisyButtonStyle: ButtonStyle {
    public var tone: DaisyButtonTone = .primary
    public var shape: DaisyButtonShape = .roundedRect

    public init(tone: DaisyButtonTone = .primary, shape: DaisyButtonShape = .roundedRect) {
        self.tone = tone
        self.shape = shape
    }

    public func makeBody(configuration: Configuration) -> some View {
        // The body is a real View, not the style struct itself: `@State`
        // and `@Environment` are DynamicProperty, and SwiftUI only installs
        // those on views. Declared on the ButtonStyle they compile, then
        // silently never update — hover would stick and `.disabled(...)`
        // would never dim.
        StyledBody(configuration: configuration, tone: tone, shape: shape)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let tone: DaisyButtonTone
        let shape: DaisyButtonShape

        // A custom ButtonStyle gets no `.controlSize` behaviour for free,
        // and several call sites (Connections' "Install", onboarding's
        // "Allow") ask for `.small`. Read it and shrink, or those buttons
        // grow the moment they change style.
        @Environment(\.controlSize) private var controlSize
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(font)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .foregroundStyle(labelColor)
                .background(clipShape.fill(fillColor(pressed: configuration.isPressed)))
                .overlay(border)
                .clipShape(clipShape)
                .contentShape(clipShape)
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }

        // MARK: Geometry

        private var isCompact: Bool {
            switch controlSize {
            case .mini, .small: true
            default:            false
            }
        }

        private var font: Font {
            if shape == .capsule { return DaisyCapsuleMetrics.font }
            return isCompact ? .caption.weight(.medium) : .callout.weight(.medium)
        }

        private var horizontalPadding: CGFloat {
            if shape == .capsule { return DaisyCapsuleMetrics.horizontalPadding }
            return isCompact ? 10 : 14
        }

        private var verticalPadding: CGFloat {
            if shape == .capsule { return DaisyCapsuleMetrics.verticalPadding }
            return isCompact ? 4 : 7
        }

        /// `AnyShape` (macOS 13+) rather than `some Shape`: the two cases are
        /// different concrete types, and `@ViewBuilder` builds views, not shapes.
        private var clipShape: AnyShape {
            switch shape {
            case .capsule:
                AnyShape(Capsule(style: .continuous))
            case .roundedRect:
                AnyShape(RoundedRectangle(cornerRadius: isCompact ? 6 : 7, style: .continuous))
            }
        }

        // MARK: Paint

        private var labelColor: Color {
            switch tone {
            case .primary:      Color.daisyControlLabel
            case .secondary:    Color.daisyTextPrimary
            case .quiet:        Color.daisyTextSecondary
            case .destructive:  Color.white
            }
        }

        /// Filled tones darken under the pointer; the quiet tone has no
        /// fill to darken, so it reaches for the neutral surface instead.
        private func fillColor(pressed: Bool) -> Color {
            switch tone {
            case .primary:
                Color.daisyControlFill.opacity(pressed ? 0.82 : 1)
            case .secondary:
                Color.daisySelectionBackground.opacity(pressed ? 0.82 : 1)
            case .quiet:
                (pressed || isHovering) ? Color.daisySelectionBackground : Color.clear
            case .destructive:
                Color.daisyDestructiveControl.opacity(pressed ? 0.82 : 1)
            }
        }

        @ViewBuilder
        private var border: some View {
            switch tone {
            case .primary, .destructive:
                clipShape.stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            case .secondary:
                clipShape.stroke(Color.daisySelectionBorder, lineWidth: 0.5)
            case .quiet:
                EmptyView()
            }
        }
    }
}

// MARK: - Call-site sugar

public extension ButtonStyle where Self == DaisyButtonStyle {
    /// The one action this sheet or pane exists for. Solid ink.
    static var daisyPrimary: DaisyButtonStyle { DaisyButtonStyle(tone: .primary) }

    /// A real alternative to the primary action. Neutral gray.
    static var daisySecondary: DaisyButtonStyle { DaisyButtonStyle(tone: .secondary) }

    /// Cancel / Close / "not now". Text until hovered.
    static var daisyQuiet: DaisyButtonStyle { DaisyButtonStyle(tone: .quiet) }

    /// Deletes something the user cannot get back.
    static var daisyDestructive: DaisyButtonStyle { DaisyButtonStyle(tone: .destructive) }

    /// Pill geometry for the "big action" idiom (Record, Continue).
    static func daisy(_ tone: DaisyButtonTone, _ shape: DaisyButtonShape = .roundedRect) -> DaisyButtonStyle {
        DaisyButtonStyle(tone: tone, shape: shape)
    }
}
