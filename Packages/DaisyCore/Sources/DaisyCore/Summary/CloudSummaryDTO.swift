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
            clientFollowUp: clientFollowUp ?? ""
        )
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
