//
//  ProcessingPresetSection.swift
//  Daisy
//
//  The «Обработка встреч» section in Settings → General: three plans
//  side by side, each with the same four lines, so the difference reads
//  across a row instead of from four separate tabs. See ProcessingPreset.
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
            if selected == nil {
                // No card is ticked — say so where the eye lands, not only
                // in the caption under the switch.
                Label {
                    Text("Your own settings — none of the plans. Picking one replaces them.")
                } icon: {
                    Image(systemName: "slider.horizontal.3")
                }
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(ProcessingPreset.allCases) { preset in
                    card(preset, isSelected: preset == selected)
                }
            }
            .padding(.vertical, 4)
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
            // still asks when its side effects were undone by hand
            // (screenshots back on after Economy): clicking it redoes them.
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

    /// What picking `preset` would change, one line each, in the cards'
    /// own words: «Живая транскрипция: Полная → Оптимальная».
    private func changes(to preset: ProcessingPreset, from current: ProcessingPreset?) -> [String] {
        let v = preset.values
        var lines: [String] = []
        func line(_ label: String, _ old: String, _ new: String) {
            if old != new { lines.append("\(label): \(old) → \(new)") }
        }
        line(String(localized: "Live transcript"),
             liveLabel(settings.liveTranscriptionTier), liveLabel(v.liveTranscript))
        line(String(localized: "Identifying participants"),
             participantsLabel(settings.diarizeRemoteSpeakers), participantsLabel(v.diarizeRemoteSpeakers))
        line(String(localized: "Shared mic in the room"),
             roomLabel(settings.diarizeMicrophone), roomLabel(v.diarizeMicrophone))
        line(String(localized: "Transcript refinement"),
             refineLabel(settings.transcriptSecondPass), refineLabel(v.transcriptSecondPass))
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
            lines.append(String(localized: "Your own settings are replaced — you can tune them again under Transcription and Summary."))
        }
        return lines
    }

    private func liveLabel(_ tier: LiveTranscriptionTier) -> String {
        switch tier {
        case .off: String(localized: "After the meeting")
        case .lite: String(localized: "Optimal")
        case .full: String(localized: "preset.live.full", defaultValue: "Full")
        }
    }

    private func participantsLabel(_ on: Bool) -> String {
        on ? String(localized: "Each separately") : String(localized: "You and the other side")
    }

    private func roomLabel(_ on: Bool) -> String {
        on ? String(localized: "Separate participants") : String(localized: "Don't separate participants")
    }

    private func refineLabel(_ on: Bool) -> String {
        on ? String(localized: "Names, terms, who spoke") : String(localized: "preset.refine.off", defaultValue: "Off")
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
            Row(label: String(localized: "Live transcript"), value: liveLabel(v.liveTranscript), isOn: v.liveTranscript != .off),
            Row(label: String(localized: "Identifying participants"),
                value: participantsLabel(v.diarizeRemoteSpeakers),
                isOn: v.diarizeRemoteSpeakers),
            Row(label: String(localized: "Shared mic in the room"),
                value: roomLabel(v.diarizeMicrophone),
                isOn: v.diarizeMicrophone),
            // The Summary tab's "Second pass" toggle: names and terms
            // fixed, and a guess at who each speaker is.
            Row(label: String(localized: "Screenshots"),
                value: preset == .economy ? String(localized: "preset.screens.off", defaultValue: "Off")
                    : preset == .balanced ? String(localized: "Every 2 min at most")
                    : String(localized: "As set in Recording"),
                isOn: preset != .economy),
            Row(label: String(localized: "Transcript refinement"),
                value: refineLabel(v.transcriptSecondPass),
                isOn: v.transcriptSecondPass),
        ]
    }
}
