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
    /// How much of the code can be lost and still read.
    public enum Correction: String, Sendable {
        /// ~15 % — the level Apple's own Wallet codes use, and the
        /// right one for a code on a screen with nothing on top of it.
        case medium = "M"
        /// ~25 % — for a code with a logo in the middle. The logo
        /// destroys the modules it covers, and without the extra
        /// redundancy a scanner that is slightly off-angle fails.
        case quartile = "Q"
    }

    /// The share of the code's width a logo may cover. Past roughly a
    /// fifth even level Q starts to fail, and a business card whose
    /// code does not scan is a blank piece of paper.
    public static let maxLogoFraction: CGFloat = 0.2

    /// The correction a card needs: higher when something sits on top
    /// of the code.
    public static func correction(hasLogo: Bool) -> Correction {
        hasLogo ? .quartile : .medium
    }

    /// A crisp, square, opaque code at `size` points × `scale` (3 by
    /// default — every current iPhone). Dark modules on a light
    /// background, always, in every appearance.
    ///
    /// `background` is baked into the pixels: the widget passes the
    /// colour it draws on, so the code sits on the card rather than in
    /// a white box on it — while staying opaque, which is what keeps
    /// any renderer from tinting the modules.
    /// The code as a grid of modules: `true` is a dark module. Rows top
    /// to bottom, columns left to right, including the quiet zone the
    /// generator leaves (one module wide).
    ///
    /// This exists because **a widget cannot draw an image of a code
    /// that follows the theme**. WidgetKit renders in its own process
    /// with a reduced set of effects: masks, blurs and blend modes do
    /// nothing there, so "paint a mask with the system colour" silently
    /// produced an empty square on a real home screen (2026-09-23), and
    /// a bitmap of a fixed colour is invisible in one appearance or the
    /// other. Shapes drawn from this grid have neither problem: the
    /// colour is the view's, and rectangles are something every
    /// renderer can draw.
    public static func matrix(from text: String, correction: Correction = .medium) -> [[Bool]] {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(text.utf8)
        generator.correctionLevel = correction.rawValue
        guard let generated = generator.outputImage else { return [] }
        let width = Int(generated.extent.width)
        let height = Int(generated.extent.height)
        guard width > 0, height > 0,
              let cg = CIContext().createCGImage(generated, from: generated.extent) else { return [] }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Row 0 of the buffer is the TOP row of the drawn image — the
        // context's y-axis points up, but its memory does not. Reading
        // it the other way round mirrors the code, and a mirrored QR
        // is one no scanner reads (caught by the finder-pattern test,
        // 2026-09-23).
        var rows: [[Bool]] = []
        rows.reserveCapacity(height)
        for y in 0..<height {
            var row: [Bool] = []
            row.reserveCapacity(width)
            for x in 0..<width {
                let index = (y * width + x) * 4
                // Opaque and dark = a module. The generator's field is
                // white; outside the code it is transparent.
                let isDark = pixels[index + 3] > 128 && pixels[index] < 128
                row.append(isDark)
            }
            rows.append(row)
        }
        return rows
    }

    /// The code as a MASK: modules opaque, everything else transparent,
    /// colour irrelevant. The caller paints it with a colour of its own
    /// — which is the only way a code on a widget can be right in both
    /// appearances: white modules vanish on a light widget, black ones
    /// vanish on a dark one, and a fixed colour is wrong half the time.
    /// SwiftUI's `.mask` over `Color.primary` follows the system.
    ///
    /// The scanner trade of an inverted code still applies (see
    /// `transparent` below): fine for the owner's own home screen,
    /// never for the code handed across a table.
    public static func mask(from text: String, size: CGFloat, scale: CGFloat = 3,
                            correction: Correction = .medium) -> CGImage? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(text.utf8)
        generator.correctionLevel = correction.rawValue
        guard let generated = generator.outputImage else { return nil }
        // `CIMaskToAlpha` turns luminance into alpha: the black modules
        // become opaque, the white field becomes nothing. Inverted
        // first, because the filter keeps the BRIGHT parts.
        let alpha = generated
            .applyingFilter("CIColorInvert")
            .applyingFilter("CIMaskToAlpha")
        let target = size * scale
        let factor = max(1, floor(target / alpha.extent.width))
        let scaled = alpha.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    /// A code with NO background at all: the modules are drawn in
    /// `modules` and everything else is transparent, so the code lies
    /// on whatever is behind it (a widget's native material, for
    /// instance).
    ///
    /// **This costs scanners.** A QR code is specified as dark modules
    /// on a light field. iPhone's camera and anything built on Vision
    /// read the inverse happily; ZXing — which is under a large share
    /// of Android scanner apps — does not, and a person holding such a
    /// phone sees nothing at all. So: the widget may use this, because
    /// it is a glance and the owner's own phone; the full-screen code
    /// that gets handed across a table must not (see `CardQRFullScreen`).
    public static func transparent(
        from text: String,
        size: CGFloat,
        scale: CGFloat = 3,
        correction: Correction = .medium,
        modules: CIColor = CIColor(red: 1, green: 1, blue: 1)
    ) -> CGImage? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(text.utf8)
        generator.correctionLevel = correction.rawValue
        guard let generated = generator.outputImage else { return nil }
        let coloured = CIFilter.falseColor()
        coloured.inputImage = generated
        coloured.color0 = modules
        coloured.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)   // nothing
        guard let masked = coloured.outputImage else { return nil }
        let target = size * scale
        let factor = max(1, floor(target / masked.extent.width))
        let scaled = masked.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    public static func cgImage(
        from text: String,
        size: CGFloat,
        scale: CGFloat = 3,
        correction: Correction = .medium,
        background: CIColor = .white,
        modules: CIColor = .black
    ) -> CGImage? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(text.utf8)
        generator.correctionLevel = correction.rawValue
        guard let generated = generator.outputImage else { return nil }

        // Black modules, white background — baked into the pixels, so
        // no renderer downstream can tint them.
        let coloured = CIFilter.falseColor()
        coloured.inputImage = generated
        coloured.color0 = modules
        coloured.color1 = background
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
        context.setFillColor(CGColor(red: background.red, green: background.green, blue: background.blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? rendered
    }
}
