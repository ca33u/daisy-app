//
//  DayCard.swift
//  Daisy
//
//  The single "your day" surface on Home — merges what used to be three
//  separate blocks (morning-brief card, the Today/Tomorrow calendar
//  column, and the standalone pre-meeting-brief card) into one card:
//
//    HEADER   greeting / TOMORROW + "N meetings · M open items" + refresh
//    LEDE     LLM intro (MorningBriefStore — local auto / cloud consent)
//    EVENTS   each meeting row: calendar-coloured record icon · time ·
//             title; tap the icon to start recording; "Prep" disclosure
//             expands the pre-meeting brief
//             inline; open items whose SOURCE session strongly matches
//             the meeting (shared attendee email) nest under it.
//    TO CLOSE remaining open items (not tied to today's meetings).
//
//  Grouping uses PreMeetingBriefStore.matchingSessions with
//  requireStrong: true — email-only, so a "Weekly sync" title collision
//  can't hang another client's task under the wrong meeting; anything
//  ambiguous stays in TO CLOSE. All local; nothing here talks to the
//  network (the lede/brief layers keep their own consent gates).
//

import SwiftUI

struct DayCard: View {
    let events: [DaisyMeeting]
    let isTomorrow: Bool
    let settings: AppSettings
    let onOpenMeeting: (DaisyMeeting) -> Void

    @Bindable private var brief = MorningBriefStore.shared
    @Bindable private var actionItems = ActionItemStore.shared
    @Bindable private var store = SessionStore.shared

    /// Open items whose source session is older than this land in the
    /// separate "Overdue" block instead of "To close" (tunable).
    private static let overdueAfterDays = 3

    /// Width of the leading glyph column shared by the meeting record button
    /// and task checkbox, so both glyphs and their titles stay aligned.
    private static let glyphColumn: CGFloat = 20

    var body: some View {
        let grouping = makeGrouping()
        let doneToday = actionItems.doneTodayItems
        let hasAnything = !events.isEmpty || !grouping.current.isEmpty
            || !grouping.overdue.isEmpty || !doneToday.isEmpty
        if settings.morningBriefEnabled == false {
            // Brief disabled → plain agenda card (events only, no LLM/no tasks).
            if !events.isEmpty {
                card {
                    header(open: 0)
                    eventRows(grouping: grouping, showTasks: false)
                }
            }
        } else if hasAnything {
            card {
                header(open: actionItems.openCount)
                ledeBody
                if events.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .foregroundStyle(.secondary)
                        Text("No meetings today or tomorrow.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    // Separator between the lede paragraph and the agenda —
                    // only when a lede is actually showing above it.
                    if hasLede { fullBleedDivider }
                    eventRows(grouping: grouping, showTasks: true)
                }
                // Current open items not tied to a meeting — shown in full
                // (the column scrolls), newest first.
                if !grouping.current.isEmpty {
                    fullBleedDivider
                    sectionLabel("To close")
                    itemsList(grouping.current)
                }
                // Overdue: carried over from older sessions, split below so
                // today's pre-meeting tasks stay on top. Most-overdue first.
                if !grouping.overdue.isEmpty {
                    fullBleedDivider
                    sectionLabel("Overdue")
                    itemsList(grouping.overdue)
                }
                // Completed today — struck through at the very bottom;
                // cleared automatically once the day rolls over.
                if !doneToday.isEmpty {
                    fullBleedDivider
                    sectionLabel("Done")
                    itemsList(doneToday)
                }
            }
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 10))
        // Re-key on the data the brief depends on: on a cold launch the
        // card's .task can fire BEFORE the calendar + action items finish
        // loading, hit prepare()'s "nothing to brief" guard, park at
        // .unavailable, and never re-run — so the lede stayed blank even
        // once the meeting + open items appeared (Egor 2026-07-22). Keying
        // the task on their counts re-invokes prepare() when they populate;
        // prepare() is idempotent (returns early once today's lede is ready).
        // `isTomorrow` is part of the id so the evening roll-over
        // re-runs prepare() for the new day instead of leaving this
        // morning's lede above tomorrow's agenda (2026-07-26).
        .task(id: "\(events.count)-\(actionItems.openCount)-\(isTomorrow)") {
            await brief.prepare(settings: settings)
        }
    }

    /// Shared uppercase section label ("To close", "Overdue") — the same
    /// style the header greeting uses, so all card sub-headers match.
    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    /// Light full-bleed 1pt rule reused between every card section (lede ↔
    /// agenda, To close, Overdue, Done). The −16 cancels the card padding
    /// so it runs edge to edge.
    private var fullBleedDivider: some View {
        Rectangle()
            .fill(Color.daisyDivider.opacity(0.5))
            .frame(height: 1)
            .padding(.horizontal, -16)
            .padding(.vertical, 2)
    }

    /// True while an LLM lede paragraph is actually on screen — gates the
    /// lede↔agenda divider so it doesn't appear under an empty header.
    private var hasLede: Bool {
        if case .ready(let summary) = brief.ledeState { return !summary.summary.isEmpty }
        return false
    }

    private func header(open: Int) -> some View {
        HStack(spacing: 8) {
            Text(isTomorrow ? String(localized: "Tomorrow") : greeting)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            Text(countsLabel(events: events.count, open: open))
                .daisyStatLabel()
            if case .ready = brief.ledeState {
                Button {
                    Task { await brief.regenerate(settings: settings) }
                } label: {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                // ⌘R lives on the app-level "Refresh Your Day" command
                // (View menu, DaisyApp) — it triggers this same
                // regenerate PLUS a calendar refresh. A view-local
                // .keyboardShortcut here would be shadowed by the menu
                // key equivalent anyway; the help just advertises it.
                .help("Refresh the brief (⌘R)")
            }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  return String(localized: "Good morning")
        case 12..<18: return String(localized: "Your day")
        default:      return String(localized: "Your evening")
        }
    }

    private func countsLabel(events: Int, open: Int) -> String {
        var parts: [String] = []
        if events > 0 {
            parts.append(events == 1
                ? String(localized: "1 meeting")
                : String(localized: "\(events) meetings"))
        }
        if open > 0 {
            parts.append(open == 1
                ? String(localized: "1 open item")
                : String(localized: "\(open) open items"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Lede

    @ViewBuilder
    private var ledeBody: some View {
        switch brief.ledeState {
        case .generating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading your day…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready(let summary):
            if !summary.summary.isEmpty {
                Text(summary.summary)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .needsConsent(let provider):
            HStack(spacing: 8) {
                Text("Summarize your day with \(provider)? Your open items are sent to \(provider).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Generate") {
                    Task { await brief.regenerate(settings: settings) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .idle, .unavailable:
            EmptyView()
        }
    }

    // MARK: - Events + nested tasks

    @ViewBuilder
    private func eventRows(grouping: Grouping, showTasks: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(events) { event in
                let key = PreMeetingBriefStore.key(for: event)
                eventRow(event, briefable: grouping.briefable.contains(key))
                if showTasks, let tasks = grouping.byEvent[key], !tasks.isEmpty {
                    // Indent nested tasks under the event title (glyph column
                    // + the row's 8pt gap) so they read as the meeting's own.
                    itemsList(tasks)
                        .padding(.leading, Self.glyphColumn + 8)
                }
            }
        }
    }

    private func eventRow(_ event: DaisyMeeting, briefable: Bool) -> some View {
        HStack(spacing: 8) {
            // The recording action now occupies the old calendar-dot slot.
            // Its tint still comes from the meeting's calendar, preserving
            // the visual calendar cue without a second icon on the right.
            Button {
                onOpenMeeting(event)
            } label: {
                Image(systemName: "record.circle")
                    .font(.body)
                    .foregroundStyle(calendarColor(event))
                    .frame(width: Self.glyphColumn)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Open details for “\(event.title)”"))
            // Time FIRST (Egor 2026-07-25), monospaced digits so the
            // titles after it start at the same x across rows.
            Button {
                onOpenMeeting(event)
            } label: {
                HStack(spacing: 8) {
                    Text(event.startDate, style: .time)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(event.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if briefable {
                // Passive badge, not a button (Egor 2026-08-31): the brief
                // itself moved into the meeting-preparation window (next to
                // the attached plan), so this chip only signals "there is
                // prep material inside". Clicking the row opens that
                // window. Not hit-test-disabled: the tooltip needs hover,
                // and a plain Text swallows no clicks anyway.
                Text("Prep")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.daisySelectionBackground)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.daisySelectionBorder, lineWidth: 0.5)
                    )
                    .help(String(localized: "A prep brief is waiting inside — open the meeting to see it"))
            }
        }
        .frame(minHeight: 24)
        .dayRowHover()
    }

    private func calendarColor(_ event: DaisyMeeting) -> Color {
        if let hex = event.calendarColorHex, let parsed = Color(hexString: hex) {
            return parsed
        }
        return Color.daisyTextTertiary
    }

    // MARK: - Checkable items

    private func itemsList(_ items: [TrackedActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        actionItems.setDone(item, done: !item.isDone)
                    } label: {
                        Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(item.isDone ? Color.daisyHomeAccent : Color.secondary)
                            .frame(width: Self.glyphColumn)
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.text)
                            .font(.callout.weight(.medium))
                            .strikethrough(item.isDone)
                            .foregroundStyle(item.isDone ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(item.sessionTitle) · \(item.sessionDate.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .dayRowHover()
            }
        }
    }

    // MARK: - Grouping

    private struct Grouping {
        var byEvent: [String: [TrackedActionItem]] = [:]
        var current: [TrackedActionItem] = []
        var overdue: [TrackedActionItem] = []
        var briefable: Set<String> = []
    }

    /// Assign each open item to at most ONE of the displayed events —
    /// only via a STRONG (shared attendee email) session match, so title
    /// collisions can't misfile a task. Ambiguous/unmatched items stay
    /// standalone. Also computes which events can show a Prep chip
    /// (provider-aware, same rule the brief store applies).
    private func makeGrouping() -> Grouping {
        var g = Grouping()
        let now = Date()
        let open = actionItems.openItems
        // Effective-local: checks the CONFIGURED endpoint, not just the
        // provider kind — an MCP/Ollama URL pointed at a remote host
        // must NOT auto-run without the consent tap.
        let providerLocal = Summarizer.shared.providerIsEffectivelyLocal

        // Prep-chip eligibility ONLY. Task nesting under meetings was
        // removed (Egor 2026-07-23): a shared attendee email across
        // DIFFERENT meeting series mis-filed one meeting's tasks under an
        // unrelated meeting with the same person. Open items now always
        // live in their own "To close" / "Overdue" block — never nested
        // under an event. `g.byEvent` stays empty by design.
        for event in events {
            let key = PreMeetingBriefStore.key(for: event)
            let briefMatches = PreMeetingBriefStore.matchingSessions(
                for: event, in: store.sessions, now: now,
                limit: 1, requireStrong: !providerLocal
            )
            if !briefMatches.isEmpty { g.briefable.insert(key) }
        }
        // Every open item is standalone now (no per-event claiming).
        let standalone = open
        let overdueCutoff = Calendar.current.date(
            byAdding: .day, value: -Self.overdueAfterDays, to: now
        ) ?? now
        g.current = standalone.filter { $0.sessionDate >= overdueCutoff }
        g.overdue = standalone
            .filter { $0.sessionDate < overdueCutoff }
            .sorted { $0.sessionDate < $1.sessionDate }   // most-overdue first
        return g
    }
}

private extension Color {
    /// Parse a `#RRGGBB` hex string. (Named `hexString:` to avoid
    /// colliding with other file-private `Color(hex:)` helpers.)
    init?(hexString: String) {
        var str = hexString.trimmingCharacters(in: .whitespaces)
        if str.hasPrefix("#") { str.removeFirst() }
        guard str.count == 6, let value = UInt32(str, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// Subtle hover highlight for the day-card meeting + task rows. Pads out a
/// comfortable hit area, draws a faint rounded fill while hovered, then
/// negates the padding so row layout doesn't shift.
private struct DayRowHover: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .padding(.horizontal, -8)
            .padding(.vertical, -4)
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

private extension View {
    func dayRowHover() -> some View { modifier(DayRowHover()) }
}
