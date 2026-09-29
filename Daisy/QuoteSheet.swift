//
//  QuoteSheet.swift
//  Daisy
//
//  Backlog 24 М-11 on the Mac: the transcript's selection as a quote —
//  «12.09, 14:20 — Иван: …» — and, when asked, the same stretch of the
//  recording (microphone and system audio mixed) as an .m4a, at most a
//  minute. The same builder as the phone's (DaisyCore's TranscriptQuote).
//

import AppKit
import DaisyCore
import SwiftUI

struct QuoteSheet: View {
    let session: StoredSession
    /// The transcript as shown (speaker names applied).
    let transcript: String
    let selection: String

    @Environment(\.dismiss) private var dismiss
    @AppStorage("daisy.quote.voiceNoticeSeen") private var voiceNoticeSeen = false
    @State private var withAudio = false
    @State private var showVoiceNotice = false
    @State private var audioURL: URL?
    @State private var exporting = false
    @State private var failure: String?

    private var lines: [TranscriptTimeline.Segment] { Self.segments(in: transcript) }
    private var chosen: [TranscriptTimeline.Segment] { TranscriptQuote.segments(touchedBy: selection, in: lines) }

    private var quoteText: String {
        chosen.isEmpty
            ? selection.trimmingCharacters(in: .whitespacesAndNewlines)
            : TranscriptQuote.text(chosen, started: session.startedAt)
    }

    private var audioTracks: [[URL]] {
        let files = SessionAudioFiles.discover(in: session.directoryURL)
        return [files.microphone, files.system].filter { !$0.isEmpty }
    }

    private var range: ClosedRange<Double>? {
        guard let last = chosen.last, let index = lines.firstIndex(of: last) else { return nil }
        return TranscriptQuote.audioRange(chosen, next: index + 1 < lines.count ? lines[index + 1] : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share Quote").font(.headline)
            ScrollView {
                Text(quoteText)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            if !audioTracks.isEmpty, let range {
                Toggle(isOn: $withAudio) {
                    Text(range.upperBound - range.lowerBound >= TranscriptQuote.maxAudioSeconds
                         ? String(localized: "With the audio — the first minute of it")
                         : String(localized: "With the audio — \(Int(range.upperBound - range.lowerBound)) s"))
                }
                .onChange(of: withAudio) { _, on in
                    if on && !voiceNoticeSeen { showVoiceNotice = true }
                    if on { Task { await export(range) } } else { audioURL = nil }
                }
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(quoteText, forType: .string)
                    ToastCenter.shared.show(String(localized: "Quote copied"), style: .success)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if withAudio {
                    if let audioURL {
                        ShareLink(item: audioURL, message: Text(quoteText)) { Text("Share…") }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    ShareLink(item: quoteText) { Text("Share…") }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .alert("You’re sharing someone else’s voice", isPresented: $showVoiceNotice) {
            Button("OK") { voiceNoticeSeen = true }
            Button("Without the audio", role: .cancel) { withAudio = false }
        } message: {
            Text("Make sure the people you recorded would be fine with it.")
        }
    }

    private func export(_ range: ClosedRange<Double>) async {
        exporting = true
        defer { exporting = false }
        let name = "\(session.title.prefix(40)) \(Int(range.lowerBound) / 60)-\(String(format: "%02d", Int(range.lowerBound) % 60)).m4a"
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try await TranscriptQuote.exportAudio(tracks: audioTracks, range: range, to: url)
            audioURL = url
            failure = nil
        } catch {
            failure = error.localizedDescription
            withAudio = false
        }
    }

    /// `**[m:ss · Name]** text` lines of the transcript, in order.
    nonisolated static func segments(in transcript: String) -> [TranscriptTimeline.Segment] {
        let pattern = try! NSRegularExpression(pattern: #"^\*\*\[([0-9:]+) · ([^\]]+)\]\*\*\s*(.*)$"#, options: .anchorsMatchLines)
        let ns = transcript as NSString
        return pattern.matches(in: transcript, range: NSRange(location: 0, length: ns.length)).map { match in
            let stamp = ns.substring(with: match.range(at: 1))
            let seconds = stamp.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
            return TranscriptTimeline.Segment(startSec: seconds, speaker: ns.substring(with: match.range(at: 2)),
                                              text: ns.substring(with: match.range(at: 3)),
                                              rawLine: ns.substring(with: match.range))
        }
    }
}
