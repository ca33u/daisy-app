//
//  main.swift
//  DiarizeFiles
//
//  Бэклог 18 Д-3. Same pinned FluidAudio, same configuration, same code
//  the phone runs — executed on the Mac, on the files the phone ran.
//
//  What this DOES settle: whether two voices in a recording are really
//  there, or whether the phone's hardware/build is producing them. What
//  it does NOT settle: a difference between this port and daisy-app's
//  own `DiarizationEngine` — that needs the app's own test host, which
//  would not launch here.
//
//      swift run DiarizeFiles /path/a.m4a [--transcript /path/transcript.md]
//
//  With a transcript, every line is printed under the voice that was
//  speaking at its second. That is the only output worth reading: "2
//  speakers" is a number, and a number cannot be wrong in a way anyone
//  notices. Split utterances can.
//

import DaisyCore
import DaisyDiarization
import Foundation

var arguments = Array(CommandLine.arguments.dropFirst())
var transcriptURL: URL?
if let flag = arguments.firstIndex(of: "--transcript"), flag + 1 < arguments.count {
    transcriptURL = URL(fileURLWithPath: arguments[flag + 1])
    arguments.removeSubrange(flag...(flag + 1))
}
let files = arguments.map { URL(fileURLWithPath: $0) }
guard !files.isEmpty else {
    print("usage: DiarizeFiles <audio> [<audio> …]")
    exit(2)
}

let diarizer = await PhoneDiarizer()
for url in files {
    guard let samples = Resampler.decodeToMono16k(urls: [url]) else {
        print("\(url.lastPathComponent): не удалось декодировать")
        continue
    }
    let seconds = Double(samples.count) / 16_000
    do {
        let started = Date()
        let outcome = try await diarizer.run(samples: samples)
        let speakers = Set(outcome.spans.map(\.speakerId)).sorted()
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "%@: %.0f с звука → %d голос(ов) [%@] за %.1f с",
                     url.lastPathComponent, seconds, speakers.count,
                     speakers.joined(separator: "/"), elapsed))
        for span in outcome.spans {
            print(String(format: "    %@  %.1f–%.1f с", span.speakerId, span.startSec, span.endSec))
        }
        if let transcriptURL, let markdown = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            print("")
            print("— текст по голосам —")
            let parsed = SessionDocument.parseFrontmatter(in: markdown)
            for line in parsed.body.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let second = Stamp.startSecond(of: String(line)) else { continue }
                // The label of the span this line starts inside; a line
                // that begins in a gap takes the nearest span that has
                // already started, which is what a reader would assume.
                let label = outcome.spans.last { $0.startSec <= second + 0.5 }?.speakerId ?? "?"
                let text = String(line).replacingOccurrences(of: "\\*\\*\\[[^\\]]*\\]\\*\\* ", with: "", options: .regularExpression)
                print(String(format: "[%@] %5.1f  %@", label, second, text))
            }
        }
    } catch {
        print("\(url.lastPathComponent): \(error.localizedDescription)")
    }
}


/// `**[m:ss · Name]** text` → the second the line starts.
enum Stamp {
    static func startSecond(of line: String) -> Double? {
        guard let open = line.firstIndex(of: "["), let dot = line.firstIndex(of: "\u{00B7}"),
              open < dot else { return nil }
        let stamp = line[line.index(after: open)..<dot].trimmingCharacters(in: .whitespaces)
        let parts = stamp.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }
}
