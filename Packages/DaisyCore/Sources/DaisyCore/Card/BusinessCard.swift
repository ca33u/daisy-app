//
//  BusinessCard.swift
//  DaisyCore
//
//  backlog 11 K-1: the card the person hands out. Six fields, typed
//  once by hand — **Contacts are not read** (that is a permission and
//  a privacy-label line right before submission, for something the
//  person can type in a minute).
//
//  Two cards at most, work and personal: a switch, not a builder.
//
//  **One spelling, not two** (Egor, 2026-09-22). The card used to carry
//  a second, latin, spelling of the name and company to keep the QR
//  payload small abroad. It is gone: one card, one set of fields. The
//  byte counter stays and does the same job honestly — a name in
//  Cyrillic costs two bytes a letter, the counter shows it, and the
//  person decides. A card written before this reads its latin spelling
//  if there was one, and its own otherwise.
//
//  A photo may be attached (K-1, Egor): it is shown on the card screen
//  and on the widget and is **never** part of the vCard — a `PHOTO`
//  line is kilobytes and would destroy the one property the code must
//  have, which is that it scans.
//

import Foundation

public nonisolated struct BusinessCard: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        case work, personal
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .work: String(localized: "Work")
            case .personal: String(localized: "Personal")
            }
        }
    }

    public var kind: Kind = .work
    public var name = ""
    public var company = ""
    public var role = ""
    public var phone = ""
    public var email = ""
    /// One link — the person's own, not Daisy's.
    public var link = ""
    /// A photo lives beside the card as a file (`BusinessCardStorage`),
    /// not inside it; this is just whether there is one.
    public var hasPhoto = false
    /// A company logo, shown in the middle of the code. Also a file
    /// beside the card — and, like the photo, never inside the vCard.
    /// It costs redundancy: with a logo the code is generated at
    /// correction level Q (see `QRCode.correction(hasLogo:)`).
    public var hasLogo = false

    public var id: String { kind.rawValue }

    public init(kind: Kind = .work) { self.kind = kind }

    // MARK: - Reading a card written before the latin fields went away

    private enum CodingKeys: String, CodingKey {
        case kind, name, company, role, phone, email, link, hasPhoto, hasLogo
        case nameLatin, companyLatin   // 2026-09-22 and earlier
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .work
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        phone = try c.decodeIfPresent(String.self, forKey: .phone) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        link = try c.decodeIfPresent(String.self, forKey: .link) ?? ""
        hasPhoto = try c.decodeIfPresent(Bool.self, forKey: .hasPhoto) ?? false
        hasLogo = try c.decodeIfPresent(Bool.self, forKey: .hasLogo) ?? false
        // The latin spelling wins when it was filled in — that is the
        // one that was being handed out at a conference.
        let name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        let nameLatin = try c.decodeIfPresent(String.self, forKey: .nameLatin) ?? ""
        self.name = nameLatin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? name : nameLatin
        let company = try c.decodeIfPresent(String.self, forKey: .company) ?? ""
        let companyLatin = try c.decodeIfPresent(String.self, forKey: .companyLatin) ?? ""
        self.company = companyLatin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? company : companyLatin
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(company, forKey: .company)
        try c.encode(role, forKey: .role)
        try c.encode(phone, forKey: .phone)
        try c.encode(email, forKey: .email)
        try c.encode(link, forKey: .link)
        try c.encode(hasPhoto, forKey: .hasPhoto)
        try c.encode(hasLogo, forKey: .hasLogo)
    }

    /// Nothing to hand over yet.
    public var isEmpty: Bool {
        [name, company, role, phone, email, link]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// A card is worth showing when it has a name and one way to reach
    /// the person.
    public var isUsable: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasContact = ![phone, email, link].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return hasName && hasContact
    }

    public var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var displayCompany: String { company.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Family name last, as vCard's `N` wants it: everything after the
    /// first word is the family name, the first word is the given one.
    /// Good enough for a card someone typed themselves.
    public static func splitName(_ full: String) -> (given: String, family: String) {
        let parts = full.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 1 else { return (parts.first ?? "", "") }
        return (parts[0], parts.dropFirst().joined(separator: " "))
    }
}

/// Where both cards live: one JSON file in the app group, so the app
/// writes it and the widget extension reads it without an IPC dance.
/// A photo sits beside it as `card-work.jpg` / `card-personal.jpg`.
public nonisolated enum BusinessCardStorage {
    public static let appGroup = "group.app.essazanov.DaisyLite"
    public static let fileName = "business-cards.json"

    public static func container(appGroup: String = appGroup) -> URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
    }

    public static func fileURL(appGroup: String = appGroup) -> URL {
        container(appGroup: appGroup).appendingPathComponent(fileName)
    }

    public static func photoURL(for kind: BusinessCard.Kind, appGroup: String = appGroup) -> URL {
        container(appGroup: appGroup).appendingPathComponent("card-\(kind.rawValue).jpg")
    }

    /// The small copy the widget reads — see `CardPhoto` for why the
    /// extension must never open the big one.
    public static func photoThumbnailURL(for kind: BusinessCard.Kind, appGroup: String = appGroup) -> URL {
        container(appGroup: appGroup).appendingPathComponent("card-\(kind.rawValue)-thumb.jpg")
    }

    /// The company logo. PNG, because a logo usually has transparency
    /// and a JPEG would put a white square in the middle of the code.
    public static func logoURL(for kind: BusinessCard.Kind, appGroup: String = appGroup) -> URL {
        container(appGroup: appGroup).appendingPathComponent("logo-\(kind.rawValue).png")
    }

    public static func logo(for kind: BusinessCard.Kind, appGroup: String = appGroup) -> Data? {
        try? Data(contentsOf: logoURL(for: kind, appGroup: appGroup))
    }

    public static func saveLogo(_ png: Data?, for kind: BusinessCard.Kind, appGroup: String = appGroup) {
        let url = logoURL(for: kind, appGroup: appGroup)
        guard let png else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: url, options: .atomic)
    }

    public static func load(appGroup: String = appGroup) -> [BusinessCard] {
        load(from: fileURL(appGroup: appGroup))
    }

    public static func save(_ cards: [BusinessCard], appGroup: String = appGroup) {
        save(cards, to: fileURL(appGroup: appGroup))
    }

    /// The file operations themselves, against any location — the app
    /// group on a device, a temporary directory in a test (the real
    /// `~/Library/Group Containers` is not writable outside an app).
    public static func load(from url: URL) -> [BusinessCard] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([BusinessCard].self, from: data)) ?? []
    }

    public static func save(_ cards: [BusinessCard], to url: URL) {
        guard let data = try? JSONEncoder().encode(cards) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public static func photo(for kind: BusinessCard.Kind, appGroup: String = appGroup) -> Data? {
        try? Data(contentsOf: photoURL(for: kind, appGroup: appGroup))
    }

    /// What the widget loads. Falls back to the big file only if the
    /// thumbnail is missing (a card saved by an older build).
    public static func photoThumbnail(for kind: BusinessCard.Kind, appGroup: String = appGroup) -> Data? {
        if let small = try? Data(contentsOf: photoThumbnailURL(for: kind, appGroup: appGroup)) { return small }
        return photo(for: kind, appGroup: appGroup)
    }

    /// Writes both sizes, or removes both.
    public static func savePhoto(_ jpeg: Data?, thumbnail: Data?, for kind: BusinessCard.Kind, appGroup: String = appGroup) {
        let url = photoURL(for: kind, appGroup: appGroup)
        let thumbURL = photoThumbnailURL(for: kind, appGroup: appGroup)
        guard let jpeg else {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: thumbURL)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? jpeg.write(to: url, options: .atomic)
        if let thumbnail { try? thumbnail.write(to: thumbURL, options: .atomic) }
    }

    /// The card the person last had in front, for the widget.
    public static func selected(appGroup: String = appGroup) -> BusinessCard? {
        let kind = UserDefaults(suiteName: appGroup)?.string(forKey: "daisy.card.selected")
            .flatMap(BusinessCard.Kind.init(rawValue:)) ?? .work
        let cards = load(appGroup: appGroup)
        return cards.first { $0.kind == kind } ?? cards.first { $0.isUsable }
    }
}
