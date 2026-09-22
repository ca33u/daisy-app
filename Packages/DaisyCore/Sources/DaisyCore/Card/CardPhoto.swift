//
//  CardPhoto.swift
//  DaisyCore
//
//  backlog 11 K-4, after Egor's review (2026-09-22): a widget extension
//  gets about 30 MB, and going over it does not look like an error to
//  anyone — it looks like an empty widget on someone's home screen.
//
//  A 512-pixel JPEG decoded whole is ~1 MB of pixels, and the widget
//  also holds the QR raster; both together are the only place this
//  extension can hit the ceiling. So the photo is stored TWICE: the
//  screen-sized one for the app, and a small thumbnail the widget
//  reads. And even the thumbnail is decoded through ImageIO with an
//  explicit `kCGImageSourceThumbnailMaxPixelSize`, which decodes the
//  smaller image rather than the full one and then shrinking it.
//

import CoreGraphics
import Foundation
import ImageIO

public nonisolated enum CardPhoto {
    /// What the app's own screen shows (a 64-point circle at 3×, with
    /// room for a bigger layout later).
    public static let screenMaxPixel: CGFloat = 512
    /// What the widget draws: ~34 points at 3× is 102 pixels; 160 keeps
    /// it crisp on every screen and still decodes to ~100 KB of pixels.
    public static let widgetMaxPixel: CGFloat = 160

    /// Decode at most `maxPixelSize` pixels on the long side — ImageIO
    /// decodes the reduced image, so the full-size bitmap never exists.
    public static func thumbnail(from data: Data, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Pixel size of an image file without decoding it — for a test, and
    /// for anything that wants to check before loading.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}
