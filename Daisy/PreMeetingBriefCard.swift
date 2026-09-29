//
//  PreMeetingBriefCard.swift
//  Daisy
//
//  Home-screen card that shows the pre-meeting brief for the next
//  upcoming meeting that has prior history. Observes
//  `PreMeetingBriefStore` and lazily kicks off generation via `.task`.
//  Renders the brief's `MeetingSummary` as a compact outline (lede +
//  sections + open items), reusing the same data the summary UI uses.
//

import SwiftUI

struct PreMeetingBriefCard: View {
    let meeting: DaisyMeeting
    let settings: AppSettings

    @Bindable private var briefStore = PreMeetingBriefStore.shared
    /// Backlog 24 М-13: questions a past meeting carried to this one.
    @State private var carried: [CarriedQuestion] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            carriedBlock
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.daisyHomeAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyHomeAccent.opacity(0.18), lineWidth: 0.5)
        )
        // Regenerates when the meeting identity changes (a different
        // event becomes the next briefable one).
        .task(id: PreMeetingBriefStore.key(for: meeting)) {
            await briefStore.prepare(for: meeting, settings: settings)
        }
        .task(id: meeting.id) { await loadCarried() }
    }

    // MARK: - Backlog 24 М-13

    @ViewBuilder
    private var carriedBlock: some View {
        if !carried.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Open from last time")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.daisyHomeAccent)
                ForEach(carried) { question in
                    Button {
                        AppNavigation.shared.openInLibrary(question.sessionID)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "questionmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(question.text)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Text(question.meetingDate, format: .dateTime.day().month(.abbreviated))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "From “\(question.meetingTitle)” — open it"))
                }
            }
        }
    }

    private func loadCarried() async {
        let ids = Set([meeting.externalID, meeting.localID].compactMap { $0 })
        let sessions = SessionStore.shared.sessions.map { ($0.id, $0.title, $0.startedAt, $0.directoryURL) }
        carried = await Task.detached(priority: .utility) {
            CarriedQuestions.find(eventIDs: ids, in: sessions.map { (id: $0.0, title: $0.1, date: $0.2, directory: $0.3) })
        }.value
    }

    private var state: PreMeetingBriefStore.State { briefStore.state(for: meeting) }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(Color.daisyHomeAccent)
            Text("Prep for \(meeting.title)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if case .ready(let brief) = state, brief.usedOnlineResearch {
                Image(systemName: "globe")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Includes public info gathered online")
            }
            if case .ready = state {
                Button {
                    Task { await briefStore.regenerate(for: meeting, settings: settings) }
                } label: {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Regenerate brief")
            }
        }
    }

    // MARK: - Content by state

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .generating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Assembling from your past meetings…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready(let brief):
            briefBody(brief)
        case .unavailable(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed:
            HStack(spacing: 8) {
                Text("Couldn't build a brief.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await briefStore.regenerate(for: meeting, settings: settings) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        case .needsConsent(let provider):
            VStack(alignment: .leading, spacing: 8) {
                Text("Brief your last meetings with these people using \(provider). Your past notes are sent to \(provider) to build it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Generate brief") {
                    Task { await briefStore.confirmAndGenerate(for: meeting, settings: settings) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .disabled:
            // The one "can't brief" reason the user can fix right here —
            // so fix it right here rather than sending them to Settings.
            VStack(alignment: .leading, spacing: 8) {
                Text("Pre-meeting briefs are turned off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // `prepare`, not `regenerate`: turning the feature on is
                // not consent to send past notes to a cloud provider, so
                // this has to be able to land on `.needsConsent`.
                Button("Turn on") {
                    settings.preMeetingBriefEnabled = true
                    Task { await briefStore.prepare(for: meeting, settings: settings) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .noHistory:
            // Reachable when history changes under us (or the provider
            // switches to cloud, which only accepts attendee-email
            // matches). An empty card under a "Prep for …" header reads
            // as broken.
            Text("No past meetings with these people yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func briefBody(_ brief: PreMeetingBrief) -> some View {
        let s = brief.summary
        VStack(alignment: .leading, spacing: 8) {
            if !s.summary.isEmpty {
                Text(s.summary)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(s.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.daisyHomeAccent)
                    ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                        BriefBulletRow(bullet: bullet, depth: 0)
                    }
                }
            }

            if !s.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open items")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.daisyHomeAccent)
                    ForEach(Array(s.actionItems.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "circle")
                                .font(.system(size: 5))
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                            Text(item)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            footer(brief)
        }
    }

    @ViewBuilder
    private func footer(_ brief: PreMeetingBrief) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            let n = brief.sourceSessionIDs.count
            Text(n == 1 ? "From 1 past meeting" : "From \(n) past meetings")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if !brief.webSources.isEmpty {
                Text("Sources: " + brief.webSources.map(\.title).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.top, 2)
    }
}

/// Recursive bullet row for the brief outline (mirrors the summary
/// outline's nesting, but as native SwiftUI rather than markdown text).
private struct BriefBulletRow: View {
    let bullet: SummaryBullet
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: depth == 0 ? "circle.fill" : "circle")
                    .font(.system(size: depth == 0 ? 4 : 3.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                Text(bullet.text)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 12)
            ForEach(Array(bullet.children.enumerated()), id: \.offset) { _, child in
                BriefBulletRow(bullet: child, depth: depth + 1)
            }
        }
    }
}
