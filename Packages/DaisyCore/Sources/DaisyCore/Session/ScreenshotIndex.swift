//
//  ScreenshotIndex.swift
//  DaisyCore
//
//  session-format.md §2: `screenshots/001.jpg …` plus
//  `screenshots/index.json` — `{"001.jpg": 12.0}`, filename → seconds
//  into the recording (the transcript's clock, not the wall clock).
//  Mirrors the Mac's `ScreenshotFile` / `ScreenshotIndex`
//  (daisy-app/Daisy/ScreenshotCapture.swift, 1.0.7.72): same names,
//  same JSON, so a phone session's photos (backlog 6 F-2) show up in
//  the Mac's "Screenshots" section with their timecodes and nothing on
//  the Mac has to change.
//

import Foundation

public nonisolated enum ScreenshotIndex {
    public static let directoryName = "screenshots"
    public static let filename = "index.json"
    public static let writtenExtension = "jpg"
    /// Extensions recognised when READING: the Mac writes jpg, older
    /// sessions and screenshot notes may carry png.
    public static let readableExtensions: Set<String> = ["jpg", "jpeg", "png"]

    /// `<session>/screenshots`.
    public static func directory(in session: URL) -> URL {
        session.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// `001.jpg`, zero-padded to three digits (the 1000th frame simply
    /// gets four — ordering is numeric, see `frames(in:)`).
    public static func name(number: Int) -> String {
        String(format: "%03d", number) + "." + writtenExtension
    }

    /// The frame number of `001.jpg`; nil for anything that isn't a
    /// frame (`index.json`, `._001.jpg`, `001 copy.jpg`).
    /// The same, from a bare filename.
    public static func number(of file: String) -> Int? {
        number(of: URL(fileURLWithPath: file))
    }

    public static func number(of url: URL) -> Int? {
        guard readableExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty, stem.allSatisfy(\.isNumber) else { return nil }
        return Int(stem)
    }

    /// Every frame in `directory`, in numeric order.
    public static func frames(in directory: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return items
            .compactMap { url in number(of: url).map { (url, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// The next free frame number: one past the highest on disk.
    public static func nextNumber(in directory: URL) -> Int {
        (frames(in: directory).compactMap(number(of:)).max() ?? 0) + 1
    }

    public static func load(from directory: URL) -> [String: Double] {
        guard let data = try? Data(contentsOf: url(in: directory)),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return decoded
    }

    public static func write(_ offsets: [String: Double], to directory: URL) throws {
        let data = try JSONEncoder().encode(offsets)
        try data.write(to: url(in: directory), options: .atomic)
    }

    /// Save one JPEG into `<session>/screenshots/` under the next free
    /// number and stamp `offsetSeconds` in `index.json`. During a
    /// recording that is the media second; for a photo added after the
    /// recording it is the seconds between `started` and now — past
    /// `duration_sec`, which is how a reader knows it was added later
    /// (session-format.md §3.3, §7.6).
    @discardableResult
    public static func append(jpeg: Data, to session: URL, offsetSeconds: Double) throws -> URL {
        let dir = directory(in: session)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = self.name(number: nextNumber(in: dir))
        let file = dir.appendingPathComponent(name)
        try jpeg.write(to: file, options: .atomic)
        var offsets = load(from: dir)
        offsets[name] = (offsetSeconds * 10).rounded() / 10
        try write(offsets, to: dir)
        return file
    }

    /// Seconds a photo added right now carries: on the session's clock,
    /// counted from `started`.
    public static func offsetForAddingNow(started: Date, now: Date = Date()) -> Double {
        max(0, now.timeIntervalSince(started))
    }

    /// session-format.md §3.3: past the end of the recording = added later.
    public static func isAddedLater(offset: Double, durationSec: Int) -> Bool {
        durationSec > 0 && offset > Double(durationSec) + 1
    }
}
