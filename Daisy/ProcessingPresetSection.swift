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

    var body: some View {
        let selected = ProcessingPreset.matching(settings)
        Section {
            HStack(alignment: .top, spacing: 10) {
                ForEach(ProcessingPreset.allCases) { preset in
                    card(preset, isSelected: preset == selected)
                }
            }
            .padding(.vertical, 4)

            Text(selected == nil
                 ? String(localized: "Your own settings — they live under Transcription and Summary. Pick a plan to reset them.")
                 : String(localized: "The final transcript is the same full quality in every plan."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Meeting processing")
        }
    }

    private func card(_ preset: ProcessingPreset, isSelected: Bool) -> some View {
        Button {
            preset.apply(to: settings)
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
        let live: String = switch v.liveTranscript {
        case .off: String(localized: "After the meeting")
        case .lite: String(localized: "Optimal")
        case .full: String(localized: "preset.live.full", defaultValue: "Full")
        }
        let separate = String(localized: "Separate participants")
        let together = String(localized: "Don't separate participants")
        return [
            Row(label: String(localized: "Live transcript"), value: live, isOn: v.liveTranscript != .off),
            Row(label: String(localized: "Identifying participants"),
                value: v.diarizeRemoteSpeakers ? String(localized: "Each separately") : String(localized: "You and the other side"),
                isOn: v.diarizeRemoteSpeakers),
            Row(label: String(localized: "Shared mic in the room"),
                value: v.diarizeMicrophone ? separate : together,
                isOn: v.diarizeMicrophone),
            // The Summary tab's "Second pass" toggle: names and terms
            // fixed, and a guess at who each speaker is.
            Row(label: String(localized: "Transcript refinement"),
                value: v.transcriptSecondPass ? String(localized: "Names, terms, who spoke") : String(localized: "preset.refine.off", defaultValue: "Off"),
                isOn: v.transcriptSecondPass),
        ]
    }
}
