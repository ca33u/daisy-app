//
//  main.swift — DecodeProbe
//
//  The phone showed a ~750 MB spike, shorter than a second, in some
//  passes over a long block and not others (26.09): the same 184 s of a
//  watch recording spiked with the temperature fallback off, and once
//  did not with it on. Here the same WhisperEngine runs on a file with
//  memory sampled every 10 ms and the decoder's progress recorded, so
//  the spike can be put on the audio.
//
//    DecodeProbe <model dir> <audio> <seconds> [runs] [--no-fallback]
//

import DaisyCore
import Darwin
import Foundation

nonisolated final class Timeline: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: [(t: Double, fraction: Double)] = []
    private(set) var peakMB = 0
    private(set) var peakAt = 0.0
    private(set) var baseMB = 0
    let start = Date()

    func note(fraction: Double) {
        lock.withLock { progress.append((Date().timeIntervalSince(start), fraction)) }
    }
    func sample() {
        let mb = Self.footprintMB()
        lock.withLock {
            if baseMB == 0 { baseMB = mb }
            if mb > peakMB { peakMB = mb; peakAt = Date().timeIntervalSince(start) }
        }
    }
    /// Progress around the peak: the last value before it and the first after.
    func around() -> (before: Double?, after: Double?) {
        lock.withLock {
            (progress.last(where: { $0.t <= peakAt })?.fraction, progress.first(where: { $0.t > peakAt })?.fraction)
        }
    }
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
let noFallback = arguments.contains("--no-fallback")
arguments.removeAll { $0.hasPrefix("--") }
guard arguments.count >= 3, let seconds = Double(arguments[2]) else {
    print("usage: DecodeProbe <model dir> <audio> <seconds> [runs] [--no-fallback]")
    exit(1)
}
let runs = arguments.count > 3 ? Int(arguments[3]) ?? 1 : 1
let engine = WhisperEngine(modelDirectory: URL(fileURLWithPath: arguments[0]))
engine.concurrentWorkers = 1
engine.debugWithoutFallback = noFallback
await engine.load()
guard engine.isReady else { print("model did not load"); exit(1) }
let reader = ArchiveBlockReader(urls: [URL(fileURLWithPath: arguments[1])], blockSeconds: seconds)
guard let block = reader.nextBlock() else { print("no audio"); exit(1) }
let samples = block.samples
let audioSeconds = Double(samples.count) / 16_000
print("model loaded, footprint \(Timeline.footprintMB()) MB; block \(Int(audioSeconds)) s; fallback \(noFallback ? "off" : "on")")

for run in 1...runs {
    let timeline = Timeline()
    let sampler = Task.detached {
        while !Task.isCancelled {
            timeline.sample()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    let result = try await engine.run(samples: samples) { fraction in timeline.note(fraction: fraction) }
    sampler.cancel()
    let around = timeline.around()
    func at(_ f: Double?) -> String { f.map { String(format: "%.0f s", $0 * audioSeconds) } ?? "-" }
    print(String(format: "run %d: %.0f s, base %d MB, peak %d MB (+%d) at %.1f s into the pass, decoded audio then between %@ and %@; %d segments, %d fallback(s)",
                 run, Date().timeIntervalSince(timeline.start), timeline.baseMB, timeline.peakMB, timeline.peakMB - timeline.baseMB,
                 timeline.peakAt, at(around.before), at(around.after), result.segments.count, result.fallbacks))
    for segment in result.segments {
        print(String(format: "   %6.1f–%6.1f  %@", segment.startSec, segment.endSec, String(segment.text.prefix(80))))
    }
}
