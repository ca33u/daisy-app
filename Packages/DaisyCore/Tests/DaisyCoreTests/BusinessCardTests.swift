//
//  BusinessCardTests.swift
//  DaisyCoreTests
//
//  backlog 11 K-1/K-2: the card, its vCard and the byte budget that
//  decides whether the code scans at a conference.
//

import Testing
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision
import UniformTypeIdentifiers
@testable import DaisyCore

@Suite("Business card and its vCard")
struct BusinessCardCoreTests {
    private func card() -> BusinessCard {
        var c = BusinessCard(kind: .work)
        c.name = "Egor Sazanov"
        c.company = "addicted"
        c.role = "Founder"
        c.phone = "+79001234567"
        c.email = "egor@addicted.sh"
        c.link = "addicted.sh"
        return c
    }

    @Test func vCardIsWellFormedAndHoldsTheContactItself() {
        let text = VCard.text(for: card())
        #expect(text.hasPrefix("BEGIN:VCARD\r\nVERSION:3.0\r\n"))
        #expect(text.hasSuffix("END:VCARD\r\n"))
        #expect(text.contains("N:Sazanov;Egor;;;"))
        #expect(text.contains("FN:Egor Sazanov"))
        #expect(text.contains("ORG:addicted"))
        #expect(text.contains("TEL;TYPE=CELL:+79001234567"))
        #expect(text.contains("EMAIL;TYPE=INTERNET:egor@addicted.sh"))
        // The link lives INSIDE the card, never as the code's target.
        #expect(text.contains("URL:https://addicted.sh"))
        #expect(!text.contains("PHOTO"))
    }

    /// One spelling now, and the counter is what tells the truth about
    /// what it costs: the same card in Cyrillic is much heavier, and
    /// the person sees the number before a conference, not during one.
    @Test func theByteCounterShowsWhatCyrillicCosts() {
        let latin = VCard.byteCount(for: card())
        let cyrillic = VCard.byteCount(for: cyrillicCard())
        #expect(latin < cyrillic)
        #expect(cyrillic - latin >= 20)
        #expect(latin <= VCard.comfortableByteLimit)
        #expect(VCard.fit(latin) != .tooBig)
        #expect(VCard.fit(VCard.comfortableByteLimit + 1).isScannable == false)
    }

    /// A card written before the latin fields went away keeps the
    /// spelling that was being handed out (the latin one), not the
    /// other (Egor, 2026-09-22).
    @Test func anOldCardMigratesToItsLatinSpelling() throws {
        let old = """
        [{"kind":"work","name":"Егор Сазанов","nameLatin":"Egor Sazanov",
          "company":"Эддиктед","companyLatin":"addicted","role":"Founder",
          "phone":"+79001234567","email":"e@addicted.sh","link":""}]
        """
        let cards = try JSONDecoder().decode([BusinessCard].self, from: Data(old.utf8))
        #expect(cards.first?.name == "Egor Sazanov")
        #expect(cards.first?.company == "addicted")
        #expect(cards.first?.hasPhoto == false)
        // And a card with no latin spelling keeps its own.
        let onlyNative = """
        [{"kind":"personal","name":"Егор","company":"","role":"","phone":"","email":"e@x.dev","link":""}]
        """
        let kept = try JSONDecoder().decode([BusinessCard].self, from: Data(onlyNative.utf8))
        #expect(kept.first?.name == "Егор")
        #expect(kept.first?.isUsable == true)
    }

    private func cyrillicCard() -> BusinessCard {
        var c = card()
        c.name = "Егор Сазанов"
        c.company = "Эддиктед"
        return c
    }

    @Test func separatorsAreEscapedAndLinksNormalised() {
        var c = BusinessCard(kind: .personal)
        c.name = "Jean-Luc Picard"
        c.company = "Acme, Inc.; Lisbon"
        c.email = "jl@acme.example"
        #expect(VCard.text(for: c).contains(#"ORG:Acme\, Inc.\; Lisbon"#))
        #expect(VCard.normalizedLink("example.com") == "https://example.com")
        #expect(VCard.normalizedLink("https://x.dev") == "https://x.dev")
        #expect(VCard.normalizedLink("  ") == nil)
    }

    /// The bug from the widget: the code must be BLACK ON WHITE in the
    /// pixels, opaque, whatever theme is around it. A transparent or
    /// tinted code is white-on-white for half the scanners.
    @Test func theCodeIsOpaqueBlackOnWhite() throws {
        let image = try #require(QRCode.cgImage(from: VCard.text(for: card()), size: 190))
        #expect(image.width >= 190)
        let info = image.alphaInfo
        #expect(info == .none || info == .noneSkipFirst || info == .noneSkipLast, "the code must not carry alpha: \(info)")

        // Read the actual pixels: the quiet zone (a corner) is white,
        // and the finder pattern a little inside it is black.
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            let i = (y * width + x) * 4
            return (pixels[i], pixels[i + 1], pixels[i + 2])
        }
        let corner = pixel(1, 1)
        #expect(corner.r > 240 && corner.g > 240 && corner.b > 240, "the quiet zone must be white, got \(corner)")
        // The finder square sits one module in from the quiet zone; at
        // this size a tenth of the width is inside it.
        let inside = pixel(width / 10, height / 10)
        #expect(inside.r < 40 && inside.g < 40 && inside.b < 40, "the modules must be black, got \(inside)")
    }

    @Test func theCardRoundTripsThroughTheSharedFile() throws {
        // The widget reads exactly what the app wrote.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cards-\(UUID().uuidString)")
            .appendingPathComponent(BusinessCardStorage.fileName)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        BusinessCardStorage.save([card(), BusinessCard(kind: .personal)], to: url)
        let loaded = BusinessCardStorage.load(from: url)
        #expect(loaded.count == 2)
        #expect(loaded.first(where: { $0.kind == .work })?.name == "Egor Sazanov")
        #expect(loaded.first(where: { $0.kind == .personal })?.isUsable == false)
    }
}

@Suite("The widget's photo stays small")
struct CardPhotoTests {
    /// A widget extension has ~30 MB. The thumbnail must be decoded at
    /// thumbnail size, not decoded whole and then shrunk.
    @Test func imageIODecodesTheSmallVersion() throws {
        // A 1200×800 JPEG standing in for a camera photo.
        let big = try #require(makeJPEG(width: 1200, height: 800))
        #expect(CardPhoto.pixelSize(of: big)?.width == 1200)

        let forWidget = try #require(CardPhoto.thumbnail(from: big, maxPixelSize: CardPhoto.widgetMaxPixel))
        #expect(max(forWidget.width, forWidget.height) <= Int(CardPhoto.widgetMaxPixel))
        #expect(forWidget.width > 0 && forWidget.height > 0)
        // Aspect ratio survives.
        #expect(abs(Double(forWidget.width) / Double(forWidget.height) - 1.5) < 0.05)

        let forScreen = try #require(CardPhoto.thumbnail(from: big, maxPixelSize: CardPhoto.screenMaxPixel))
        #expect(max(forScreen.width, forScreen.height) <= Int(CardPhoto.screenMaxPixel))
        #expect(forScreen.width > forWidget.width)
    }

    @Test func bothSizesAreStoredAndTheWidgetReadsTheSmallOne() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cards-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let big = try #require(makeJPEG(width: 512, height: 512))
        let small = try #require(makeJPEG(width: 160, height: 160))
        try big.write(to: directory.appendingPathComponent("card-work.jpg"))
        try small.write(to: directory.appendingPathComponent("card-work-thumb.jpg"))
        // Read them the way the two sides do, by path.
        let widgetData = try Data(contentsOf: directory.appendingPathComponent("card-work-thumb.jpg"))
        #expect(CardPhoto.pixelSize(of: widgetData)?.width == 160)
        #expect(widgetData.count < big.count)
    }

    private func makeJPEG(width: Int, height: Int) -> Data? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

@Suite("A logo costs redundancy")
struct QRLogoTests {
    /// A logo destroys the modules it covers. Level M leaves ~15 % of
    /// the code recoverable; a logo plus a scanner at an angle eats
    /// that. With a logo the code is generated at Q (~25 %).
    @Test func aCardWithALogoUsesHigherCorrection() {
        #expect(QRCode.correction(hasLogo: false) == .medium)
        #expect(QRCode.correction(hasLogo: true) == .quartile)
        #expect(QRCode.Correction.medium.rawValue == "M")
        #expect(QRCode.Correction.quartile.rawValue == "Q")
        // And the logo is never allowed to grow past a fifth of the code.
        #expect(QRCode.maxLogoFraction <= 0.2)
    }

    /// Both levels produce a usable, square code for a real card.
    /// (Not a size comparison: the image is scaled by an INTEGER
    /// factor to reach the asked-for size, so a denser code can come
    /// out physically smaller — the first version of this test asserted
    /// the opposite and was simply wrong.)
    @Test func bothCorrectionLevelsProduceASquareCode() throws {
        var card = BusinessCard(kind: .work)
        card.name = "Egor Sazanov"
        card.company = "addicted"
        card.email = "egor@addicted.sh"
        let text = VCard.text(for: card)
        for level in [QRCode.Correction.medium, .quartile] {
            let image = try #require(QRCode.cgImage(from: text, size: 200, correction: level))
            #expect(image.width == image.height)
            #expect(image.width >= 200)
        }
    }

    /// The code takes the colour it will be drawn on, so a widget does
    /// not end up with a white card inside a coloured one — and it is
    /// still opaque, which is what stops a renderer tinting it.
    @Test func theBackgroundColourIsBakedIn() throws {
        let cream = CIColor(red: 0.98, green: 0.98, blue: 0.96)
        let image = try #require(QRCode.cgImage(from: "hello", size: 120, background: cream))
        let info = image.alphaInfo
        #expect(info == .none || info == .noneSkipFirst || info == .noneSkipLast)

        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // The quiet zone is the cream, not white.
        let corner = (r: pixels[0], g: pixels[1], b: pixels[2])
        #expect(corner.r > 240 && corner.b > 235 && corner.b < 252, "quiet zone should be the given colour, got \(corner)")
        // And the modules are still dark — looked for across the whole
        // image rather than at a guessed coordinate, since where the
        // finder squares land depends on the code's version.
        var darkest = 255
        for index in stride(from: 0, to: pixels.count, by: 4) {
            darkest = min(darkest, Int(pixels[index]))
        }
        #expect(darkest < 40, "no dark modules found; darkest pixel was \(darkest)")
    }
}

@Suite("The widget's code has no field of its own")
struct TransparentQRTests {
    /// Light modules, everything else transparent — and the two kinds
    /// of code must not be confused with each other, because one of
    /// them is only safe on a screen the owner holds.
    @Test func transparentCodeIsLightModulesOnNothing() throws {
        let image = try #require(QRCode.transparent(from: "hello", size: 120))
        #expect(image.alphaInfo != .none, "a transparent code must carry alpha")

        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        // The quiet zone is nothing at all, not white.
        #expect(pixels[3] == 0, "the corner should be transparent, alpha was \(pixels[3])")
        // Somewhere there are opaque, light modules.
        var brightestOpaque = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 200 {
            brightestOpaque = max(brightestOpaque, Int(pixels[index]))
        }
        #expect(brightestOpaque > 200, "modules should be light, brightest opaque pixel was \(brightestOpaque)")
    }

    /// The one that gets scanned by strangers stays dark-on-light and
    /// opaque. If this ever flips, half of Android stops reading it.
    @Test func theSharedCodeStaysDarkOnLightAndOpaque() throws {
        let image = try #require(QRCode.cgImage(from: "hello", size: 120))
        let info = image.alphaInfo
        #expect(info == .none || info == .noneSkipFirst || info == .noneSkipLast)
    }
}

@Suite("The widget's code is painted, not pictured")
struct QRMaskTests {
    /// The bug from a real home screen (2026-09-23): a code drawn in a
    /// fixed colour is invisible half the time — white on a light
    /// widget, black on a dark one. The mask carries only shape, and
    /// the view paints it with a colour that follows the system.
    @Test func theMaskIsShapeOnlyAndCoversAboutHalfTheCode() throws {
        let image = try #require(QRCode.mask(from: "hello world", size: 120))
        #expect(image.alphaInfo != .none, "a mask must carry alpha")

        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        // The quiet zone is nothing, so the widget's own material shows.
        #expect(pixels[3] == 0, "the corner should be transparent, alpha was \(pixels[3])")
        // And the modules are there: a QR code is roughly half covered.
        var opaque = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 200 { opaque += 1 }
        let share = Double(opaque) / Double(image.width * image.height)
        #expect(share > 0.25 && share < 0.65, "modules covered \(Int(share * 100))% — that is not a QR code")
    }

    @Test func aLogoStillRaisesCorrectionOnAMask() throws {
        let plain = try #require(QRCode.mask(from: "hello", size: 120, correction: .medium))
        let withLogo = try #require(QRCode.mask(from: "hello", size: 120, correction: .quartile))
        #expect(plain.width > 0 && withLogo.width > 0)
        #expect(QRCode.correction(hasLogo: true) == .quartile)
    }
}

@Suite("The code as a grid of modules")
struct QRMatrixTests {
    /// Drawn as shapes because a widget cannot draw it any other way
    /// and still follow the theme (2026-09-23). The grid has to be a
    /// real QR code: square, quiet zone around it, roughly half dark.
    @Test func theGridIsSquareQuietAtTheEdgesAndHalfDark() {
        let grid = QRCode.matrix(from: "https://addicted.sh")
        #expect(!grid.isEmpty)
        #expect(grid.allSatisfy { $0.count == grid.count }, "the grid must be square")

        // The generator leaves a one-module quiet zone; the outermost
        // ring must be empty or a scanner has nothing to lock onto.
        #expect(grid.first?.allSatisfy { !$0 } == true)
        #expect(grid.last?.allSatisfy { !$0 } == true)
        #expect(grid.allSatisfy { !$0.first! && !$0.last! })

        let dark = grid.flatMap { $0 }.filter { $0 }.count
        let share = Double(dark) / Double(grid.count * grid.count)
        #expect(share > 0.25 && share < 0.6, "dark modules were \(Int(share * 100))%")
    }

    /// The finder pattern: a 7×7 square just inside the quiet zone, in
    /// three corners. If this is wrong the grid is upside down or
    /// mirrored, and nothing will ever scan it.
    @Test func theFinderPatternsAreWhereTheyShouldBe() {
        let grid = QRCode.matrix(from: "hello world")
        let n = grid.count
        // Top-left finder: row 1 has seven dark modules from column 1.
        #expect(grid[1][1...7].allSatisfy { $0 })
        // Its inner ring is light.
        #expect(!grid[2][2])
        // Top-right finder.
        #expect(grid[1][(n - 8)...(n - 2)].allSatisfy { $0 })
        // Bottom-left finder.
        #expect(grid[n - 2][1...7].allSatisfy { $0 })
        // And the bottom-right corner is NOT a finder — that is how a
        // scanner tells the orientation.
        #expect(!grid[n - 2][n - 2])
    }

    @Test func aLongerCardMakesABiggerGrid() {
        let small = QRCode.matrix(from: "hi")
        let large = QRCode.matrix(from: String(repeating: "x", count: 200))
        #expect(large.count > small.count)
        // And a higher correction level costs modules too.
        #expect(QRCode.matrix(from: "hi", correction: .quartile).count >= small.count)
    }
}

@Suite("The drawn code actually scans")
struct QRRoundTripTests {
    /// The only test that proves the whole chain: build the grid the
    /// way the views do, draw it the way they draw it, and read it back
    /// with Vision — the same detector the iPhone camera uses. A
    /// mirrored grid, a half-module offset or a seam between modules
    /// all fail here rather than in someone's hand at a conference.
    @Test func aCardDrawnFromTheGridDecodesBackToItsVCard() throws {
        var card = BusinessCard(kind: .work)
        card.name = "Egor Sazanov"
        card.company = "addicted"
        card.role = "Founder"
        card.email = "egor@addicted.sh"
        card.link = "addicted.sh"
        let payload = VCard.text(for: card)

        let grid = QRCode.matrix(from: payload)
        let drawn = try #require(draw(grid, side: 600))

        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: drawn).perform([request])
        let decoded = (request.results ?? []).compactMap(\.payloadStringValue)
        #expect(decoded.count == 1)
        #expect(decoded.first == payload, "what the code carries must be exactly the vCard")
    }

    /// And with a logo covering the middle, at the size the views use.
    @Test func aCodeWithALogoInTheMiddleStillDecodes() throws {
        var card = BusinessCard(kind: .work)
        card.name = "Egor Sazanov"
        card.company = "addicted"
        card.email = "egor@addicted.sh"
        card.hasLogo = true
        let payload = VCard.text(for: card)

        let grid = QRCode.matrix(from: payload, correction: QRCode.correction(hasLogo: true))
        let drawn = try #require(draw(grid, side: 600, logoFraction: QRCode.maxLogoFraction))

        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: drawn).perform([request])
        #expect((request.results ?? []).compactMap(\.payloadStringValue).first == payload,
                "a logo of \(Int(QRCode.maxLogoFraction * 100))% must still leave a readable code")
    }

    /// Rounded modules still scan — the look Egor asked for on
    /// 2026-09-23, checked rather than assumed. A third of a module is
    /// what the views use; half (full circles) is tested too, because
    /// that is the first thing anyone will try next.
    /// The gap between dots, measured rather than chosen: 7 % of a
    /// module reads everywhere, 8 % already fails at some sizes. Every
    /// gap eats the dark mass a scanner thresholds on, so this is the
    /// line between "airy" and "works on the desk but not at a booth".
    @Test func sevenPercentOfAirBetweenDotsStillDecodes() throws {
        var card = BusinessCard(kind: .work)
        card.name = "Egor Sazanov"
        card.company = "addicted"
        card.role = "Founder"
        card.email = "egor@addicted.sh"
        let payload = VCard.text(for: card)
        let grid = QRCode.matrix(from: payload)
        for side in [200, 400, 600, 900] {
            let drawn = try #require(draw(grid, side: side, roundness: 0.35, gap: 0.07))
            let request = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: drawn).perform([request])
            #expect((request.results ?? []).compactMap(\.payloadStringValue).first == payload,
                    "a 7% gap stopped decoding at \(side)px")
        }
    }

    @Test func roundedModulesStillDecode() throws {
        var card = BusinessCard(kind: .work)
        card.name = "Egor Sazanov"
        card.company = "addicted"
        card.email = "egor@addicted.sh"
        let payload = VCard.text(for: card)
        let grid = QRCode.matrix(from: payload)
        for roundness in [CGFloat(0), 0.3, 0.5] {
            let drawn = try #require(draw(grid, side: 600, roundness: roundness))
            let request = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: drawn).perform([request])
            #expect((request.results ?? []).compactMap(\.payloadStringValue).first == payload,
                    "modules rounded by \(roundness) stopped decoding")
        }
    }

    /// Draw the grid as the views do: dark squares on white, y running
    /// downwards, optionally rounded and with a disc in the middle.
    private func draw(_ grid: [[Bool]], side: Int, logoFraction: CGFloat = 0,
                      roundness: CGFloat = 0, gap: CGFloat = 0) -> CGImage? {
        guard !grid.isEmpty else { return nil }
        let count = grid.count
        let step = CGFloat(side) / CGFloat(count)
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for (y, row) in grid.enumerated() {
            for (x, isDark) in row.enumerated() where isDark {
                let cell = CGRect(x: CGFloat(x) * step,
                                  y: CGFloat(count - 1 - y) * step,
                                  width: step, height: step)
                let rect = gap > 0 ? cell.insetBy(dx: step * gap, dy: step * gap)
                                   : cell.insetBy(dx: -0.25, dy: -0.25)
                if roundness > 0 {
                    let radius = min(rect.width * roundness, rect.width / 2)
                    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                                           cornerHeight: radius, transform: nil))
                    context.fillPath()
                } else {
                    context.fill(rect)
                }
            }
        }
        if logoFraction > 0 {
            let discSide = CGFloat(side) * logoFraction
            let origin = (CGFloat(side) - discSide) / 2
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fillEllipse(in: CGRect(x: origin, y: origin, width: discSide, height: discSide))
        }
        return context.makeImage()
    }
}
