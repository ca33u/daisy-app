// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  NotionExporter.swift
//  Daisy
//
//  Pushes a finished meeting (summary + transcript) into Notion: a child
//  page under the parent the person set, a row of a database, or a meeting
//  note (`NotionMeetingNote`). Uses the official REST API directly — no
//  third-party SDK.
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
        /// Part of the meeting is in Notion, and the page couldn't be
        /// taken back.
        case incompletePage

        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return String(localized: "Notion isn’t set up yet, finish it in \(SettingsRow.notion.path)")
            case .invalidParentID:
                return "Notion parent ID looks malformed (expecting 32 hex chars)."
            case .httpError(let code, let body):
                return "Notion API error \(code): \(body)"
            case .decodingFailed(let msg):
                return "Could not decode Notion response: \(msg)"
            case .incompletePage:
                return String(localized: "Notion took only part of the meeting, an incomplete page is left there")
            }
        }
    }

    private let urlSession = URLSession.shared
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Notion")

    /// Create a new page under the configured parent containing the
    /// rendered meeting summary + transcript. Returns the canonical URL
    /// to the new page.
    func createMeetingPage(_ data: MeetingExportData) async throws -> URL {
        if await readParentKind() == NotionMeetingNote.kind {
            return try await createMeetingNote(data)
        }
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

        var body = buildPageJSON(parentID: parentID, data: data, parentKind: parentKind)
        // A long meeting is more blocks than one request takes: the page
        // with the first of them, the rest appended in order.
        let batches = Self.batches(body["children"] as? [[String: Any]] ?? [])
        body["children"] = batches.first ?? []
        let page = try await post(body, token: token)
        do {
            for batch in batches.dropFirst() {
                try await append(batch, toPage: page.id, token: token)
            }
        } catch {
            // Half a meeting is not a page: it goes to Notion's trash, so
            // sending again doesn't leave two. In a task of its own — a
            // cancelled send takes its page back too.
            let id = page.id
            guard await Task(operation: { await self.trash(page: id, token: token) }).value else {
                throw NotionError.incompletePage
            }
            throw error
        }
        ImprovementStats.record(.exportNotion)
        return page.url
    }

    /// Backlog 24 М-14: one next step as its own page, in the same parent
    /// as the meetings. Marked as a step by its title, not a column — a
    /// «Type» property would fail on every database that has none.
    ///
    /// Beside meeting notes there is no parent: the step is a private page
    /// of the token's owner (Notion allows that to a personal token).
    func createActionPage(title: String, lines: [String]) async throws -> URL {
        if await readParentKind() == NotionMeetingNote.kind {
            let body: [String: Any] = [
                "parent": ["type": "workspace", "workspace": true],
                "properties": [
                    "title": ["title": [["type": "text", "text": ["content": title.notionTrimmed]]]]
                ],
                "children": lines.filter { !$0.isEmpty }.map(paragraph),
            ]
            let page = try await post(body, token: try await personalToken(), personal: true)
            ImprovementStats.record(.exportNotion)
            return page.url
        }
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
        let page = try await post(body, token: token)
        ImprovementStats.record(.exportNotion)
        return page.url
    }

    private func personalToken() async throws -> String {
        guard let token = await readCredential(SecretKey.notionToken), !token.isBlank else {
            throw NotionError.missingCredentials
        }
        return token
    }

    private func createMeetingNote(_ data: MeetingExportData) async throws -> URL {
        var request = URLRequest(url: NotionMeetingNote.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await personalToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(NotionMeetingNote.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.httpBody = try NotionMeetingNote.body(for: data)

        let (responseData, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NotionError.httpError(0, "No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = String(data: responseData, encoding: .utf8) ?? "<empty>"
            log.error("Notion meeting note HTTP \(http.statusCode): \(payload, privacy: .private)")
            if let failure = NotionMeetingNote.Failure(status: http.statusCode, body: responseData) { throw failure }
            throw NotionError.httpError(http.statusCode, payload)
        }
        let url = NotionMeetingNote.pageURL(fromResponse: responseData)
        log.info("Created a Notion meeting note at \(url.absoluteString, privacy: .private)")
        ImprovementStats.record(.exportNotion)
        return url
    }

    /// `personal` — the token was to be a personal one, and a refusal says so.
    private func post(_ body: [String: Any], token: String, personal: Bool = false) async throws -> (url: URL, id: String) {
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
            if personal, let failure = NotionMeetingNote.Failure(status: http.statusCode, body: responseData) { throw failure }
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
        return (url, json["id"] as? String ?? "")
    }

    /// Notion takes a hundred children in a request.
    nonisolated static func batches<T>(_ items: [T], of size: Int = 100) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    private func append(_ children: [[String: Any]], toPage id: String, token: String) async throws {
        guard UUID(uuidString: id) != nil,
              let url = URL(string: "https://api.notion.com/v1/blocks/\(id)/children") else {
            throw NotionError.decodingFailed("Missing 'id' field.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["children": children])
        // Only «too many requests» is asked again: that one is known not to
        // have been taken, and anything else may put the same lines in twice.
        var attempt = 1
        while true {
            let (responseData, response) = try await urlSession.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (200..<300).contains(status) { return }
            if status == 429, attempt < 3 {
                attempt += 1
                try await Task.sleep(for: .seconds(Self.retryDelay(http?.value(forHTTPHeaderField: "Retry-After"))))
                continue
            }
            let payload = String(data: responseData, encoding: .utf8) ?? "<empty>"
            log.error("Notion append HTTP \(status): \(payload, privacy: .private)")
            throw NotionError.httpError(status, payload)
        }
    }

    /// Seconds to wait, as Notion asks; a second when it doesn't say, and
    /// not longer than a person would wait on a send.
    nonisolated static func retryDelay(_ header: String?) -> Int {
        min(max(header.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1, 1), 30)
    }

    /// A page made by this send goes to Notion's trash. False when it's
    /// still there.
    private func trash(page id: String, token: String) async -> Bool {
        guard UUID(uuidString: id) != nil, let url = URL(string: "https://api.notion.com/v1/pages/\(id)"),
              let body = try? JSONSerialization.data(withJSONObject: ["archived": true]) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.httpBody = body
        // Often right after a «too many requests»; asking twice for the
        // trash does no harm, so whatever failed is asked again.
        for attempt in 1...3 {
            let response = try? await urlSession.data(for: request).1 as? HTTPURLResponse
            let status = response?.statusCode ?? 0
            if (200..<300).contains(status) { return true }
            log.error("Notion trash HTTP \(status)")
            if attempt < 3 {
                try? await Task.sleep(for: .seconds(Self.retryDelay(response?.value(forHTTPHeaderField: "Retry-After"))))
            }
        }
        return false
    }

    /// What a send on its own says when it fails.
    nonisolated static func autoSendFailure(_ error: Error) -> String {
        if case NotionError.incompletePage = error { return error.localizedDescription }
        return String(localized: "Auto-send to Notion failed — retry from Library")
    }

    // MARK: - Helpers

    /// Keychain access is synchronous; wrap to keep this code async-friendly.
    private func readCredential(_ key: String) async -> String? {
        KeychainStore.get(account: key)
    }

    /// Notion parent kind ("page", "database" or "meeting_notes") read off the
    /// `AppSettings` singleton on the main actor. Defaults to
    /// "page" when the value's missing — matches the historical
    /// behaviour before this setting existed.
    @MainActor
    private func readParentKind() -> String {
        UserDefaults.standard.string(forKey: "daisy.notionParentKind") ?? "page"
    }

    /// Bullets and what's under them as lines, broken where a block would
    /// pass Notion's 2000 characters.
    nonisolated static func outlineParagraphs(_ bullets: [SummaryBullet], limit: Int = 1900) -> [String] {
        func lines(_ bullets: [SummaryBullet], _ level: Int) -> [String] {
            bullets.flatMap {
                [String(repeating: "    ", count: level) + "• " + $0.text] + lines($0.children, level + 1)
            }
        }
        var out: [String] = []
        for line in lines(bullets, 0) {
            if let last = out.last, last.count + line.count + 1 <= limit {
                out[out.count - 1] = last + "\n" + line
            } else {
                out.append(line)
            }
        }
        return out
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

            // The view the card shows: a template's sections (backlog 35)
            // when there is one, the outline otherwise. A section is as few
            // blocks as it fits: Notion takes a hundred in a request.
            for section in summary.templated?.sections ?? summary.sections {
                children.append(heading2(section.title))
                for part in Self.outlineParagraphs(section.bullets) {
                    children.append(paragraph(part))
                }
            }

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
