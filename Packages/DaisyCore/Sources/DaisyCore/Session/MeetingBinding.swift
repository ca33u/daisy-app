//
//  MeetingBinding.swift
//  DaisyCore
//
//  backlog 5 E-4: the calendar event a recording belongs to, as the
//  contract writes it (session-format.md §3.1 `daisy_event_*`) —
//  copied key for key from daisy-app/Daisy/MarkdownExporter.swift
//  @ 1.0.7.72 so the Mac sees the same binding on a phone session.
//  Detection of the meeting link is the Mac's `CalendarService
//  .meetingPatterns`, verbatim; it is plain string work, so it lives
//  here and the app only projects EKEvent fields into strings.
//

import Foundation

public nonisolated struct MeetingBinding: Codable, Sendable, Hashable {
    /// Provider-side id (`calendarItemExternalIdentifier`) — survives
    /// re-sync and matches across devices.
    public var externalID: String?
    /// This device's `eventIdentifier`.
    public var localID: String
    public var title: String
    public var startDate: Date
    /// "zoom" / "meet" / "teams" / "webex" / "whereby" / "jitsi".
    public var platform: String?
    public var attendees: [String]
    public var attendeeEmails: [String]

    public init(externalID: String?, localID: String, title: String, startDate: Date,
                platform: String?, attendees: [String], attendeeEmails: [String]) {
        self.externalID = externalID
        self.localID = localID
        self.title = title
        self.startDate = startDate
        self.platform = platform
        self.attendees = attendees
        self.attendeeEmails = attendeeEmails
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// The `daisy_event_*` lines, in the Mac's order.
    public func frontmatterLines() -> [String] {
        var lines: [String] = []
        if let externalID {
            lines.append("daisy_event_external_id: \(SessionDocument.yamlQuote(externalID))")
        }
        lines.append("daisy_event_local_id: \(SessionDocument.yamlQuote(localID))")
        lines.append("daisy_event_title: \(SessionDocument.yamlQuote(title))")
        lines.append("daisy_event_start: \(Self.iso.string(from: startDate))")
        if let platform {
            lines.append("daisy_event_platform: \(platform)")
        }
        if !attendees.isEmpty {
            lines.append("daisy_event_attendees: [\(attendees.map(SessionDocument.yamlQuote).joined(separator: ", "))]")
        }
        if !attendeeEmails.isEmpty {
            lines.append("daisy_event_emails: [\(attendeeEmails.map(SessionDocument.yamlQuote).joined(separator: ", "))]")
        }
        return lines
    }

    public static func parse(_ p: ParsedFrontmatter) -> MeetingBinding? {
        guard let localID = p["daisy_event_local_id"], let title = p["daisy_event_title"],
              let start = p["daisy_event_start"].flatMap({ iso.date(from: $0) }) else { return nil }
        return MeetingBinding(
            externalID: p["daisy_event_external_id"],
            localID: localID,
            title: title,
            startDate: start,
            platform: p["daisy_event_platform"],
            attendees: p["daisy_event_attendees"].map(SessionDocument.parseYAMLArray) ?? [],
            attendeeEmails: p["daisy_event_emails"].map(SessionDocument.parseYAMLArray) ?? []
        )
    }
}

/// Where the meeting link hides in an event, and which platform it is.
/// Order matters: location is where most Zoom invites end up, then the
/// event's own URL field, then the notes (Google Calendar dumps the
/// link there).
public nonisolated enum MeetingURLDetector {
    public static let patterns: [(platform: String, pattern: String)] = [
        ("zoom",    #"https?://[\w.-]*zoom\.us/(?:j|my|wc|s)/[^\s<>"']+"#),
        ("meet",    #"https?://meet\.google\.com/[a-z0-9\-]+(?:\?[^\s<>"']*)?"#),
        ("teams",   #"https?://teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet)/[^\s<>"']+"#),
        ("webex",   #"https?://[\w.-]*webex\.com/(?:meet/[^\s<>"']+|[^\s<>"']*/j\.php\?[^\s<>"']+)"#),
        ("whereby", #"https?://whereby\.com/[\w\-]+"#),
        ("jitsi",   #"https?://meet\.jit\.si/[^\s<>"']+"#),
    ]

    public static func detect(in haystacks: [String?]) -> (platform: String, url: URL)? {
        for text in haystacks.compactMap({ $0 }) {
            for (platform, pattern) in patterns {
                if let match = text.range(of: pattern, options: .regularExpression),
                   let url = URL(string: String(text[match])) {
                    return (platform, url)
                }
            }
        }
        return nil
    }
}
