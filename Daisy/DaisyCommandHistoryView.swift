//
//  DaisyCommandHistoryView.swift
//  Daisy
//
//  The Command History (backlog 34): what was said on the Daisy key, kept
//  on this Mac as long as dictations, with what Daisy made of it. Shown
//  under the dictation history; same retention, its own Clear.
//

import AppKit
import SwiftUI

struct DaisyCommandHistorySection: View {
    @Bindable private var history = DaisyCommandHistory.shared

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        Section {
            if history.entries.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    Text("Nothing said on the Daisy key yet — holds are kept here as long as dictations")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .font(.callout)
            } else {
                ForEach(history.entries) { entry in
                    row(entry)
                }
            }
        } header: {
            HStack {
                Text("Daisy key")
                Spacer()
                if !history.entries.isEmpty {
                    Button("Clear") { history.clear() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        }
        .onAppear { history.sweepExpired() }
    }

    private func row(_ entry: DaisyCommandEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
                ToastCenter.shared.show(String(localized: "Copied"), style: .success)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.text.isEmpty ? "—" : entry.text)
                        .font(.callout)
                        .foregroundStyle(Color.daisyTextPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Text(Self.outcomeLabel(entry.outcome))
                        Text(verbatim: "·")
                        Text(Self.relativeFormatter.localizedString(for: entry.date, relativeTo: Date()))
                        if let app = entry.appName {
                            Text(verbatim: "·")
                            Text(app)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .help("Copy")
            if let url = history.audioURL(for: entry), FileManager.default.fileExists(atPath: url.path) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "waveform")
                }
                .buttonStyle(.borderless)
                .help("Show the recording in Finder")
            }
        }
    }

    static func outcomeLabel(_ outcome: String) -> String {
        switch outcome {
        case "note": return String(localized: "Saved as a note")
        case "inbox": return String(localized: "Note — project not found")
        case "rewrite": return String(localized: "Rewritten")
        case "inserted": return String(localized: "Inserted")
        case "clipboard": return String(localized: "Put on the clipboard")
        case "stopped": return String(localized: "Stopped")
        case "refined": return String(localized: "Changed the card’s text")
        case "cardUnchanged": return String(localized: "Card unchanged")
        case "silent": return String(localized: "Nothing recognized")
        case "failed": return String(localized: "Note not saved — text copied")
        default: return String(localized: "Kept as a note")
        }
    }
}
