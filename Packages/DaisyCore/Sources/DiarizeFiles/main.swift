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
//      swift run DiarizeFiles /path/a.m4a /path/b.m4a
//

import DaisyCore
import DaisyDiarization
import Foundation

let files = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
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
        for span in outcome.spans.prefix(8) {
            print(String(format: "    %@  %.1f–%.1f с", span.speakerId, span.startSec, span.endSec))
        }
    } catch {
        print("\(url.lastPathComponent): \(error.localizedDescription)")
    }
}
