//
//  DaisyMark.swift
//  Daisy
//
//  Static (non-animated) daisy logomark. Two flavours:
//    • `DaisyMark` — SwiftUI View, used inside the app (settings, etc.)
//    • `DaisyMark.menuBarImage` — pre-rendered template NSImage suitable
//      for `MenuBarExtra(label:)`. Bypasses SwiftUI's templating because
//      arbitrary template-mode renderings in MenuBarExtra labels don't
//      always pick up the correct light/dark tint; an explicit NSImage
//      with `isTemplate = true` always gets the right treatment.
//
//  Rendering source of truth: `Assets.xcassets/DaisyMark.imageset` —
//  one SVG with `preserves-vector-representation` + `template-rendering-
//  intent: template`. That lets `Image("DaisyMark")` and AppKit's
//  `NSImage(named:)` pull the same vector at any size and let the
//  surrounding tint do the colouring.
//

import SwiftUI
import AppKit

struct DaisyMark: View {
    var size: CGFloat = 18
    var tint: Color = .primary

    var body: some View {
        Image("DaisyMark")
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(tint)
            .frame(width: size, height: size)
    }
}

// MARK: - NSImage for the menu bar

@MainActor
extension DaisyMark {
    /// Cached template NSImage at 20×20 pt (18 until 24.09: Egor asked
    /// for a couple of points more; the bar is 22–24 pt tall). `isTemplate = true` tells
    /// AppKit to tint it black on a light menu bar and white on a dark
    /// one. Pulled straight from the Asset Catalog so it tracks any
    /// brand refresh automatically — no rasterised copies to keep in
    /// sync.
    static let menuBarImage: NSImage = {
        let img = NSImage(named: "DaisyMark") ?? NSImage()
        img.isTemplate = true
        img.size = NSSize(width: 20, height: 20)
        return img
    }()
}

#Preview {
    HStack(spacing: 20) {
        DaisyMark(size: 18)
        DaisyMark(size: 36)
        DaisyMark(size: 72, tint: .black)
        DaisyMark(size: 72, tint: .white).background(.black)
    }
    .padding()
}
