//
//  ActionItem.swift
//  DaisyCore
//
//  Backlog 22 Д-0 (2026-09-28): the meeting's next steps as records an
//  action can be made from — what kind of step it is, whose, by when, with
//  whom — instead of a line of text. `summary.json` carries them as
//  `actions`, beside the old `actionItems` strings, which stay exactly as
//  they were: the Mac (and every summary written before) reads the strings
//  and ignores the key it does not know (§4). A file without `actions`
//  reads as one `other` item per string.
//
//  The phone keeps each item's status here too (Д-1): sent, scheduled,
//  done — where it went and under which identifier — so the Mac sees it
//  through sync, which carries the file byte for byte.
//

import Foundation

public nonisolated struct ActionItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case meeting, email, message, task, code, bug, feature, decision, question, other

        /// Kinds a person acts on; decisions are memory, questions go to the follow-up.
        public var isActionable: Bool { self != .decision && self != .question }
    }

    /// What the step was turned into, and when.
    public struct Status: Codable, Sendable, Equatable {
        public enum State: String, Codable, Sendable { case done, sent, scheduled }
        public var state: State
        /// ISO 8601 — a string, so every encoder writes it the same way.
        public var at: String
        /// `calendar`, `reminders`, `mail`, `messages`, `share`, `chatgpt`, `claude`, `shortcuts`.
        public var destination: String?
        /// `eventIdentifier` / `calendarItemIdentifier` when it became one.
        public var identifier: String?

        public init(state: State, at: Date = Date(), destination: String? = nil, identifier: String? = nil) {
            self.state = state
            self.at = ISO8601DateFormatter().string(from: at)
            self.destination = destination
            self.identifier = identifier
        }
    }

    /// What the form is filled with, when the transcript said it.
    public struct Payload: Codable, Sendable, Equatable {
        public var title: String?
        public var attendees: [String]?
        public var start: String?
        public var durationMinutes: Int?
        public var to: [String]?
        public var subject: String?
        public var points: [String]?
        public var location: String?

        public init(title: String? = nil, attendees: [String]? = nil, start: String? = nil, durationMinutes: Int? = nil,
                    to: [String]? = nil, subject: String? = nil, points: [String]? = nil, location: String? = nil) {
            self.title = title
            self.attendees = attendees
            self.start = start
            self.durationMinutes = durationMinutes
            self.to = to
            self.subject = subject
            self.points = points
            self.location = location
        }

        public var isEmpty: Bool {
            title == nil && (attendees ?? []).isEmpty && start == nil && durationMinutes == nil
                && (to ?? []).isEmpty && subject == nil && (points ?? []).isEmpty && location == nil
        }
    }

    public var id: String
    public var text: String
    public var kind: Kind
    /// As named in the transcript, or `me` for the person who recorded.
    public var owner: String?
    /// ISO 8601 date or date-time, only when one was said.
    public var due: String?
    /// The people it involves.
    public var with: [String]
    /// 1 when said outright; lower when inferred.
    public var confidence: Double
    public var payload: Payload?
    public var status: Status?

    public init(id: String = UUID().uuidString, text: String, kind: Kind = .other, owner: String? = nil,
                due: String? = nil, with: [String] = [], confidence: Double = 1, payload: Payload? = nil,
                status: Status? = nil) {
        self.id = id
        self.text = text
        self.kind = kind
        self.owner = owner
        self.due = due
        self.with = with
        self.confidence = confidence
        self.payload = payload
        self.status = status
    }

    /// A said-outright item; low-confidence ones are shown grey and not counted.
    public var isConfident: Bool { confidence >= 0.6 }

    /// The step belongs to the person holding the phone: no owner named,
    /// `me`, or their own name.
    public func isMine(ownerName: String?) -> Bool {
        guard let owner = owner?.trimmingCharacters(in: .whitespaces), !owner.isEmpty else { return true }
        let lower = owner.lowercased()
        if ["me", "i", "я", "мне", "you", "вы"].contains(lower) { return true }
        guard let name = ownerName?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return false }
        return lower == name || name.contains(lower) || lower.contains(name)
    }

    /// `due` as a date, when it parses: `2026-10-03` or `2026-10-03T15:00[:00][Z]`.
    public var dueDate: Date? { Self.date(from: due) }

    /// Whether `due` named a time of day, not only a date.
    public var dueHasTime: Bool { (due ?? "").contains("T") }

    public static func date(from string: String?) -> Date? {
        guard let s = string?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let full = ISO8601DateFormatter()
        if let d = full.date(from: s) { return d }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// The legacy reading of an `actionItems` string: "Maria: send the
    /// contract" → owner Maria.
    public static func legacy(_ text: String, index: Int) -> ActionItem {
        var owner: String?
        var body = text
        if let colon = text.firstIndex(of: ":") {
            let head = text[..<colon].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty, head.split(separator: " ").count <= 3, head.count <= 30 {
                owner = head
                body = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return ActionItem(id: "legacy-\(index)", text: body.isEmpty ? text : body, kind: .other, owner: owner)
    }
}
