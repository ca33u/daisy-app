//
//  NotionExporter.swift
//  Daisy
//
//  Pushes a finished meeting (summary + transcript) into Notion as a new
//  child page under the user's configured parent page. Uses the official
//  REST API directly — no third-party SDK.
//

import Foundation
import os

struct MeetingExportData: Sendable {
    let title: String
    let summary: MeetingSummary?
    let transcriptChunks: [String]
    let durationSeconds: Int
    let locale: String
    let startedAt: Date?
}

actor NotionExporter {
    static let shared = NotionExporter()

    enum NotionError: LocalizedError {
        case missingCredentials
        case invalidParentID
        case httpError(Int, String)
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "Notion token or parent page ID is missing. Open Settings to configure."
            case .invalidParentID:
                return "Notion parent ID looks malformed (expecting 32 hex chars)."
            case .httpError(let code, let body):
                return "Notion API error \(code): \(body)"
            case .decodingFailed(let msg):
                return "Could not decode Notion response: \(msg)"
            }
        }
    }

    private let urlSession = URLSession.shared
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Notion")

    /// Create a new page under the configured parent containing the
    /// rendered meeting summary + transcript. Returns the canonical URL
    /// to the new page.
    func createMeetingPage(_ data: MeetingExportData) async throws -> URL {
        guard let token = await readCredential(SecretKey.notionToken),
              let rawParent = await readCredential(SecretKey.notionParentID),
              !token.isEmpty, !rawParent.isEmpty else {
            throw NotionError.missingCredentials
        }

        let normalized = rawParent
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard normalized.count == 32 else {
            throw NotionError.invalidParentID
        }
        let parentID = formatPageID(normalized)
        // Read the user's "page vs database" choice from settings.
        // Off-main reading from a MainActor singleton — keep this
        // explicit so the async hop is visible at the call site.
        let parentKind = await readParentKind()

        let body = buildPageJSON(parentID: parentID, data: data, parentKind: parentKind)
        return try await post(body, token: token)
    }

    /// Backlog 24 М-14: one next step as its own page, in the same parent
    /// as the meetings. Marked as a step by its title, not a column — a
    /// «Type» property would fail on every database that has none.
    func createActionPage(title: String, lines: [String]) async throws -> URL {
        guard let token = await readCredential(SecretKey.notionToken),
              let rawParent = await readCredential(SecretKey.notionParentID),
              !token.isEmpty, !rawParent.isEmpty else {
            throw NotionError.missingCredentials
        }
        let normalized = rawParent.replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespaces)
        guard normalized.count == 32 else { throw NotionError.invalidParentID }
        let parentID = formatPageID(normalized)
        let parentKind = await readParentKind()
        let titleKey = parentKind == "database" ? "Name" : "title"
        let parent: [String: Any] = parentKind == "database" ? ["database_id": parentID] : ["page_id": parentID]
        let body: [String: Any] = [
            "parent": parent,
            "properties": [
                titleKey: ["title": [["type": "text", "text": ["content": title.notionTrimmed]]]]
            ],
            "children": lines.filter { !$0.isEmpty }.map(paragraph),
        ]
        return try await post(body, token: token)
    }

    private func post(_ body: [String: Any], token: String) async throws -> URL {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/pages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (responseData, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NotionError.httpError(0, "No HTTP response.")
        }
        if !(200..<300).contains(http.statusCode) {
            let payload = String(data: responseData, encoding: .utf8) ?? "<empty>"
            // payload stays .private — Notion error bodies often
            // include the parent_id / database_id we sent, which is a
            // workspace-internal capability identifier.
            log.error("Notion HTTP \(http.statusCode): \(payload, privacy: .private)")
            throw NotionError.httpError(http.statusCode, payload)
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let urlString = json["url"] as? String,
              let url = URL(string: urlString) else {
            throw NotionError.decodingFailed("Missing 'url' field.")
        }
        // URL stays .private — Notion page URLs contain the page ID,
        // which together with the integration secret in the Keychain
        // grants read/write access to that page. Status code is fine
        // in logs, the addressable identifier is not.
        log.info("Created Notion page at \(url.absoluteString, privacy: .private)")
        return url
    }

    // MARK: - Helpers

    /// Keychain access is synchronous; wrap to keep this code async-friendly.
    private func readCredential(_ key: String) async -> String? {
        KeychainStore.get(account: key)
    }

    /// Notion parent kind ("page" or "database") read off the
    /// `AppSettings` singleton on the main actor. Defaults to
    /// "page" when the value's missing — matches the historical
    /// behaviour before this setting existed.
    @MainActor
    private func readParentKind() -> String {
        UserDefaults.standard.string(forKey: "daisy.notionParentKind") ?? "page"
    }

    private func formatPageID(_ raw: String) -> String {
        let s = Array(raw)
        let parts = [
            String(s[0..<8]),
            String(s[8..<12]),
            String(s[12..<16]),
            String(s[16..<20]),
            String(s[20..<32])
        ]
        return parts.joined(separator: "-")
    }

    private func buildPageJSON(parentID: String, data: MeetingExportData, parentKind: String) -> [String: Any] {
        var children: [[String: Any]] = []

        // Metadata callout-style paragraph.
        if let started = data.startedAt {
            let stamp = DateFormatter.localizedString(from: started, dateStyle: .medium, timeStyle: .short)
            let dur = "\(data.durationSeconds / 60):\(String(format: "%02d", data.durationSeconds % 60))"
            children.append(paragraph("📌  \(stamp)  ·  \(dur)  ·  \(data.locale)"))
        }

        if let summary = data.summary {
            // Localise the H2 headers to match the summary content
            // language — so a Russian session sent to Notion shows
            // "Встреча / Следующие шаги / Ответ клиенту" instead of
            // English headers above Russian content.
            var sample = summary.summary
            if sample.count < 60, let firstBullet = summary.sections.first?.bullets.first?.text {
                sample += " " + firstBullet
            }
            let labels = SummaryLabels.for(language: LanguageDetector.detect(sample))

            children.append(heading2(labels.meeting))
            children.append(paragraph(summary.summary))

            if !summary.actionItems.isEmpty {
                children.append(heading2(labels.nextActions))
                for item in summary.actionItems {
                    children.append(todo(item))
                }
            }

            if !summary.clientFollowUp.isEmpty {
                children.append(heading2(labels.followUp))
                children.append(paragraph(summary.clientFollowUp))
            }

            children.append(divider())
        }

        children.append(heading2("Transcript"))
        for chunk in data.transcriptChunks {
            children.append(paragraph(chunk))
        }

        // Body shape differs between page-parent and database-parent:
        //   • Page parent — `properties` key must be exactly "title"
        //     (the implicit title slot every Notion page has).
        //   • Database parent — `properties` key must match the
        //     title-type column's name in that database. Default
        //     Notion DBs use "Name"; if the user renamed it, our
        //     POST will fail with a clear API error pointing at it.
        //     We don't fetch the schema to auto-discover the title
        //     column name — that's an extra GET on every send for
        //     a value users typically keep as "Name". Catch the
        //     error if/when they hit it and link to docs.
        if parentKind == "database" {
            return [
                "parent": ["database_id": parentID],
                "properties": [
                    "Name": [
                        "title": [
                            ["type": "text", "text": ["content": data.title.notionTrimmed]]
                        ]
                    ]
                ],
                "children": children
            ]
        } else {
            return [
                "parent": ["page_id": parentID],
                "properties": [
                    "title": [
                        "title": [
                            ["type": "text", "text": ["content": data.title.notionTrimmed]]
                        ]
                    ]
                ],
                "children": children
            ]
        }
    }

    // MARK: - Block factories

    private func paragraph(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "paragraph",
            "paragraph": ["rich_text": richText(text)]
        ]
    }

    private func heading2(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "heading_2",
            "heading_2": ["rich_text": richText(text)]
        ]
    }

    private func todo(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "to_do",
            "to_do": [
                "rich_text": richText(text),
                "checked": false
            ]
        ]
    }

    private func divider() -> [String: Any] {
        ["object": "block", "type": "divider", "divider": [String: Any]()]
    }

    private func richText(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": ["content": text.notionTrimmed]]]
    }
}

nonisolated private extension String {
    /// Notion caps `rich_text.content` at 2000 characters per element.
    var notionTrimmed: String {
        if count <= 2000 { return self }
        return String(prefix(1997)) + "…"
    }
}
