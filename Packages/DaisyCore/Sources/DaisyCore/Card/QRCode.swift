//
//  QRCode.swift
//  DaisyCore
//
//  backlog 11 K-2: the code itself, from CoreImage — nothing is
//  pulled in for this.
//
//  Error correction **M, not H**: H spends a quarter of the code's
//  capacity on redundancy a phone screen does not need (this is not a
//  sticker on a crate), and the bigger, denser code that results is
//  harder to scan, not easier. M is the level Apple's own Wallet codes
//  use.
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public nonisolated enum QRCode {
    /// A crisp, square code at `size` points × `scale` (3 by default —
    /// every current iPhone).
    /// Nil only if CoreImage refuses the payload (too long for any
    /// version) — the caller shows the byte count and says so.
    public static func cgImage(from text: String, size: CGFloat, scale: CGFloat = 3) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Scale by an INTEGER factor: a fractional one blurs module
        // edges, and a blurry code is a code that does not scan.
        let target = size * scale
        let factor = max(1, floor(target / output.extent.width))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let context = CIContext()
        return context.createCGImage(scaled, from: scaled.extent)
    }
}
