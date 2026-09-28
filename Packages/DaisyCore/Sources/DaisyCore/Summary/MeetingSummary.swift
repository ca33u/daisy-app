//
//  MeetingSummary.swift
//  DaisyCore
//
//  Copied from daisy-app/Daisy/Summarizer.swift @ 1.0.7.72, 2026-09-19
//  (backlog 4 B-2): the `summary.json` shape, session-format.md §4.
//  All four keys are always written, including empty arrays/strings;
//  unknown keys are ignored on read.
//

import Foundation

public nonisolated struct MeetingSummary: Codable, Sendable, Equatable {
    /// One-sentence lede — what the meeting was about.
    public let summary: String
    /// Topical outline; empty for legacy files, then `summary` is the whole text.
    public let sections: [SummarySection]
    /// Imperative next steps, optionally "Owner: …" prefixed.
    public let actionItems: [String]
    /// Ready-to-send follow-up; empty for purely internal meetings.
    public let clientFollowUp: String
    /// Backlog 22 Д-0: the same next steps as records — kind, owner, due,
    /// people, confidence, and the status an action gave them. Written
    /// beside `actionItems`, never instead of it; derived from the strings
    /// when a file does not carry it.
    public private(set) var actions: [ActionItem]

    public init(summary: String, sections: [SummarySection] = [], actionItems: [String], clientFollowUp: String,
                actions: [ActionItem]? = nil) {
        self.summary = summary
        self.sections = sections
        self.actionItems = actionItems
        self.clientFollowUp = clientFollowUp
        self.actions = actions ?? actionItems.enumerated().map { ActionItem.legacy($1, index: $0) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(String.self, forKey: .summary)
        sections = try c.decodeIfPresent([SummarySection].self, forKey: .sections) ?? []
        actionItems = try c.decodeIfPresent([String].self, forKey: .actionItems) ?? []
        clientFollowUp = try c.decodeIfPresent(String.self, forKey: .clientFollowUp) ?? ""
        let typed = (try? c.decodeIfPresent([ActionItem].self, forKey: .actions)) ?? nil
        actions = typed ?? actionItems.enumerated().map { ActionItem.legacy($1, index: $0) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(summary, forKey: .summary)
        try c.encode(sections, forKey: .sections)
        try c.encode(actionItems, forKey: .actionItems)
        try c.encode(clientFollowUp, forKey: .clientFollowUp)
        try c.encode(actions, forKey: .actions)
    }

    /// The same summary with one action's status changed.
    public func setting(_ status: ActionItem.Status?, forAction id: String) -> MeetingSummary {
        var copy = self
        if let index = copy.actions.firstIndex(where: { $0.id == id }) { copy.actions[index].status = status }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case summary, sections, actionItems, clientFollowUp, actions
    }
}

public nonisolated struct SummarySection: Codable, Sendable, Equatable {
    public let title: String
    public let bullets: [SummaryBullet]

    public init(title: String, bullets: [SummaryBullet]) {
        self.title = title
        self.bullets = bullets
    }
}

public nonisolated struct SummaryBullet: Codable, Sendable, Equatable {
    public let text: String
    public let children: [SummaryBullet]

    public init(text: String, children: [SummaryBullet] = []) {
        self.text = text
        self.children = children
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        children = try c.decodeIfPresent([SummaryBullet].self, forKey: .children) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(children, forKey: .children)
    }

    private enum CodingKeys: String, CodingKey {
        case text, children
    }
}

/// `summary.json` on disk (§4): atomic writes, never over an existing
/// file — its absence is the only signal that a summary is still owed.
public nonisolated enum SummaryStore {
    public static let fileName = "summary.json"

    public static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    public static func exists(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(in: directory).path)
    }

    public static func read(from directory: URL) -> MeetingSummary? {
        guard let data = try? Data(contentsOf: url(in: directory)) else { return nil }
        return try? JSONDecoder().decode(MeetingSummary.self, from: data)
    }

    public enum WriteError: Error { case alreadyExists }

    /// Backlog 22 Д-1: an action's status, written back into the file —
    /// the one place the phone and the Mac both read.
    @discardableResult
    public static func setStatus(_ status: ActionItem.Status?, forAction id: String, in directory: URL) -> MeetingSummary? {
        guard let summary = read(from: directory) else { return nil }
        let updated = summary.setting(status, forAction: id)
        try? write(updated, to: directory, replacing: true)
        return updated
    }

    /// Бэклог 15 П-3: `replacing` is how "Re-summarize" gets past the
    /// guard below. The guard exists so a retry after a crash cannot
    /// silently overwrite a good summary; a person asking for a new one
    /// is the one case where overwriting is the request.
    public static func write(_ summary: MeetingSummary, to directory: URL, replacing: Bool = false) throws {
        let target = url(in: directory)
        if !replacing {
            guard !FileManager.default.fileExists(atPath: target.path) else { throw WriteError.alreadyExists }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(to: target, options: .atomic)
    }
}
