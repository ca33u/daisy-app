//
//  ActionRouting.swift
//  Daisy
//
//  Backlog 24 М-14: one next step, sent where the whole session can be
//  sent — Notion, and every destination in Connections (a Linear issue, a
//  Slack message, a webhook, another MCP server). No new configuration:
//  the destination's own template gets the step in place of the session —
//  its title is the step, its body who and by when, the meeting, the time
//  and the lines around it. The step's status records where it went and
//  the link the destination answered with, if any. The same, for agents,
//  as the MCP tool `route_action_to_destination`.
//

import AppKit
import DaisyCore
import Foundation

@MainActor
enum ActionRouting {
    /// One step, as it goes out.
    struct Step: Equatable {
        let index: Int
        let text: String
        let owner: String?
        let due: String?
        let timecode: String?
        let excerpt: String
        let meetingTitle: String
        let meetingDate: Date

        /// «Owner: Maria», «Due: 3 Oct», «From: Weekly, 29 Sep», «At: 14:20», then the lines.
        var bodyLines: [String] {
            var lines: [String] = []
            if let owner, !["me", "i", "я"].contains(owner.lowercased()) {
                lines.append(String(localized: "Owner: \(owner)"))
            }
            if let due, let date = ActionItem.date(from: due) {
                lines.append(String(localized: "Due: \(date.formatted(date: .abbreviated, time: .omitted))"))
            }
            let day = meetingDate.formatted(date: .abbreviated, time: .omitted)
            lines.append(String(localized: "From the meeting: \(meetingTitle), \(day)"))
            if let timecode { lines.append(String(localized: "At: \(timecode)")) }
            if !excerpt.isEmpty { lines += ["", excerpt] }
            return lines
        }
    }

    /// The step at `index` of a session: its typed record when the file
    /// has one (owner, due), else read from its string; the transcript
    /// lines nearest its words.
    static func step(_ index: Int, of session: StoredSession) -> Step? {
        let strings = session.summary?.actionItems ?? []
        guard strings.indices.contains(index) else { return nil }
        let item = typedAction(index, in: session.directoryURL) ?? ActionItem.legacy(strings[index], index: index)
        let (excerpt, timecode) = Self.excerpt(for: item.text, in: session.transcriptText)
        return Step(index: index, text: item.text, owner: item.owner, due: item.due, timecode: timecode,
                    excerpt: excerpt, meetingTitle: session.title, meetingDate: session.startedAt)
    }

    /// Every step of a session as records: the file's typed ones, else
    /// read from the strings as every reader does.
    static func actions(of session: StoredSession) -> [ActionItem] {
        struct File: Decodable { let actions: [ActionItem]? }
        if let data = try? Data(contentsOf: session.directoryURL.appendingPathComponent("summary.json")),
           let typed = (try? JSONDecoder().decode(File.self, from: data))?.actions, !typed.isEmpty {
            return typed
        }
        return (session.summary?.actionItems ?? []).enumerated().map { ActionItem.legacy($1, index: $0) }
    }

    // MARK: - М-1: the recap, from the Mac

    /// Mail's compose window with the recap for the people who were there
    /// (the event's addresses — this Mac's calendar leaves the owner out).
    /// Once Mail takes it, every step nothing else has claimed is marked
    /// as gone to the participants, as on the phone.
    static func composeRecap(for session: StoredSession) {
        let language = MeetingRecap.Language(locale: session.locale)
        let actions = actions(of: session)
        guard let service = NSSharingService(named: .composeEmail) else { return }
        service.recipients = MeetingRecap.recipients(eventEmails: session.meetingAttendeeEmails, ownEmails: [], leadEmails: [])
        service.subject = MeetingRecap.subject(title: session.title, date: session.startedAt, language: language)
        let delegate = RecapShareDelegate(directory: session.directoryURL, count: actions.count)
        service.delegate = delegate
        RecapShareDelegate.current = delegate
        service.perform(withItems: [MeetingRecap.body(actions: actions, language: language)])
    }

    static func stepsText(of session: StoredSession) -> String {
        MeetingRecap.stepsText(actions: actions(of: session), language: MeetingRecap.Language(locale: session.locale))
    }

    /// The file's own typed record of the step, read without this app's
    /// summary model (which does not know `actions`).
    nonisolated static func typedAction(_ index: Int, in directory: URL) -> ActionItem? {
        struct File: Decodable { let actions: [ActionItem]? }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("summary.json")),
              let file = try? JSONDecoder().decode(File.self, from: data),
              let actions = file.actions, actions.indices.contains(index) else { return nil }
        return actions[index]
    }

    /// The transcript lines nearest the step's own words, two either side,
    /// and the time of the best one.
    nonisolated static func excerpt(for text: String, in transcript: String) -> (String, String?) {
        let lines = transcript.components(separatedBy: "\n").filter { $0.hasPrefix("**[") }
        let words = Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 })
        guard !lines.isEmpty, !words.isEmpty else { return ("", nil) }
        let scored = lines.enumerated().map { index, line -> (Int, Int) in
            let lineWords = Set(line.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            return (index, words.intersection(lineWords).count)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return ("", nil) }
        let range = max(0, best.0 - 2)...min(lines.count - 1, best.0 + 2)
        let excerpt = lines[range].map { $0.replacingOccurrences(of: "**", with: "") }.joined(separator: "\n")
        let line = lines[best.0]
        let timecode = line.dropFirst(3).split(separator: " ").first.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]·*"))
        return (excerpt, timecode)
    }

    /// The destination's template, filled with the step instead of the
    /// session. Same keys as the session's, so every template works as is.
    static func placeholders(for step: Step, session: StoredSession) -> [(key: String, value: String)] {
        let body = step.bodyLines.joined(separator: "\n")
        return [
            ("{{actionItemsBullets}}", "- " + step.text),
            ("{{clientFollowUp}}", ""),
            ("{{actionItems}}", step.text),
            ("{{transcript}}", step.excerpt),
            ("{{summary}}", body),
            ("{{folder}}", session.folderSlug),
            ("{{locale}}", session.locale),
            ("{{title}}", step.text),
            ("{{date}}", ISO8601DateFormatter().string(from: session.startedAt)),
        ]
    }

    /// Where a step can go: Notion when it is set up, then every enabled
    /// destination in Connections.
    struct Destination: Identifiable, Hashable {
        let id: String
        let name: String
        let integration: MCPIntegration?
    }

    static var destinations: [Destination] {
        var out: [Destination] = []
        if AppSettings.notionConfigured { out.append(Destination(id: "notion", name: "Notion", integration: nil)) }
        out += MCPIntegrationStore.shared.enabledIntegrations.map {
            Destination(id: $0.id.uuidString, name: $0.name, integration: $0)
        }
        return out
    }

    /// Sends, and on success writes `sent: <destination>` with the link the
    /// destination answered with. Returns that link (or "" with none) — nil
    /// when it did not go.
    @discardableResult
    static func send(step index: Int, of session: StoredSession, to destination: Destination) async -> String? {
        guard let step = step(index, of: session) else { return nil }
        let link: String?
        if let integration = destination.integration {
            let result = await MCPDispatcher.send(integration, placeholders: placeholders(for: step, session: session))
            guard result.ok else { return nil }
            link = result.link
        } else {
            do {
                let url = try await NotionExporter.shared.createActionPage(
                    title: String(localized: "Step: \(step.text)"), lines: step.bodyLines)
                ToastCenter.shared.show(String(localized: "Sent to Notion"), style: .success)
                link = url.absoluteString
            } catch {
                ToastCenter.shared.show("Notion: \(error.localizedDescription)", style: .error)
                return nil
            }
        }
        ActionStatusWriter.set(.init(state: .sent, destination: destination.name, identifier: link),
                               forStep: index, in: session.directoryURL)
        return link ?? ""
    }
}

/// Held while Mail's compose window is open; marks the recap sent when
/// Mail took it.
private final class RecapShareDelegate: NSObject, NSSharingServiceDelegate {
    @MainActor static var current: RecapShareDelegate?
    let directory: URL
    let count: Int

    init(directory: URL, count: Int) {
        self.directory = directory
        self.count = count
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        let directory = directory, count = count
        Task { @MainActor in
            ActionStatusWriter.markRecapSent(steps: count, in: directory)
            RecapShareDelegate.current = nil
        }
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        Task { @MainActor in RecapShareDelegate.current = nil }
    }
}
