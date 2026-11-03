//
//  CloudSummaryDTO.swift
//  DaisyCore
//
//  Copied from daisy-app/Daisy/SummaryProvider.swift @ 1.0.7.72,
//  2026-09-19 (backlog 4 B-2): the tolerant decoder for what a cloud
//  model returns — strips Markdown fences, extracts the outermost JSON
//  object, reads the key aliases models emit despite the schema.
//

import Foundation
import os

nonisolated struct CloudSummaryDTO: Decodable {
    let summary: String?
    let sections: [DTOSection]?
    let actionItems: [String]?
    let clientFollowUp: String?
    /// Backlog 22 Д-0; absent from older prompts and from the proxy until
    /// it carries them — then the strings stand alone.
    let actions: [DTOAction]?
    /// The meeting's short name (03.10.2026); absent from the proxy until
    /// it carries the field.
    let title: String?

    /// Element by element (03.11.2026): a field of the wrong type reads as
    /// absent, and a broken section, bullet, action item or action is
    /// mended or left out — never the whole summary. See `LenientJSON`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LenientJSON.Key.self)
        summary = LenientJSON.string(container, Self.summaryKeys)
        clientFollowUp = LenientJSON.string(container, Self.clientFollowUpKeys)
        title = LenientJSON.string(container, ["title"])
        actionItems = (LenientJSON.list(container, Self.actionItemsKeys) as [DTOText]?)?.map(\.text)
        actions = LenientJSON.list(container, ["actions"])
        sections = (LenientJSON.list(container, Self.sectionsKeys) as [DTOSection]?).map(DTOSection.titled)
    }

    func toMeetingSummary() -> MeetingSummary {
        let lede: String = {
            if let s = summary, !s.isEmpty { return s }
            if let t = sections?.first?.title, !t.isEmpty { return t }
            if let a = actionItems?.first, !a.isEmpty { return a }
            return ""
        }()
        return MeetingSummary(
            summary: lede,
            sections: (sections ?? []).map { $0.toSummarySection() },
            actionItems: actionItems ?? [],
            clientFollowUp: clientFollowUp ?? "",
            actions: typedActions,
            title: title
        )
    }

    /// The typed list, one per string when the model kept to the order;
    /// nil (so the strings stand alone) when it returned none.
    private var typedActions: [ActionItem]? {
        guard let actions, !actions.isEmpty else { return nil }
        return actions.compactMap { $0.toActionItem() }
    }

    /// Each field under its canonical name first, then the names models
    /// use for it despite the schema, case ignored — read straight off the
    /// keys since 03.11.2026 (a string rewrite of the JSON ran before).
    static let summaryKeys = ["summary", "lede", "tldr", "headline"]
    static let sectionsKeys = ["sections", "outline", "topics"]
    static let actionItemsKeys = ["actionItems", "action_items"]
    static let clientFollowUpKeys = ["clientFollowUp", "client_follow_up", "follow_up", "followup"]

    static func decode(from text: String) throws -> CloudSummaryDTO {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNL = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNL)...])
            }
            if s.hasSuffix("```") { s = String(s.dropLast(3)) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let extracted = extractOutermostJSONObject(s) { s = extracted }
        if s.isEmpty {
            throw DecodeFailure(reason: "Empty response — the model returned nothing after fence stripping.")
        }
        guard let data = s.data(using: .utf8) else {
            throw DecodeFailure(reason: "Couldn't encode response as UTF-8.")
        }
        do {
            return try JSONDecoder().decode(CloudSummaryDTO.self, from: data)
        } catch {
            // Every field and element is read leniently, so only text that
            // isn't JSON, or JSON that isn't an object, gets here.
            throw DecodeFailure(reason: "JSON schema mismatch: \(LenientJSON.reason(error)).")
        }
    }

    /// Only the reason: the provider wraps it once as «<provider>: <reason>»
    /// (it read «Anthropic: cloud: …» before 03.11.2026).
    struct DecodeFailure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Outermost balanced `{ … }`, ignoring braces inside string literals.
    private static func extractOutermostJSONObject(_ s: String) -> String? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escape = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if escape {
                escape = false
            } else if inString {
                if c == "\\" { escape = true } else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "{":
                    if depth == 0 { start = i }
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0, let start { return String(s[start...i]) }
                default: break
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}

nonisolated struct DTOSection {
    /// Nil only straight out of the decoder; `titled` gives every section
    /// one before anything else reads it.
    let title: String?
    let bullets: [DTOBullet]?

    func toSummarySection() -> SummarySection {
        SummarySection(
            title: title ?? "",
            bullets: (bullets ?? []).flatMap { $0.toSummaryBullets() }
        )
    }

    /// Every section titled, no bullet lost: one without a title joins the
    /// section before it (the first titled one when it comes first); when
    /// none has a title, the first bullet becomes it.
    static func titled(_ sections: [DTOSection]) -> [DTOSection] {
        var result: [DTOSection] = []
        var leading: [DTOBullet] = []
        for (index, section) in sections.enumerated() {
            let bullets = section.bullets ?? []
            if let title = section.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(DTOSection(title: title, bullets: leading + bullets))
                leading = []
            } else if let previous = result.popLast() {
                LenientJSON.log.error("Summary JSON: sections[\(index, privacy: .public)] has no title — its bullets join the section before")
                result.append(DTOSection(title: previous.title, bullets: (previous.bullets ?? []) + bullets))
            } else {
                LenientJSON.log.error("Summary JSON: sections[\(index, privacy: .public)] has no title — its bullets join the next titled section")
                leading += bullets
            }
        }
        let orphans = leading.flatMap(\.withTextPromoted)
        if let first = orphans.first, let title = first.text {
            result.append(DTOSection(title: title, bullets: (first.children ?? []) + orphans.dropFirst()))
        }
        return result
    }
}

nonisolated extension DTOSection: Decodable {
    /// `{"title": …, "bullets": […]}`, under a few other names models
    /// use, or a bare string as a title with no bullets.
    init(from decoder: Decoder) throws {
        if let title = try? decoder.singleValueContainer().decode(String.self) {
            self.init(title: title, bullets: nil)
            return
        }
        let container = try decoder.container(keyedBy: LenientJSON.Key.self)
        let title = LenientJSON.string(container, ["title", "heading", "header", "name"])
        let bullets: [DTOBullet]? = LenientJSON.list(container, ["bullets", "items", "points"])
        guard title != nil || !(bullets ?? []).isEmpty else {
            throw DecodingError.keyNotFound(LenientJSON.Key(stringValue: "title"), .init(codingPath: decoder.codingPath, debugDescription: "No title and no bullets"))
        }
        self.init(title: title, bullets: bullets)
    }
}

/// JSON shape of a bullet. `children` is optional; missing/null in
/// the LLM output is treated as "no sub-bullets", which is the
/// common case for shallow facts.
nonisolated struct DTOBullet {
    /// Nil or blank when the model wrote only children; those stand in
    /// for it (`toSummaryBullets`).
    let text: String?
    let children: [DTOBullet]?

    private var hasText: Bool {
        !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// This bullet, or its children in its place when it has no text.
    var withTextPromoted: [DTOBullet] {
        hasText ? [self] : (children ?? []).flatMap(\.withTextPromoted)
    }

    func toSummaryBullets() -> [SummaryBullet] {
        withTextPromoted.map { bullet in
            SummaryBullet(
                text: bullet.text ?? "",
                children: (bullet.children ?? []).flatMap { $0.toSummaryBullets() }
            )
        }
    }
}

nonisolated extension DTOBullet: Decodable {
    /// `{"text": …, "children": […]}`, under a few other names models
    /// use, or a bare string.
    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self.init(text: text, children: nil)
            return
        }
        let container = try decoder.container(keyedBy: LenientJSON.Key.self)
        // `title` last: a bullet written like a section keeps its heading
        // as its text and its bullets as children.
        let text = LenientJSON.string(container, ["text", "content", "point", "bullet", "title"])
        let children: [DTOBullet]? = LenientJSON.list(container, ["children", "subBullets", "sub_bullets", "bullets"])
        guard text != nil || !(children ?? []).isEmpty else {
            throw DecodingError.keyNotFound(LenientJSON.Key(stringValue: "text"), .init(codingPath: decoder.codingPath, debugDescription: "No text and no children"))
        }
        self.init(text: text, children: children)
    }
}

/// One `actionItems` entry: a string, or an object a model made of it.
nonisolated struct DTOText: Decodable {
    let text: String

    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self.text = text
            return
        }
        let container = try decoder.container(keyedBy: LenientJSON.Key.self)
        guard let text = LenientJSON.string(container, ["text", "task", "action", "title"]) else {
            throw DecodingError.keyNotFound(LenientJSON.Key(stringValue: "text"), .init(codingPath: decoder.codingPath, debugDescription: "No text"))
        }
        self.text = text
    }
}

/// One `actions` entry as a model writes it — every field optional, kinds
/// and numbers tolerated in whatever shape they come.
nonisolated struct DTOAction: Codable {
    let text: String?
    let kind: String?
    let owner: String?
    let due: String?
    let people: [String]?
    let confidence: Double?
    let payload: DTOPayload?

    enum CodingKeys: String, CodingKey {
        case text, kind, owner, due, people = "with", confidence, payload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        owner = try? c.decodeIfPresent(String.self, forKey: .owner)
        due = try? c.decodeIfPresent(String.self, forKey: .due)
        people = (try? c.decodeIfPresent([String].self, forKey: .people))
            ?? (try? c.decodeIfPresent(String.self, forKey: .people)).flatMap { $0.map { [$0] } }
        if let number = try? c.decodeIfPresent(Double.self, forKey: .confidence) {
            confidence = number
        } else if let string = try? c.decodeIfPresent(String.self, forKey: .confidence) {
            confidence = Double(string)
        } else {
            confidence = nil
        }
        payload = try? c.decodeIfPresent(DTOPayload.self, forKey: .payload)
    }

    func toActionItem() -> ActionItem? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let kind = kind.flatMap { ActionItem.Kind(rawValue: $0.lowercased().trimmingCharacters(in: .whitespaces)) } ?? .other
        func clean(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
                  !["null", "none", "n/a", "-"].contains(s.lowercased()) else { return nil }
            return s
        }
        let dueValue = clean(due).flatMap { ActionItem.date(from: $0) != nil ? $0 : nil }
        let mapped = payload?.toPayload()
        return ActionItem(text: text, kind: kind, owner: clean(owner), due: dueValue,
                          with: (people ?? []).compactMap(clean),
                          confidence: min(1, max(0, confidence ?? 1)),
                          payload: mapped?.isEmpty == true ? nil : mapped)
    }
}

nonisolated struct DTOPayload: Codable {
    let title: String?
    let attendees: [String]?
    let start: String?
    let durationMinutes: Int?
    let to: [String]?
    let subject: String?
    let points: [String]?
    let location: String?
    let editsCurrentEvent: Bool?
    let place: String?

    enum CodingKeys: String, CodingKey {
        case title, attendees, start, durationMinutes, to, subject, points, location, editsCurrentEvent, place
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        attendees = try? c.decodeIfPresent([String].self, forKey: .attendees)
        start = try? c.decodeIfPresent(String.self, forKey: .start)
        durationMinutes = (try? c.decodeIfPresent(Int.self, forKey: .durationMinutes))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .durationMinutes)).flatMap { $0.map { Int($0) } }
        to = (try? c.decodeIfPresent([String].self, forKey: .to))
            ?? (try? c.decodeIfPresent(String.self, forKey: .to)).flatMap { $0.map { [$0] } }
        subject = try? c.decodeIfPresent(String.self, forKey: .subject)
        points = try? c.decodeIfPresent([String].self, forKey: .points)
        location = try? c.decodeIfPresent(String.self, forKey: .location)
        editsCurrentEvent = (try? c.decodeIfPresent(Bool.self, forKey: .editsCurrentEvent))
            ?? (try? c.decodeIfPresent(String.self, forKey: .editsCurrentEvent)).flatMap { $0.map { $0.lowercased() == "true" } }
        place = try? c.decodeIfPresent(String.self, forKey: .place)
    }

    func toPayload() -> ActionItem.Payload {
        func clean(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.lowercased() != "null" else { return nil }
            return s
        }
        return ActionItem.Payload(
            title: clean(title), attendees: attendees?.compactMap(clean),
            start: clean(start).flatMap { ActionItem.date(from: $0) != nil ? $0 : nil },
            durationMinutes: durationMinutes.flatMap { $0 > 0 && $0 <= 600 ? $0 : nil },
            to: to?.compactMap(clean), subject: clean(subject), points: points?.compactMap(clean),
            location: clean(location), editsCurrentEvent: editsCurrentEvent == true ? true : nil, place: clean(place))
    }
}
