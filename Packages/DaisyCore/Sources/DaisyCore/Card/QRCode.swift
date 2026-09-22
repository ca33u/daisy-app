//
//  QRCode.swift
//  DaisyCore
//
//  backlog 11 K-2: the code itself, from CoreImage — nothing is pulled
//  in for this.
//
//  Error correction **M, not H**: H spends a quarter of the code's
//  capacity on redundancy a phone screen does not need (this is not a
//  sticker on a crate), and the bigger, denser code that results is
//  harder to scan, not easier. M is the level Apple's own Wallet codes
//  use.
//
//  ─── The colours are fixed, and that is not a style choice ───────
//
//  2026-09-22, found on a real phone: the widget drew a white square.
//  `CIQRCodeGenerator` returns the modules as BLACK on a TRANSPARENT
//  background, and anything that renders such an image with a tint —
//  SwiftUI's template rendering, the system's dark mode, iOS 18's
//  tinted home screen — paints the modules in the accent colour over
//  whatever is behind them. White on white scans for nobody.
//
//  So the image is baked here, opaque, with `CIFalseColor`: black
//  modules, white background, no alpha for anyone to tint. A QR code is
//  not a UI element that should follow the theme; it is an optical
//  target, and inverted contrast makes it unreadable for about half of
//  the scanners in the world rather than merely ugly. Callers must also
//  render it as `.original`, never as a template.
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public nonisolated enum QRCode {
    /// A crisp, square, opaque code at `size` points × `scale` (3 by
    /// default — every current iPhone). Black modules on white, always,
    /// in every appearance.
    public static func cgImage(from text: String, size: CGFloat, scale: CGFloat = 3) -> CGImage? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(text.utf8)
        generator.correctionLevel = "M"
        guard let generated = generator.outputImage else { return nil }

        // Black modules, white background — baked into the pixels, so
        // no renderer downstream can tint them.
        let coloured = CIFilter.falseColor()
        coloured.inputImage = generated
        coloured.color0 = CIColor.black   // the modules
        coloured.color1 = CIColor.white   // the background
        guard let opaque = coloured.outputImage else { return nil }

        // Scale by an INTEGER factor: a fractional one blurs module
        // edges, and a blurry code is a code that does not scan.
        let target = size * scale
        let factor = max(1, floor(target / opaque.extent.width))
        let scaled = opaque.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        guard let rendered = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }

        // Redraw into a context with NO alpha channel at all. CoreImage
        // hands back an image that still carries alpha (opaque, but
        // present), and an image with alpha is an image a renderer can
        // treat as a mask and tint — which is exactly the bug this
        // guards against. White background first, so even a stray
        // transparent pixel comes out white rather than black.
        let width = rendered.width, height = rendered.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return rendered }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? rendered
    }
}
