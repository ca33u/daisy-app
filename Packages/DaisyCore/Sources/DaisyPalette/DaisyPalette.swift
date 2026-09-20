//
//  DaisyPalette.swift
//  DaisyPalette
//
//  The ONE list of Daisy's colours, as data — light + dark sRGB hex per
//  semantic token, nothing else. Moved from daisy-app/Daisy/DaisyColors
//  .swift @ 1.0.7.72 on 2026-09-19 (backlog 5 E-1) value for value; the
//  rationale comments travelled with each token. No SwiftUI, UIKit or
//  AppKit here: `DaisyDesign` turns these into `Color` per platform.
//
//  The rule the palette exists to protect: amber means "a microphone is
//  live". Buttons, backgrounds and statuses are ink and gray.
//

public nonisolated struct DaisyColorPair: Sendable, Equatable {
    public let light: UInt32
    public let dark: UInt32
    public init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }
}

public nonisolated enum DaisyPalette {

    // ─── Recording / mic-active ───────────────────────────────────────
    //
    // Amber recording signal. This is the sole vivid, always-live colour.

    /// Primary "recording in progress". Centre of the petal widget, Stop
    /// button background, the recording status dot.
    public static let recording = DaisyColorPair(light: 0xF47B20, dark: 0xFF9147)

    /// Softer orange used for halos / glows around the recording centre.
    public static let recordingPulse = DaisyColorPair(light: 0xF8B36F, dark: 0xFFD3A7)

    // ─── Update-available affordance ──────────────────────────────────
    //
    // Orange for the sidebar "Обновиться" row. Sits on the same warm axis
    // as the recording amber; nudged slightly redder to separate them.
    public static let updateAccent = DaisyColorPair(light: 0xE8620E, dark: 0xFF8A3D)

    // ─── Dictation mode (lilac) ───────────────────────────────────────
    //
    // Vivid lilac, same volume / saturation as the recording orange —
    // dictation IS live capture, its indicator must read as "ON".
    public static let dictation = DaisyColorPair(light: 0xB7A2FF, dark: 0xC9B9FF)
    public static let dictationPulse = DaisyColorPair(light: 0xD7CEFA, dark: 0xE4DDFF)

    // ─── Voice-note mode (coral) ──────────────────────────────────────
    //
    // Pink-coral, pushed off the orange axis (hue ≈351°) so meetings vs
    // voice notes read as two different dots at a glance.
    public static let voiceNote = DaisyColorPair(light: 0xD8755C, dark: 0xEC9A84)
    public static let voiceNotePulse = DaisyColorPair(light: 0xE8A493, dark: 0xF5C0B3)

    /// Paused. Cool slate gray — "held / not live" without any of the
    /// warm recording-family hues.
    public static let paused = DaisyColorPair(light: 0x9AA0A6, dark: 0x7D828B)

    // ─── Brand / surfaces ─────────────────────────────────────────────

    /// Main app background. Airy warm white in light; espresso in dark.
    public static let bgPrimary = DaisyColorPair(light: 0xFFFEFC, dark: 0x0D100E)
    /// Sidebar, cards and widgets — one shared surface.
    public static let bgSidebar = DaisyColorPair(light: 0xFBF9F5, dark: 0x151816)
    /// Elevated surfaces — cards, popovers. Matches the sidebar in light.
    public static let bgElevated = DaisyColorPair(light: 0xFBF9F5, dark: 0x151816)
    /// Subtle dividers between sections.
    public static let divider = DaisyColorPair(light: 0xECE7DE, dark: 0x303531)
    /// Sidebar icons and labels — warm charcoal / paper.
    public static let sidebarInk = DaisyColorPair(light: 0x282824, dark: 0xF4F5EF)
    public static let sidebarSelection = DaisyColorPair(light: 0xF0F1F0, dark: 0x242825)

    // ─── Informational banners ──────────────────────────────────────
    //
    // Quiet containers, not status fills; the CTA uses high-contrast ink.
    public static let bannerBackground = DaisyColorPair(light: 0xF5F5F3, dark: 0x191C1A)
    public static let bannerBorder = DaisyColorPair(light: 0xDDDDD8, dark: 0x343836)
    public static let bannerAction = DaisyColorPair(light: 0x242522, dark: 0xF4F5EF)
    public static let bannerActionText = DaisyColorPair(light: 0xFFFEFC, dark: 0x0D100E)

    // ─── Controls ────────────────────────────────────────────────────
    //
    // Buttons are black and gray (Egor, 2026-09-19): prominent actions
    // take the banner CTA's ink pair — aliases, not new hexes.

    /// Fill of a primary (solid) control.
    public static var controlFill: DaisyColorPair { bannerAction }
    /// Ink for text and glyphs sitting ON `controlFill`.
    public static var controlLabel: DaisyColorPair { bannerActionText }

    // ─── Content selection ──────────────────────────────────────────
    //
    // Selected rows and filter chips stay neutral.
    public static let selectionBackground = DaisyColorPair(light: 0xECEDEA, dark: 0x242825)
    public static let selectionBorder = DaisyColorPair(light: 0xD6D8D4, dark: 0x3A3F3B)

    // ─── Petal mark ───────────────────────────────────────────────────
    //
    // The flower in idle / finished state: golden-orange, calmer than
    // the vivid capture signal.

    /// Centre disc of the petal mark when idle / finished.
    public static let centerIdle = DaisyColorPair(light: 0xF5A14B, dark: 0xF5A14B)
    /// Warm, non-live accent for Home widgets and compact indicators.
    public static var homeAccent: DaisyColorPair { centerIdle }
    /// Petal fill — ink that matches the text on each appearance.
    public static let petal = DaisyColorPair(light: 0x282824, dark: 0xF4F5EF)

    // ─── Text ─────────────────────────────────────────────────────────

    public static let textPrimary = DaisyColorPair(light: 0x282824, dark: 0xF4F5EF)
    public static let textSecondary = DaisyColorPair(light: 0x62625D, dark: 0xBEC7BE)
    public static let textTertiary = DaisyColorPair(light: 0x85857F, dark: 0x8F988E)

    // ─── Status semantics ─────────────────────────────────────────────

    /// Success / finished / transcript ready. Sage — calm, not alarming.
    public static let success = DaisyColorPair(light: 0x3D7458, dark: 0x93C9A5)
    /// Warning / summarizing / pending. Warm gold — explicitly NOT orange.
    public static let warning = DaisyColorPair(light: 0xF5A14B, dark: 0xFFBF73)
    /// Error. Red shifted toward magenta so it can't pass for recording orange.
    public static let error = DaisyColorPair(light: 0xCF684E, dark: 0xE98A73)
    /// Filled destructive controls — darker than `error` for white labels.
    public static let destructiveControl = DaisyColorPair(light: 0xA9362B, dark: 0xB63D31)

    /// Brand accent / primary CTA when NOT in recording state.
    public static let accent = DaisyColorPair(light: 0xD97A28, dark: 0xF5A14B)
    /// Soft amber for selected backgrounds, focus halos, and controls.
    public static let accentSoft = DaisyColorPair(light: 0xF8E5D2, dark: 0x3A2A1E)
    /// Ink ON an accent-filled surface — warm near-black, clears 4.5:1
    /// on both accents and on the recording orange (white does not).
    public static let textOnAccent = DaisyColorPair(light: 0x2B1A07, dark: 0x2B1A07)

    // ─── Record button (idle / finished) ─────────────────────────────
    //
    // The "Start a recording" capsule fill when nothing is live: a warm
    // charcoal. Solid orange is reserved for a live microphone.
    public static let recordIdle = DaisyColorPair(light: 0x242522, dark: 0x334138)
}

/// Numbers the record capsule and the capsule-shaped buttons share.
/// The font itself is SwiftUI and lives in `DaisyDesign`.
public nonisolated enum DaisyMetrics {
    public static let capsuleHorizontalPadding: Double = 12
    public static let capsuleVerticalPadding: Double = 14
}
