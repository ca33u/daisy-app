//
//  BusinessCardTests.swift
//  DaisyCoreTests
//
//  backlog 11 K-1/K-2: the card, its vCard and the byte budget that
//  decides whether the code scans at a conference.
//

import Testing
import CoreGraphics
import Foundation
import ImageIO
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
