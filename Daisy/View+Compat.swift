// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  View+Compat.swift
//  Daisy
//
//  macOS-version compatibility shims for SwiftUI modifiers that are
//  only available on macOS 26 (Tahoe) but for which we want a clean
//  fallback on macOS 14/15. Lets us target macOS 14+ for the floor
//  install base while still lighting up Liquid Glass on Tahoe.
//
//  Pattern: each shim wraps `#available(macOS 26.0, *)`. The fallback
//  is intentionally a no-op or the closest pre-26 equivalent — the
//  underlying view continues to look correct because we already paint
//  a background + overlay stroke at the call site (so the Liquid Glass
//  material was layered ON TOP, not the only paint).
//

import SwiftUI

extension View {
    /// Apply Liquid Glass material in the given shape on macOS 26+,
    /// otherwise no-op. Call sites already paint a `.background(...)`
    /// + `.overlay(...strokeBorder...)` directly under this modifier,
    /// so the non-Tahoe rendering keeps its capsule fill and hairline
    /// — it just loses the Liquid Glass sheen. Acceptable degradation
    /// for the ~90% of Macs still on Sonoma/Sequoia.
    @ViewBuilder
    func daisyGlass<S: Shape>(in shape: S) -> some View {
        // 2026-05-27 — DISABLED on every macOS version. `glassEffect(in:)`
        // is backed by DesignLibrary, and on macOS 26.2 (25C56) its body
        // runs `swift_task_isCurrentExecutor` → `swift_getObjectType`
        // during SwiftUI's layout pass and dereferences freed class
        // metadata → EXC_BREAKPOINT (pointer-authentication trap DA).
        // Reproduces 100% on Record: when `session.status` flips to
        // `.recording`, the sidebar List in MainView restructures (Stop
        // button + status pill appear) and `DynamicContainerInfo`
        // re-evaluates the `RecordCapsule` glass row mid-layout, firing
        // the buggy path. Same Swift concurrency↔AppKit UAF family as the
        // NSSegmentedCell sidebar-toggle crash fixed in c612635, and as
        // the documented 26.0.1 SwiftUI Button crash — so we disable
        // across ALL of 26.x, not just 26.2. Not materializing the
        // glassEffect means the buggy DesignLibrary code can't run.
        //
        // No-op is a safe degradation: every call site paints its own
        // Capsule fill + hairline stroke directly under this modifier
        // (RecordCapsule, ContentView record button), so we lose only the
        // Liquid Glass sheen — the control's shape and legibility are
        // unchanged, identical to the macOS 14/15 render path. Re-enable
        // by restoring `if #available(macOS 26.0, *) { self.glassEffect(in: shape) }`
        // once Apple ships a 26.x with the DesignLibrary UAF fixed.
        self
    }

    /// Hide the window toolbar's frosted background. On macOS 26 this
    /// is `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`
    /// — added alongside Liquid Glass to suppress the material strip.
    /// On macOS 14/15 the older `.toolbarBackground(.hidden, for: ...)`
    /// does the equivalent job (suppresses the toolbar bg paint so
    /// the window's `containerBackground` shows through unobstructed).
    @ViewBuilder
    func daisyWindowToolbarHidden() -> some View {
        if #available(macOS 26.0, *) {
            self.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self.toolbarBackground(.hidden, for: .windowToolbar)
        }
    }

    /// Tint the window's content background. The SwiftUI
    /// `.containerBackground(_:for: .window)` modifier was added in
    /// macOS 15 — even though the broader `containerBackground` API
    /// shipped in macOS 14, the `.window` placement specifically
    /// came in Sequoia. On macOS 14 we fall back to the AppKit-level
    /// `NSWindow.backgroundColor` set in `DaisyAppDelegate` (warm
    /// cream), which produces a visually identical result.
    @ViewBuilder
    func daisyWindowBackground(_ color: Color) -> some View {
        if #available(macOS 15.0, *) {
            self.containerBackground(color, for: .window)
        } else {
            self
        }
    }
}
