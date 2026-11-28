// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  GoogleCalendarService.swift
//  Daisy
//
//  REST client for Google Calendar API v3. Fetches upcoming events
//  from the user's primary calendar, maps them into `DaisyMeeting`
//  (same struct EventKit projects into) so downstream consumers
//  don't care about the source. Uses `GoogleAccountStore` for token
//  freshness — never holds raw credentials itself.
//
//  Scope: this MVP fetches `/calendars/primary/events` only. Users
//  with multiple Google calendars (work + personal + family +
//  holidays-subscribed) will see only their primary calendar's
//  events. Multi-calendar UI is a backlog item — see daisy.md
//  Phase 8 backlog.
//
//  ─── Sync model ──────────────────────────────────────────────
//
//  We pull on-demand: `CalendarService` (the multiplexer) calls
//  `fetchUpcomingEvents(...)` on its 15s tick AND when EventKit
//  notifies us of a change. No webhook / push subscription — the
//  Google Calendar push notification flow requires a public
//  HTTPS endpoint which a local Mac app obviously can't expose.
//

import Foundation
import os

@MainActor
final class GoogleCalendarService {
    static let shared = GoogleCalendarService()

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "GoogleCalendar")
    private let baseURL = URL(string: "https://www.googleapis.com/calendar/v3")!
    /// Two ISO-8601 parsers — `withInternetDateTime` handles the
    /// `2026-05-19T14:00:00Z` / `2026-05-19T14:00:00-07:00` shapes,
    /// `withFractionalSeconds` handles Google's sometimes-emitted
    /// `2026-05-19T14:00:00.000-07:00`. Try plain first, fall back
    /// to fractional. Skipping the fractional flag in plain mode is
    /// required because `ISO8601DateFormatter` rejects a missing
    /// `.000` when it expects fractional seconds.
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parse a Google-emitted `dateTime` string with either of the
    /// two formatters. Returns nil only if BOTH fail.
    private func parseDate(_ s: String) -> Date? {
        if let d = isoFormatter.date(from: s) { return d }
        return isoFormatterFractional.date(from: s)
    }

    private init() {}

    // MARK: - Public fetch

    /// Fetch upcoming events from the user's primary calendar in the
    /// `[now, now+hours]` window. Returns `[]` if not connected
    /// (rather than throwing) so the multiplexer can no-op cleanly
    /// when the user hasn't linked Google yet.
    func fetchUpcomingEvents(lookaheadHours: Int) async throws -> [DaisyMeeting] {
        guard GoogleAccountStore.shared.isConnected else {
            return []
        }

        let now = Date()
        let end = now.addingTimeInterval(TimeInterval(lookaheadHours * 3600))
        let calendarColor = "#4285F4" // Google blue — placeholder; primary calendar's actual colour is in calendarList which we don't fetch yet.

        var components = URLComponents(url: baseURL.appendingPathComponent("/calendars/primary/events"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: isoFormatter.string(from: now)),
            URLQueryItem(name: "timeMax", value: isoFormatter.string(from: end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "100"),
            // Skip events the user has declined — they don't belong
            // in "your upcoming meetings".
            URLQueryItem(name: "showDeleted", value: "false"),
        ]

        guard let url = components.url else {
            throw GoogleCalendarError.urlConstructionFailed
        }

        let token = try await GoogleAccountStore.shared.validAccessToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleCalendarError.invalidResponse
        }

        // 401 → access token rejected (revoked / past expiry we
        // didn't catch / clock skew). Force a refresh and retry
        // once; if it still fails, surface.
        if http.statusCode == 401 {
            log.warning("Google API returned 401, attempting fresh token + retry")
            // Invalidate cached token implicitly by waiting; the
            // store will re-derive on next call.
            let retryToken = try await GoogleAccountStore.shared.validAccessToken()
            var retry = URLRequest(url: url)
            retry.setValue("Bearer \(retryToken)", forHTTPHeaderField: "Authorization")
            retry.setValue("application/json", forHTTPHeaderField: "Accept")
            let (retryData, retryResponse) = try await URLSession.shared.data(for: retry)
            guard let retryHTTP = retryResponse as? HTTPURLResponse,
                  (200..<300).contains(retryHTTP.statusCode) else {
                let body = String(data: retryData, encoding: .utf8) ?? "no body"
                throw GoogleCalendarError.apiError(status: (retryResponse as? HTTPURLResponse)?.statusCode ?? -1, body: body)
            }
            return try parseEvents(retryData, calendarColor: calendarColor)
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            throw GoogleCalendarError.apiError(status: http.statusCode, body: body)
        }

        return try parseEvents(data, calendarColor: calendarColor)
    }

    // MARK: - JSON → DaisyMeeting projection

    private func parseEvents(_ data: Data, calendarColor: String) throws -> [DaisyMeeting] {
        let response: EventsListResponse
        do {
            response = try JSONDecoder().decode(EventsListResponse.self, from: data)
        } catch {
            throw GoogleCalendarError.parseFailed(error.localizedDescription)
        }

        var skippedAllDay = 0
        var skippedUnparseable = 0
        let mapped: [DaisyMeeting] = response.items.compactMap { event -> DaisyMeeting? in
            // Skip all-day events (those have `date` instead of
            // `dateTime`) — they're never recordable meetings.
            guard let startStr = event.start.dateTime,
                  let endStr = event.end.dateTime else {
                skippedAllDay += 1
                return nil
            }
            guard let startDate = parseDate(startStr),
                  let endDate = parseDate(endStr) else {
                skippedUnparseable += 1
                log.warning("Couldn't parse Google event dateTime: start=\(startStr, privacy: .public) end=\(endStr, privacy: .public)")
                return nil
            }

            // Detect meeting URL — prefer `hangoutLink` /
            // `conferenceData` first since those are first-party
            // Google fields, then fall back to description / location
            // text scan (third-party Zoom/Teams in a Google event).
            let (platform, meetingURL) = Self.detectMeetingURL(in: event)

            // Skip pure agenda events with no meeting URL only if
            // user didn't decline. CalendarService still wants all
            // upcoming events for the Home view (calendar dot,
            // even non-meetings). meetingURL = nil is fine, it
            // just won't auto-record.

            let attendees = (event.attendees ?? [])
                .compactMap { participant -> String? in
                    // Don't return the user themselves in the
                    // attendee list — EventKit path does the same.
                    if participant.isMe ?? false { return nil }
                    if let name = participant.displayName, !name.isEmpty {
                        return name
                    }
                    if let email = participant.email,
                       let local = email.split(separator: "@").first {
                        return String(local)
                    }
                    return nil
                }

            // Raw emails for client-tag domain inference. Same
            // self-skipping logic as the names list. Lowercase +
            // deduped so the suggestion pipeline can count domains.
            var seenEmails = Set<String>()
            let attendeeEmails = (event.attendees ?? [])
                .compactMap { participant -> String? in
                    if participant.isMe ?? false { return nil }
                    guard let raw = participant.email else { return nil }
                    let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
                    guard lower.contains("@") else { return nil }
                    return seenEmails.insert(lower).inserted ? lower : nil
                }

            return DaisyMeeting(
                externalID: event.iCalUID,
                // Google events don't have a stable local ID the
                // way EventKit does — we use the API's `id` field
                // and prefix it so a collision with EventKit's
                // localID is impossible.
                localID: "google:" + event.id,
                title: event.summary ?? "Untitled",
                startDate: startDate,
                endDate: endDate,
                location: event.location,
                notes: event.description,
                meetingURL: meetingURL,
                meetingPlatform: platform,
                calendarColorHex: calendarColor,
                attendees: attendees,
                attendeeEmails: attendeeEmails
            )
        }

        // Diagnostic: surface fetch counts in Console.app so the
        // "Google says connected but no events" case can be debugged
        // without instrumentation. Filter category by "GoogleCalendar".
        log.info("Google fetch: \(response.items.count, privacy: .public) raw → \(mapped.count, privacy: .public) parsed (\(skippedAllDay, privacy: .public) all-day skipped, \(skippedUnparseable, privacy: .public) unparseable)")
        return mapped
    }

    // MARK: - Meeting URL detection

    /// Pull a meeting URL out of a Google event. Priority:
    ///  1. `hangoutLink` — Google's native Meet field
    ///  2. `conferenceData.entryPoints` — modern Google Meet field
    ///  3. Description / location text scan — catches Zoom / Teams /
    ///     Webex links pasted in by users or by Zapier-style
    ///     integrations.
    private static func detectMeetingURL(in event: APIEvent) -> (platform: String?, url: URL?) {
        if let hangout = event.hangoutLink, let url = URL(string: hangout) {
            return ("meet", url)
        }
        for entry in event.conferenceData?.entryPoints ?? [] {
            if entry.entryPointType == "video", let uri = entry.uri, let url = URL(string: uri) {
                return ("meet", url)
            }
        }
        // Fall back to the same regex set EventKit-path uses,
        // applied to description + location strings.
        let haystacks = [event.description, event.location].compactMap { $0 }
        for text in haystacks {
            for (platform, pattern) in meetingPatterns {
                if let match = text.range(of: pattern, options: .regularExpression),
                   let url = URL(string: String(text[match])) {
                    return (platform, url)
                }
            }
        }
        return (nil, nil)
    }

    private static let meetingPatterns: [(platform: String, pattern: String)] = [
        ("zoom",    #"https?://[\w.-]*zoom\.us/(?:j|my|wc|s)/[^\s<>"']+"#),
        ("meet",    #"https?://meet\.google\.com/[a-z0-9\-]+(?:\?[^\s<>"']*)?"#),
        ("teams",   #"https?://teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet)/[^\s<>"']+"#),
        ("webex",   #"https?://[\w.-]*webex\.com/(?:meet/[^\s<>"']+|[^\s<>"']*/j\.php\?[^\s<>"']+)"#),
        ("whereby", #"https?://whereby\.com/[\w\-]+"#),
        ("jitsi",   #"https?://meet\.jit\.si/[^\s<>"']+"#),
    ]
}

// MARK: - Errors

enum GoogleCalendarError: LocalizedError {
    case urlConstructionFailed
    case invalidResponse
    case apiError(status: Int, body: String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .urlConstructionFailed:
            return "Couldn't build the Google Calendar API URL."
        case .invalidResponse:
            return "Google Calendar API returned an unexpected response."
        case .apiError(let status, let body):
            let trimmed = body.count > 200 ? String(body.prefix(200)) + "…" : body
            return "Google Calendar API error \(status): \(trimmed)"
        case .parseFailed(let msg):
            return "Couldn't parse Google Calendar response: \(msg)"
        }
    }
}

// MARK: - JSON DTOs
//
// Decoders for the subset of Google Calendar API v3 fields Daisy
// actually reads. Documented at developers.google.com/calendar/api/v3/reference/events.

private struct EventsListResponse: Decodable {
    let items: [APIEvent]
}

private struct APIEvent: Decodable {
    let id: String
    let iCalUID: String?
    let summary: String?
    let description: String?
    let location: String?
    let start: EventDateTime
    let end: EventDateTime
    let hangoutLink: String?
    let conferenceData: ConferenceData?
    let attendees: [Attendee]?
}

private struct EventDateTime: Decodable {
    /// Present for all-day events (`"2026-05-19"`).
    let date: String?
    /// Present for time-bounded events (`"2026-05-19T14:00:00+02:00"`).
    let dateTime: String?
}

private struct ConferenceData: Decodable {
    let entryPoints: [EntryPoint]?
}

private struct EntryPoint: Decodable {
    let entryPointType: String?
    let uri: String?
}

private struct Attendee: Decodable {
    let email: String?
    let displayName: String?
    /// True when this attendee is the calendar owner — we skip these
    /// so the attendee list shows the OTHER people only.
    /// Mapped from JSON key `"self"` (which would collide with the
    /// Swift `self` keyword if used directly as a property name).
    let isMe: Bool?

    private enum CodingKeys: String, CodingKey {
        case email
        case displayName
        case isMe = "self"
    }
}
