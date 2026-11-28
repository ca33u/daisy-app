// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  GlassSegmentedControl.swift
//  Daisy
//
//  A shared, text-only segmented control that reads as the native
//  macOS 26 toolbar tab strip (Safari / Finder / Xcode style) but that
//  WE lay out — so we control the minimum side padding inside each
//  segment cell, which the system `TabView`+`.tabItem` chrome locks.
//
//  ── Why this exists ────────────────────────────────────────────────
//  The owner wants three things at once for the Vocabulary/History,
//  Auto-routing/MCP, and 5 Settings tab strips:
//    1. real Liquid Glass pills,
//    2. text-only (no SF Symbol icons),
//    3. sitting at the window-toolbar level.
//  Native `TabView`+`.tabItem` gives 1+2+3 but its per-cell padding is
//  system-locked. A plain custom control got the padding but was not
//  glass and not toolbar-level.
//
//  ── Why NSGlassEffectView, not SwiftUI `.glassEffect()` ────────────
//  This app disabled SwiftUI's `glassEffect(_:in:)` app-wide (see the
//  `daisyGlass` no-op in View+Compat.swift): on macOS 26.2 that modifier
//  is backed by DesignLibrary and dereferences freed class metadata
//  during SwiftUI's layout pass (EXC_BREAKPOINT, the swift-concurrency↔
//  AppKit UAF family) when the window restructures on record-start. We
//  deliberately do NOT re-enable that path.
//
//  Instead we get REAL Liquid Glass from AppKit's `NSGlassEffectView`
//  (macOS 26), bridged via `NSViewRepresentable`. That's a plain
//  `@MainActor NSView` subclass — NOT the SwiftUI DesignLibrary
//  layout path — so it sidesteps the exact crash the app hit. (An
//  Apple engineer and multiple shipping apps confirm `NSGlassEffectView`
//  works even where the SwiftUI symbol crashes.) Below macOS 26 there is
//  no Liquid Glass, so we fall back to a `.regularMaterial` capsule — the
//  same safe degradation the rest of the app already uses.
//
//  The glass is used only as a BACKDROP (`.background`) behind the
//  SwiftUI segment buttons; the buttons own layout + hit-testing, so we
//  never host SwiftUI inside the glass view's `contentView`.
//

import AppKit
import SwiftUI

/// A text-only, Liquid-Glass segmented control. Generic over the
/// selection value so it can drive any `@State` tab enum
/// (`DictationView.Tab`, `ConnectionSection`, `SettingsTab`).
///
/// Placed in each view's `.toolbar` via `ToolbarItem(placement: .principal)`
/// so it renders centered in the window toolbar — genuine toolbar level,
/// matching the native macOS 26 tab strip position.
struct GlassSegmentedControl<Value: Hashable>: View {
    /// One cell: the value it selects and the (already-localized) label
    /// it shows. Text only — no `systemImage`, by design.
    struct Segment: Identifiable {
        let value: Value
        let title: String
        var id: Value { value }
    }

    @Binding var selection: Value
    let segments: [Segment]

    /// The tunable MINIMUM horizontal breathing room inside each cell —
    /// the whole point of rolling our own control. ~14pt gives the text
    /// room from the pill edges that `.tabItem` refuses to.
    var segmentHPadding: CGFloat = 14
    /// Vertical room inside each cell.
    var segmentVPadding: CGFloat = 6
    /// Inset of the pills from the glass track edge.
    var trackInset: CGFloat = 3

    /// Namespace for the moving selection pill.
    @Namespace private var pillNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                segmentButton(segment)
            }
        }
        .padding(trackInset)
        .background(glassTrack)
        // Scope animation to THIS control: the selection pill glides
        // between cells, without dragging the (sibling) tab-content swap
        // into the transaction.
        .animation(.easeInOut(duration: 0.18), value: selection)
        // Hug content so it reads as a compact pill in the toolbar's
        // centered slot rather than stretching across it.
        .fixedSize()
    }

    private func segmentButton(_ segment: Segment) -> some View {
        let isSelected = segment.value == selection
        return Button {
            selection = segment.value
        } label: {
            Text(segment.title)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                // Neutral ink on both states (selected = dark on the grey
                // selection pill, NOT white-on-accent). Weight carries the
                // selected emphasis.
                .foregroundStyle(Color.daisyTextPrimary)
                // The load-bearing padding: minimum side room per cell.
                .padding(.horizontal, segmentHPadding)
                .padding(.vertical, segmentVPadding)
                // Hit-test the whole pill, not just the glyphs.
                .contentShape(Capsule(style: .continuous))
                .background {
                    if isSelected {
                        // Neutral selection pill (was daisyAccent orange) —
                        // same grey as the Library row / native tab selection.
                        Capsule(style: .continuous)
                            .fill(Color.daisySelectionBackground)
                            .matchedGeometryEffect(id: "selectionPill", in: pillNamespace)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var glassTrack: some View {
        if #available(macOS 26.0, *) {
            // Real Liquid Glass via AppKit — NOT SwiftUI `.glassEffect()`.
            LiquidGlassCapsuleBackdrop()
        } else {
            // Pre-Tahoe: closest safe equivalent (no Liquid Glass exists
            // there anyway). Matches the app's other material capsules.
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
                )
        }
    }
}

// MARK: - AppKit Liquid Glass backdrop

/// A capsule-shaped `NSGlassEffectView` bridged into SwiftUI, used purely
/// as a translucent Liquid Glass BACKDROP behind the segment buttons.
///
/// Uses AppKit's glass — deliberately avoiding SwiftUI's disabled
/// `glassEffect()` DesignLibrary path (see file header + View+Compat).
@available(macOS 26.0, *)
private struct LiquidGlassCapsuleBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> CapsuleGlassNSView {
        let view = CapsuleGlassNSView()
        // We want ONLY the glass material as a backdrop; the SwiftUI
        // buttons render on top via `.background`, so there is no
        // `contentView` to embed.
        return view
    }

    func updateNSView(_ nsView: CapsuleGlassNSView, context: Context) {
        // Corner radius is kept in sync with height in `setFrameSize`
        // (below); nothing dynamic to push here.
    }
}

/// `NSGlassEffectView` that keeps itself a perfect capsule by pinning its
/// corner radius to half its height whenever it's resized. Setting the
/// radius in `setFrameSize` (the standard AppKit resize hook) — NOT in a
/// `sizeThatFits` measurement pass, which is the geometry-mutation trap
/// that crashed 1.0.7.27 (b73).
@available(macOS 26.0, *)
private final class CapsuleGlassNSView: NSGlassEffectView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        cornerRadius = newSize.height / 2.0
    }
}
