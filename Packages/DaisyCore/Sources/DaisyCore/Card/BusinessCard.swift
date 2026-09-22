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
//  Each card carries a second, LATIN spelling of the name and company.
//  This is not decoration: in a QR code UTF-8 Cyrillic costs two bytes
//  per character plus a mode switch, so "Егор Сазанов" is twice the
//  payload of "Egor Sazanov", and older Android scanners mangle it.
//  At an international conference the latin card is what gets handed
//  over; to people who read Cyrillic, the native one (K-2 decides
//  which by size and by what the scanner can take).
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
    /// Latin spelling of `name`, for the code that crosses borders.
    public var nameLatin = ""
    public var company = ""
    public var companyLatin = ""
    public var role = ""
    public var phone = ""
    public var email = ""
    /// One link — the person's own, not Daisy's.
    public var link = ""

    public var id: String { kind.rawValue }

    public init(kind: Kind = .work) { self.kind = kind }

    /// Nothing to hand over yet.
    public var isEmpty: Bool {
        [name, nameLatin, company, companyLatin, role, phone, email, link]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// A card is worth showing when it has at least a name (in either
    /// spelling) and one way to reach the person.
    public var isUsable: Bool {
        let hasName = !displayName(latin: false).isEmpty || !displayName(latin: true).isEmpty
        let hasContact = ![phone, email, link].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return hasName && hasContact
    }

    /// The name to show/encode: the latin spelling when asked for and
    /// present, the native one otherwise — never an empty string when
    /// the other field has something.
    public func displayName(latin: Bool) -> String {
        let wanted = (latin ? nameLatin : name).trimmingCharacters(in: .whitespacesAndNewlines)
        if !wanted.isEmpty { return wanted }
        return (latin ? name : nameLatin).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func displayCompany(latin: Bool) -> String {
        let wanted = (latin ? companyLatin : company).trimmingCharacters(in: .whitespacesAndNewlines)
        if !wanted.isEmpty { return wanted }
        return (latin ? company : companyLatin).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Family name last, as vCard's `N` wants it: everything after the
    /// first word is the family name, the first word is the given one.
    /// Good enough for a card someone typed themselves; the person can
    /// always write the name the way they want it read.
    public static func splitName(_ full: String) -> (given: String, family: String) {
        let parts = full.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 1 else { return (parts.first ?? "", "") }
        return (parts[0], parts.dropFirst().joined(separator: " "))
    }
}


/// Where both cards live: one JSON file in the app group, so the app
/// writes it and the widget extension reads it without an IPC dance.
public nonisolated enum BusinessCardStorage {
    public static let appGroup = "group.app.essazanov.DaisyLite"
    public static let fileName = "business-cards.json"

    public static func fileURL(appGroup: String = appGroup) -> URL {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return container.appendingPathComponent(fileName)
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

    /// The card the person last had in front, for the widget.
    public static func selected(appGroup: String = appGroup) -> BusinessCard? {
        let kind = UserDefaults(suiteName: appGroup)?.string(forKey: "daisy.card.selected")
            .flatMap(BusinessCard.Kind.init(rawValue:)) ?? .work
        let cards = load(appGroup: appGroup)
        return cards.first { $0.kind == kind } ?? cards.first { $0.isUsable }
    }
}
