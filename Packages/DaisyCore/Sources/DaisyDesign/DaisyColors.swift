//
//  DaisyColors.swift
//  DaisyDesign
//
//  Semantic colour tokens as SwiftUI `Color`, one per `DaisyPalette`
//  entry, resolved light/dark at render time — via `NSColor(name:)` on
//  the Mac and a dynamic `UIColor` on iOS. This is the only place that
//  knows which platform it is on; everything above it just says
//  `Color.daisyRecording`. Moved from daisy-app/Daisy/DaisyColors.swift
//  @ 1.0.7.72 (backlog 5 E-1) — same names, same values.
//

import DaisyPalette
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Dynamic Color helpers

extension Color {
    /// Resolves to `light` in light mode and `dark` in dark mode at render time.
    public init(light: Color, dark: Color) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
        #else
        self.init(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }

    /// `Color(hex: 0xFF9500)` — RGB hex literal initializer.
    public init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8)  & 0xFF) / 255
        let b = Double(hex         & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    public init(_ pair: DaisyColorPair) {
        self.init(light: Color(hex: pair.light), dark: Color(hex: pair.dark))
    }
}

// MARK: - Daisy palette

extension Color {
    // Recording / mic-active
    public static let daisyRecording = Color(DaisyPalette.recording)
    public static let daisyRecordingPulse = Color(DaisyPalette.recordingPulse)
    public static let daisyUpdateAccent = Color(DaisyPalette.updateAccent)
    public static let daisyDictation = Color(DaisyPalette.dictation)
    public static let daisyDictationPulse = Color(DaisyPalette.dictationPulse)
    public static let daisyVoiceNote = Color(DaisyPalette.voiceNote)
    public static let daisyVoiceNotePulse = Color(DaisyPalette.voiceNotePulse)
    public static let daisyPaused = Color(DaisyPalette.paused)
    /// Colour audit IOS-01: the capsule ships its foreground together
    /// with its fill, never assumes white.
    /// Colour audit MAC-02: a warning you read, not a warning you see.
    public static let daisyWarningText = Color(DaisyPalette.warningText)
    public static let daisyRecordCapsuleText = Color(DaisyPalette.recordCapsuleText)
    public static let daisyRecordCapsuleTextOnDark = Color(DaisyPalette.recordCapsuleTextOnDark)

    // Brand / surfaces
    public static let daisyBgPrimary = Color(DaisyPalette.bgPrimary)
    public static let daisyBgSidebar = Color(DaisyPalette.bgSidebar)
    public static let daisyBgElevated = Color(DaisyPalette.bgElevated)
    public static let daisyDivider = Color(DaisyPalette.divider)
    public static let daisySidebarInk = Color(DaisyPalette.sidebarInk)
    public static let daisySidebarSelection = Color(DaisyPalette.sidebarSelection)

    // Informational banners
    public static let daisyBannerBackground = Color(DaisyPalette.bannerBackground)
    public static let daisyBannerBorder = Color(DaisyPalette.bannerBorder)
    public static let daisyBannerAction = Color(DaisyPalette.bannerAction)
    public static let daisyBannerActionText = Color(DaisyPalette.bannerActionText)

    // Controls — aliases, so the banner CTA and every primary control
    // stay the same button by definition. See DaisyButtonStyles.
    public static var daisyControlFill: Color { daisyBannerAction }
    public static var daisyControlLabel: Color { daisyBannerActionText }

    // Content selection
    public static let daisySelectionBackground = Color(DaisyPalette.selectionBackground)
    public static let daisySelectionBorder = Color(DaisyPalette.selectionBorder)

    // Petal mark
    public static let daisyCenterIdle = Color(DaisyPalette.centerIdle)
    public static let daisyHomeAccent = Color(DaisyPalette.homeAccent)
    public static let daisyPetal = Color(DaisyPalette.petal)

    // Petal mark on a dark surface: state colours
    public static let daisyMarkReady = Color(DaisyPalette.markReady)
    public static let daisyMarkMeeting = Color(DaisyPalette.markMeeting)
    public static let daisyMarkDictation = Color(DaisyPalette.markDictation)
    public static let daisyMarkVoiceNote = Color(DaisyPalette.markVoiceNote)
    public static var daisyMarkPaused: Color { daisyMarkMeeting }
    public static let daisyMarkError = Color(DaisyPalette.markError)
    public static let daisyMarkPetal = Color(DaisyPalette.markPetal)
    public static let daisyMarkPausedPetal = Color(DaisyPalette.markPausedPetal)

    // Text
    public static let daisyTextPrimary = Color(DaisyPalette.textPrimary)
    public static let daisyTextSecondary = Color(DaisyPalette.textSecondary)
    public static let daisyTextTertiary = Color(DaisyPalette.textTertiary)

    // Status semantics
    public static let daisySuccess = Color(DaisyPalette.success)
    public static let daisyWarning = Color(DaisyPalette.warning)
    /// Behind highlighted words in a transcript (§3.3 `==like this==`).
    public static let daisyHighlight = Color(DaisyPalette.highlight)
    public static let daisyError = Color(DaisyPalette.error)
    public static let daisyDestructiveControl = Color(DaisyPalette.destructiveControl)
    public static let daisyAccent = Color(DaisyPalette.accent)
    public static let daisyAccentSoft = Color(DaisyPalette.accentSoft)
    public static let daisyTextOnAccent = Color(DaisyPalette.textOnAccent)

    // Record button (idle / finished)
    public static let daisyRecordIdle = Color(DaisyPalette.recordIdle)
}

/// The record capsule's geometry, shared with the capsule-shaped
/// buttons (`DaisyButtonShape.capsule`) so "Continue" carries the same
/// visual weight as "Record".
public enum DaisyCapsuleMetrics {
    public static let horizontalPadding: CGFloat = CGFloat(DaisyMetrics.capsuleHorizontalPadding)
    public static let verticalPadding: CGFloat = CGFloat(DaisyMetrics.capsuleVerticalPadding)
    public static let font: Font = .callout.weight(.medium)
}
