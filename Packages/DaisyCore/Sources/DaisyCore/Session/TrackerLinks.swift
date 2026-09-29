//
//  TrackerLinks.swift
//  DaisyCore
//
//  Backlog 24 М-8: a step as a new issue in the folder's tracker, through
//  the tracker's own «new issue» page, filled in — no sign-in, nothing
//  sent by Daisy. Formats as the trackers document them (Linear:
//  linear.new, checked 29.09). One builder for the phone and the Mac.
//

import Foundation

public nonisolated enum TrackerLinks {
    public enum Tracker: String, CaseIterable, Identifiable, Sendable {
        case github, linear, jira
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .github: "GitHub"
            case .linear: "Linear"
            case .jira: "Jira"
            }
        }
    }

    public static func trackers(in project: ProjectContext?) -> [Tracker] {
        guard let project else { return [] }
        func has(_ s: String?) -> Bool { !(s ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        var out: [Tracker] = []
        if has(project.repo) { out.append(.github) }
        if has(project.linearTeam) { out.append(.linear) }
        if has(project.jiraBase), has(project.jiraProjectID) { out.append(.jira) }
        return out
    }

    /// The step, where it came from, and the lines around it with their times.
    public static func issueBody(step: String, meetingTitle: String, date: Date?, excerpt: String, russian: Bool = false) -> String {
        let locale = Locale(identifier: russian ? "ru_RU" : "en_US")
        let day = date.map { $0.formatted(.dateTime.day().month(.wide).year().locale(locale)) }
        let from = russian
            ? "Со встречи «\(meetingTitle)»" + (day.map { ", \($0)." } ?? ".")
            : "From the meeting “\(meetingTitle)”" + (day.map { ", \($0)." } ?? ".")
        var lines = [step, "", from]
        if !excerpt.isEmpty { lines += ["", excerpt] }
        return lines.joined(separator: "\n")
    }

    public static func issueURL(_ tracker: Tracker, project: ProjectContext, title: String, body: String) -> URL? {
        switch tracker {
        case .github:
            guard let repo = project.repo?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")), !repo.isEmpty else { return nil }
            var parts = URLComponents(string: "https://github.com/\(repo)/issues/new")
            parts?.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
            return parts?.url
        case .linear:
            var parts = URLComponents(string: "https://linear.new")
            parts?.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "description", value: body),
                                 URLQueryItem(name: "team", value: project.linearTeam)]
            return parts?.url
        case .jira:
            guard let base = project.jiraBase?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
                  let pid = project.jiraProjectID else { return nil }
            var parts = URLComponents(string: "\(base)/secure/CreateIssueDetails!init.jspa")
            var items = [URLQueryItem(name: "pid", value: pid)]
            if let type = project.jiraIssueType, !type.isEmpty { items.append(URLQueryItem(name: "issuetype", value: type)) }
            items += [URLQueryItem(name: "summary", value: title), URLQueryItem(name: "description", value: body)]
            parts?.queryItems = items
            return parts?.url
        }
    }
}
