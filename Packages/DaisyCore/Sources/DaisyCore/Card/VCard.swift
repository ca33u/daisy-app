//
//  VCard.swift
//  DaisyCore
//
//  backlog 11 K-2: the contact itself, as a vCard 3.0 in UTF-8 — the
//  payload of the QR code and the body of the `.vcf` the Share sheet
//  sends. Version 3.0 on purpose: it is what every phone camera, every
//  scanner app and every desktop mail client reads without argument.
//
//  Three rules the backlog fixes, all about the code staying scannable:
//
//  • **Under 250 bytes.** A denser code needs a steadier hand, better
//    light and a better scanner; ZXing — under half the scanner apps in
//    the world — decodes version-20-and-up codes about one time in
//    twenty. The card reports its size so the person sees it before a
//    conference, not during one.
//  • **Latin where it can be.** UTF-8 Cyrillic is two bytes a letter
//    plus a mode switch, so the same card in latin letters is roughly
//    half the payload. `latin: true` uses the latin spellings.
//  • **Nothing that is not contact data.** No photo, no logo, no
//    social accounts: this is the one screen where prettier means
//    less likely to scan.
//
//  And the rule that protects every card already handed out: if a page
//  on mydaisy.io ever exists, its address goes INSIDE the vCard as a
//  `URL` line — never becomes the code's target. A code that points at
//  a server is dead the day the server is, and needs a network to read;
//  this one is neither.
//

import Foundation

public nonisolated enum VCard {
    /// The byte budget for a comfortably scannable code.
    public static let comfortableByteLimit = 250
    /// Past this the code is dense enough that older scanners start to
    /// struggle; the UI warns rather than refuses.
    public static let warningByteLimit = 200

    /// vCard 3.0 for one card. `latin` picks the spelling of name and
    /// company (K-2: the latin one is what crosses borders).
    public static func text(for card: BusinessCard, latin: Bool) -> String {
        let name = card.displayName(latin: latin)
        let company = card.displayCompany(latin: latin)
        let (given, family) = BusinessCard.splitName(name)
        var lines = ["BEGIN:VCARD", "VERSION:3.0"]
        // N is mandatory in 3.0; FN is what readers show.
        lines.append("N:\(escape(family));\(escape(given));;;")
        if !name.isEmpty { lines.append("FN:\(escape(name))") }
        if !company.isEmpty { lines.append("ORG:\(escape(company))") }
        let role = card.role.trimmingCharacters(in: .whitespacesAndNewlines)
        if !role.isEmpty { lines.append("TITLE:\(escape(role))") }
        let phone = card.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        if !phone.isEmpty { lines.append("TEL;TYPE=CELL:\(escape(phone))") }
        let email = card.email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.isEmpty { lines.append("EMAIL;TYPE=INTERNET:\(escape(email))") }
        if let link = normalizedLink(card.link) { lines.append("URL:\(escape(link))") }
        lines.append("END:VCARD")
        // CRLF: the spec says so, and a few older Android readers insist.
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Bytes on the wire — what the QR encoder actually has to fit.
    public static func byteCount(for card: BusinessCard, latin: Bool) -> Int {
        text(for: card, latin: latin).utf8.count
    }

    public enum Fit {
        case comfortable
        case dense       // scans, but older scanners may struggle
        case tooBig      // over the budget: the person must trim

        public var isScannable: Bool { self != .tooBig }
    }

    public static func fit(_ bytes: Int) -> Fit {
        if bytes > comfortableByteLimit { return .tooBig }
        if bytes > warningByteLimit { return .dense }
        return .comfortable
    }

    /// "example.com" → "https://example.com"; an address the person
    /// already wrote in full is left alone. Nil when there is nothing.
    public static func normalizedLink(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return trimmed }
        if trimmed.hasPrefix("mailto:") || trimmed.hasPrefix("tel:") { return trimmed }
        return "https://" + trimmed
    }

    /// vCard escaping: backslash, comma, semicolon, newline. Commas in
    /// a company name are common enough to matter ("Acme, Inc.").
    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// The file the Share sheet sends: same contact, any device.
    public static func fileURL(for card: BusinessCard, latin: Bool) throws -> URL {
        let name = card.displayName(latin: true).isEmpty ? "contact" : card.displayName(latin: true)
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).vcf")
        try Data(text(for: card, latin: latin).utf8).write(to: url, options: .atomic)
        return url
    }
}
