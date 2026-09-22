//
//  BusinessCardTests.swift
//  DaisyCoreTests
//
//  backlog 11 K-1/K-2: the card, its vCard and the byte budget that
//  decides whether the code scans at a conference.
//

import Testing
import Foundation
@testable import DaisyCore

@Suite("Business card and its vCard")
struct BusinessCardCoreTests {
    private func card() -> BusinessCard {
        var c = BusinessCard(kind: .work)
        c.name = "Егор Сазанов"
        c.nameLatin = "Egor Sazanov"
        c.company = "Эддиктед"
        c.companyLatin = "addicted"
        c.role = "Founder"
        c.phone = "+79001234567"
        c.email = "egor@addicted.sh"
        c.link = "addicted.sh"
        return c
    }

    @Test func vCardIsWellFormedAndHoldsTheContactItself() {
        let text = VCard.text(for: card(), latin: true)
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

    @Test func latinCostsRoughlyHalfOfCyrillicAndFitsTheBudget() {
        let latin = VCard.byteCount(for: card(), latin: true)
        let native = VCard.byteCount(for: card(), latin: false)
        #expect(latin < native)
        #expect(native - latin >= 20)
        #expect(latin <= VCard.comfortableByteLimit)
        #expect(VCard.fit(latin) != .tooBig)
        #expect(VCard.fit(VCard.comfortableByteLimit + 1).isScannable == false)
    }

    @Test func separatorsAreEscapedAndLinksNormalised() {
        var c = BusinessCard(kind: .personal)
        c.nameLatin = "Jean-Luc Picard"
        c.companyLatin = "Acme, Inc.; Lisbon"
        c.email = "jl@acme.example"
        #expect(VCard.text(for: c, latin: true).contains(#"ORG:Acme\, Inc.\; Lisbon"#))
        #expect(VCard.normalizedLink("example.com") == "https://example.com")
        #expect(VCard.normalizedLink("https://x.dev") == "https://x.dev")
        #expect(VCard.normalizedLink("  ") == nil)
    }

    @Test func aScannableCodeComesOutOfIt() {
        let image = QRCode.cgImage(from: VCard.text(for: card(), latin: true), size: 190)
        #expect(image != nil)
        #expect((image?.width ?? 0) >= 190)
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
        #expect(loaded.first(where: { $0.kind == .work })?.nameLatin == "Egor Sazanov")
        #expect(loaded.first(where: { $0.kind == .personal })?.isUsable == false)
    }
}
