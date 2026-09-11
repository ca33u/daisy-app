//
//  HoverHighlight.swift
//  Daisy
//
//  Pointer feedback for hand-drawn controls.
//
//  AppKit gives hover states to system controls for free. Daisy draws a
//  lot of its own — sidebar rows outside `List(selection:)`, capsule
//  buttons, filter chips, card headers — and every one of those was
//  inert under the cursor: nothing said "this is clickable" until you
//  clicked it (Egor, 2026-09-10). This is the one place that decides
//  what a hover looks like, so the whole app agrees.
//
//  Deliberately subtle: 5% ink, the same weight the Library's session
//  rows already used. Anything stronger reads as a selection and
//  competes with the real one.
//

import SwiftUI

struct DaisyHoverHighlight<S: Shape>: ViewModifier {
    let shape: S
    let strength: Double
    /// Hover is pointless on a control that can't be clicked, and a
    /// highlight under an already-selected row just muddies it.
    let isEnabled: Bool
    /// Paint UNDER the content instead of over it. Right for anything
    /// whose ink carries meaning — the orange update row, the
    /// destructive Stop capsule — because 5% of `Color.primary` over a
    /// coloured label washes that colour out. Only controls with an
    /// opaque fill of their own need the overlay.
    let overContent: Bool

    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(overContent ? nil : tint)
            .overlay(overContent ? tint : nil)
            .onHover { hovering = $0 }
            // A chip that disappears under a stationary cursor (the kind
            // chips hide themselves when empty) or a row recycled by a
            // scroll never gets the exit event, and would otherwise stay
            // lit while the pointer is somewhere else.
            .onDisappear { hovering = false }
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    /// `allowsHitTesting(false)` keeps the control's own clicks and
    /// cursor untouched whichever layer this lands in.
    private var tint: some View {
        shape
            .fill(Color.primary.opacity(hovering && isEnabled ? strength : 0))
            .allowsHitTesting(false)
    }
}

extension View {
    /// Standard hover fill for a hand-drawn control.
    ///
    /// - Parameters:
    ///   - shape: matches the control's own corner radius; pass the same
    ///     `Capsule()` / `RoundedRectangle` the control fills.
    ///   - strength: ink opacity at rest. The default suits a row or a
    ///     chip; a collapsed card header asks for a bit more, since
    ///     inviting the click is the whole point there.
    ///   - isEnabled: pass `false` for a selected or disabled control.
    func daisyHover<S: Shape>(
        _ shape: S,
        strength: Double = 0.05,
        isEnabled: Bool = true,
        overContent: Bool = true
    ) -> some View {
        modifier(DaisyHoverHighlight(
            shape: shape,
            strength: strength,
            isEnabled: isEnabled,
            overContent: overContent
        ))
    }

    /// Hover fill for the app's usual 8-point row corner.
    func daisyHover(
        strength: Double = 0.05,
        isEnabled: Bool = true,
        overContent: Bool = true
    ) -> some View {
        daisyHover(
            RoundedRectangle(cornerRadius: 8, style: .continuous),
            strength: strength,
            isEnabled: isEnabled,
            overContent: overContent
        )
    }

    /// Hover fill for a row of text that carries no padding of its own —
    /// a tappable line inside a card, say. The tint bleeds `inset`
    /// points past the text on every side so it reads as a hovered row
    /// rather than a box shrink-wrapped around the words.
    func daisyHoverRow(
        cornerRadius: CGFloat = 6,
        inset: CGFloat = 6,
        strength: Double = 0.05,
        isEnabled: Bool = true
    ) -> some View {
        daisyHover(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .inset(by: -inset),
            strength: strength,
            isEnabled: isEnabled,
            // A bare row of text has nothing opaque to hide a backdrop,
            // and painting under the words leaves their colour alone.
            overContent: false
        )
    }
}
