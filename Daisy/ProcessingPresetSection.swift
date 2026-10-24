//
//  ProcessingPresetSection.swift
//  Daisy
//
//  The «Обработка встреч» section in Settings → Meetings: three plans
//  side by side, each with the same lines, so the difference reads
//  across a row instead of from four separate tabs. See ProcessingPreset.
//
//  S2 (Egor 24.10.2026): the rows a plan speaks for wear a «по плану»
//  badge (`PlanBadge`) while the settings match it; a hand change there
//  turns the cards to «Свой», a fourth card that links to those rows.
//

import SwiftUI

struct ProcessingPresetSection: View {
    @Bindable var settings: AppSettings
    /// The plan waiting for «Переключить»: a plan rewrites settings the
    /// person may have tuned by hand, and one stray click on a card used
    /// to do it silently (Egor, 08.10.2026).
    @State private var pending: ProcessingPreset?

    var body: some View {
        let selected = ProcessingPreset.matching(settings)
        Section {
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(ProcessingPreset.allCases) { preset in
                        card(preset, isSelected: preset == selected)
                    }
                }
                // No plan's rules hold: the fourth state, said where the
                // eye lands, with the way back to what was changed.
                if selected == nil {
                    customCard
                }
            }
            .padding(.vertical, 4)
            .settingsRow(.processingPlan)
            .confirmationDialog(
                pending.map { String(localized: "Switch to “\($0.title)”?") } ?? "",
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible,
                presenting: pending
            ) { preset in
                Button("Switch") { preset.apply(to: settings) }
                Button("Cancel", role: .cancel) {}
            } message: { preset in
                Text(changes(to: preset, from: selected).joined(separator: "\n"))
            }

            // Separate from the plans: Economy turns it on, nothing turns
            // it off but this switch.
            Toggle(isOn: $settings.deferProcessingOnBattery) {
                Text("Process meetings later, on a charger")
                Text("On battery or in Low Power Mode, a meeting keeps its live transcript; the final transcript, speakers and summary come once the Mac is plugged in. “Process now” on the meeting does it at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .settingsRow(.processLaterOnCharger)

            Text("The final transcript is the same full quality in every plan.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Meeting processing")
        }
    }

    private func card(_ preset: ProcessingPreset, isSelected: Bool) -> some View {
        Button {
            // Nothing would change → no question to ask. The ticked card
            // still asks when Economy's side effect was undone by hand
            // (processing on battery back on): clicking it redoes it.
            if changes(to: preset, from: ProcessingPreset.matching(settings)).isEmpty {
                preset.apply(to: settings)
            } else {
                pending = preset
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(preset.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.daisyTextPrimary)
                    Spacer(minLength: 4)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.daisyAccent)
                    }
                }
                Text(preset.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // Same height in all three, so the rows below line up.
                    .frame(minHeight: 44, alignment: .top)
                Divider()
                ForEach(rows(for: preset), id: \.label) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.label)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(row.value)
                            .font(.caption)
                            .foregroundStyle(row.isOn ? Color.daisyTextPrimary : Color.daisyTextSecondary)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.daisySelectionBackground : Color.daisyBgElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.daisySelectionBorder : Color.daisyDivider,
                                  lineWidth: isSelected ? 1 : 0.5)
            )
        }
        .buttonStyle(.plain)
        // Read once as one control: title, description, the four rows.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// «Свой»: the settings keep no plan's rules. Not a button — there is
    /// nothing to pick; the links lead to the rows a plan would set.
    private var customCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(String(localized: "plan.custom", defaultValue: "Custom"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.daisyTextPrimary)
                Spacer(minLength: 4)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.daisyAccent)
            }
            Text("Changed by hand — these are the rows a plan sets")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)],
                      alignment: .leading, spacing: 4) {
                ForEach(customLinks, id: \.self) { row in
                    // A row on another tab says which, as search does.
                    Button(row.tab == .meetings ? row.title : "\(row.title) · \(row.tab.title)") {
                        AppNavigation.shared.openInSettings(row.tab, row: row)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.daisySelectionBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.daisySelectionBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isSelected)
    }

    /// The rows a plan speaks for — the interval only while captures are
    /// on, since its row is hidden otherwise.
    private var customLinks: [SettingsRow] {
        ProcessingPreset.Setting.allCases
            .filter { $0 != .screenshotInterval || settings.screenshotsEnabled }
            .map(\.row)
    }

    /// What picking `preset` would change, one line each, in the cards'
    /// own words: «Живая транскрипция: Полная → Оптимальная».
    private func changes(to preset: ProcessingPreset, from current: ProcessingPreset?) -> [String] {
        let v = preset.values
        var lines: [String] = []
        func line(_ label: String, _ old: String, _ new: String) {
            if old != new { lines.append("\(label): \(old) → \(new)") }
        }
        line(String(localized: "Live transcript"),
             ProcessingPreset.liveLabel(settings.liveTranscriptionTier), ProcessingPreset.liveLabel(v.liveTranscript))
        line(String(localized: "Identifying participants"),
             ProcessingPreset.participantsLabel(settings.diarizeRemoteSpeakers), ProcessingPreset.participantsLabel(v.diarizeRemoteSpeakers))
        line(String(localized: "Shared mic in the room"),
             ProcessingPreset.roomLabel(settings.diarizeMicrophone), ProcessingPreset.roomLabel(v.diarizeMicrophone))
        line(String(localized: "Transcript refinement"),
             ProcessingPreset.refineLabel(settings.transcriptSecondPass), ProcessingPreset.refineLabel(v.transcriptSecondPass))
        switch preset {
        case .economy:
            if settings.screenshotsEnabled { lines.append(String(localized: "Screenshots will be turned off.")) }
            if !settings.deferProcessingOnBattery {
                lines.append(String(localized: "Meetings will be processed later, on a charger."))
            }
        case .balanced:
            if settings.screenshotsEnabled,
               settings.screenshotIntervalSec < ProcessingPreset.balancedScreenshotIntervalSec {
                lines.append(String(localized: "Screenshots: every 2 minutes at most."))
            }
        case .maximum:
            break
        }
        if current == nil, !lines.isEmpty {
            lines.append(String(localized: "Your own settings are replaced — you can change them again in the rows marked “set by plan”."))
        }
        return lines
    }

    private struct Row {
        let label: String
        let value: String
        let isOn: Bool
    }

    /// The four lines every card shows, in the same order. Wording by
    /// Egor (07.10.2026). Keyed where a plain key is already taken with
    /// another form — "Full" is «Полный» and "Off" is «Выкл» elsewhere.
    private func rows(for preset: ProcessingPreset) -> [Row] {
        let v = preset.values
        return [
            Row(label: String(localized: "Live transcript"), value: ProcessingPreset.liveLabel(v.liveTranscript), isOn: v.liveTranscript != .off),
            Row(label: String(localized: "Identifying participants"),
                value: ProcessingPreset.participantsLabel(v.diarizeRemoteSpeakers),
                isOn: v.diarizeRemoteSpeakers),
            Row(label: String(localized: "Shared mic in the room"),
                value: ProcessingPreset.roomLabel(v.diarizeMicrophone),
                isOn: v.diarizeMicrophone),
            Row(label: String(localized: "Screenshots"),
                value: preset == .economy ? String(localized: "preset.screens.off", defaultValue: "Off")
                    : preset == .balanced ? String(localized: "Every 2 min at most")
                    : String(localized: "preset.screens.asIs", defaultValue: "As they are"),
                isOn: preset != .economy),
            // The AI tab's "Second pass" toggle: names and terms fixed,
            // and a guess at who each speaker is.
            Row(label: String(localized: "Transcript refinement"),
                value: ProcessingPreset.refineLabel(v.transcriptSecondPass),
                isOn: v.transcriptSecondPass),
        ]
    }
}

/// «по плану» beside a row a processing plan speaks for, while the
/// settings keep that plan's rules; the tooltip names the plan. A hand
/// change to the row breaks the match, the badge goes and the plan cards
/// say «Свой» — the plan shown is always `ProcessingPreset.matching`.
struct PlanBadge: View {
    let setting: ProcessingPreset.Setting
    let settings: AppSettings

    init(_ setting: ProcessingPreset.Setting, settings: AppSettings) {
        self.setting = setting
        self.settings = settings
    }

    var body: some View {
        if let plan = ProcessingPreset.matching(settings), plan.owns(setting) {
            let help = String(localized: "Set by the “\(plan.title)” plan")
            Text("set by plan")
                .font(.caption2)
                .foregroundStyle(Color.daisyTextSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.daisyTextSecondary.opacity(0.12)))
                .fixedSize()
                .help(help)
                .accessibilityLabel(help)
        }
    }
}
