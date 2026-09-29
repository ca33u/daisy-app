//
//  MeetingRecap.swift
//  DaisyCore
//
//  Backlog 24 М-1: the recap the people who were there get — decisions,
//  then the steps with who and by when, then one line inviting
//  corrections; in the meeting's language, nothing from the transcript.
//  One text for the phone and the Mac.
//

import Foundation

public nonisolated enum MeetingRecap {
    /// The meeting's language, for text that leaves the device.
    public enum Language: Equatable, Sendable {
        case english, russian

        public init(locale: String?) {
            self = (locale ?? "").lowercased().hasPrefix("ru") ? .russian : .english
        }

        var locale: Locale { Locale(identifier: self == .russian ? "ru_RU" : "en_US") }
    }

    /// Everyone the event had, minus the person sending; else the people
    /// named in the steps who have an address.
    public static func recipients(eventEmails: [String], ownEmails: [String], leadEmails: [String]) -> [String] {
        let own = Set(ownEmails.map { $0.lowercased() })
        let source = eventEmails.isEmpty ? leadEmails : eventEmails
        var seen = Set<String>()
        return source.filter { !own.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
    }

    public static func subject(title: String, date: Date?, language: Language) -> String {
        guard let date else { return title }
        return "\(title) — \(date.formatted(.dateTime.day().month(.wide).locale(language.locale)))"
    }

    public static func body(actions: [ActionItem], language: Language) -> String {
        let decisions = actions.filter { $0.kind == .decision && $0.status?.state != .dismissed }
        let steps = actions.filter { $0.kind.isActionable && $0.status?.state != .dismissed }
        var parts: [String] = []
        if !decisions.isEmpty {
            parts.append((language == .russian ? "Решили:" : "Decided:") + "\n"
                         + decisions.map { "• " + $0.text }.joined(separator: "\n"))
        }
        if !steps.isEmpty {
            parts.append((language == .russian ? "Дальше:" : "Next steps:") + "\n"
                         + steps.map { "• " + stepLine($0, language: language) }.joined(separator: "\n"))
        }
        parts.append(language == .russian ? "Если что-то не так — напишите, поправлю."
                                          : "If anything is off, let me know and I'll fix it.")
        return parts.joined(separator: "\n\n")
    }

    /// «Send the deck — Maria, by 3 Oct».
    public static func stepLine(_ action: ActionItem, language: Language) -> String {
        var tail: [String] = []
        if let owner = action.owner, !["me", "i", "я"].contains(owner.lowercased()) { tail.append(owner) }
        if let due = action.dueDate {
            let day = due.formatted(.dateTime.day().month(.abbreviated).locale(language.locale))
            tail.append(language == .russian ? "до \(day)" : "by \(day)")
        }
        return tail.isEmpty ? action.text : "\(action.text) — \(tail.joined(separator: ", "))"
    }

    /// The steps alone, as one text, no greeting.
    public static func stepsText(actions: [ActionItem], language: Language) -> String {
        actions.filter { $0.kind.isActionable && $0.status?.state != .dismissed }
            .map { "• " + stepLine($0, language: language) }
            .joined(separator: "\n")
    }
}
