//
//  CloudSummaryDTO.swift
//  DaisyCore
//
//  Copied from daisy-app/Daisy/SummaryProvider.swift @ 1.0.7.72,
//  2026-09-19 (backlog 4 B-2): the tolerant decoder for what a cloud
//  model returns — strips Markdown fences, extracts the outermost JSON
//  object, remaps the key aliases models emit despite the schema.
//

import Foundation

nonisolated struct CloudSummaryDTO: Codable {
    let summary: String?
    let sections: [DTOSection]?
    let actionItems: [String]?
    let clientFollowUp: String?
    /// Backlog 22 Д-0; absent from older prompts and from the proxy until
    /// it carries them — then the strings stand alone.
    let actions: [DTOAction]?

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
            actions: typedActions
        )
    }

    /// The typed list, one per string when the model kept to the order;
    /// nil (so the strings stand alone) when it returned none.
    private var typedActions: [ActionItem]? {
        guard let actions, !actions.isEmpty else { return nil }
        return actions.compactMap { $0.toActionItem() }
    }

    var isEffectivelyEmpty: Bool {
        (summary ?? "").isEmpty && (sections ?? []).isEmpty && (actionItems ?? []).isEmpty
    }

    /// Alias → canonical key, longest first.
    static let keyAliases: [(String, String)] = [
        ("client_follow_up", "clientFollowUp"),
        ("action_items",     "actionItems"),
        ("outline",          "sections"),
        ("topics",           "sections"),
        ("follow_up",        "clientFollowUp"),
        ("followup",         "clientFollowUp"),
        ("lede",             "summary"),
        ("tldr",             "summary"),
        ("headline",         "summary"),
    ]

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
            throw SummaryProviderError.parseFailed(provider: "cloud", message: "Empty response — the model returned nothing after fence stripping.")
        }
        guard let data = s.data(using: .utf8) else {
            throw SummaryProviderError.parseFailed(provider: "cloud", message: "Couldn't encode response as UTF-8.")
        }
        let decoder = JSONDecoder()
        do {
            let dto = try decoder.decode(CloudSummaryDTO.self, from: data)
            if dto.isEffectivelyEmpty,
               let remappedData = remapKeyAliases(jsonString: s).data(using: .utf8),
               let retried = try? decoder.decode(CloudSummaryDTO.self, from: remappedData),
               !retried.isEffectivelyEmpty {
                return retried
            }
            return dto
        } catch {
            guard let remappedData = remapKeyAliases(jsonString: s).data(using: .utf8) else { throw error }
            do {
                return try decoder.decode(CloudSummaryDTO.self, from: remappedData)
            } catch {
                throw SummaryProviderError.parseFailed(provider: "cloud", message: "JSON schema mismatch (\(error.localizedDescription)).")
            }
        }
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

    /// `"lede":` → `"summary":` and friends; only keys (followed by a colon).
    private static func remapKeyAliases(jsonString: String) -> String {
        var result = jsonString
        for (alias, canonical) in keyAliases {
            let variants = [alias, alias.uppercased(), alias.prefix(1).uppercased() + alias.dropFirst()]
            for v in variants {
                result = result.replacingOccurrences(of: "\"\(v)\":", with: "\"\(canonical)\":")
                result = result.replacingOccurrences(of: "\"\(v)\" :", with: "\"\(canonical)\":")
            }
        }
        return result
    }
}

nonisolated struct DTOSection: Codable {
    let title: String
    let bullets: [DTOBullet]?

    func toSummarySection() -> SummarySection {
        SummarySection(title: title, bullets: (bullets ?? []).map { $0.toSummaryBullet() })
    }
}

nonisolated struct DTOBullet: Codable {
    let text: String
    let children: [DTOBullet]?

    func toSummaryBullet() -> SummaryBullet {
        SummaryBullet(text: text, children: (children ?? []).map { $0.toSummaryBullet() })
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

    enum CodingKeys: String, CodingKey {
        case title, attendees, start, durationMinutes, to, subject, points, location
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
            location: clean(location))
    }
}
