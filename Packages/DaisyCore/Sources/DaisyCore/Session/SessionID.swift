//
//  SessionID.swift
//  DaisyCore
//
//  The directory name IS the session id (session-format.md §1.1): an
//  ISO-8601 UTC instant to the second with every `:` replaced by `-`.
//  `make` is the Mac's algorithm verbatim (RecordingSession.swift
//  `makeSessionDirectory`, 1.0.7.72); `parse` is the Mac's
//  `SessionStore.dateFromFolderName` — both the current `Z` shape and
//  the legacy local-offset shape.
//
//  `unique(in:)` is the collision rule the contract asks new
//  implementations to apply to recordings, not only imports: two
//  sessions in the same second get `-2`, `-3`, …
//

import Foundation

public nonisolated enum SessionID {
    // ISO8601DateFormatter is documented as thread-safe but not declared
    // `Sendable` in Foundation.
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `2026-05-17T12-37-36Z` for the given instant.
    public static func make(for date: Date) -> String {
        iso.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    /// The instant a folder name encodes, or nil for a name that is not
    /// a session id (hand-made folders are still valid sessions — §2 —
    /// they just carry no date in their name). A `-2` collision suffix
    /// is accepted and ignored.
    public static func parse(_ name: String) -> Date? {
        let zRegex      = /^(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})Z(?:-\d+)?$/
        let offsetRegex = /^(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})([+-])(\d{2})-(\d{2})(?:-\d+)?$/

        if let m = name.wholeMatch(of: zRegex) {
            let restored = "\(m.1)-\(m.2)-\(m.3)T\(m.4):\(m.5):\(m.6)Z"
            return iso.date(from: restored)
        }
        if let m = name.wholeMatch(of: offsetRegex) {
            let restored = "\(m.1)-\(m.2)-\(m.3)T\(m.4):\(m.5):\(m.6)\(m.7)\(m.8):\(m.9)"
            return iso.date(from: restored)
        }
        return nil
    }

    /// `make(for:)` plus the `-2`, `-3`, … suffix until no entry — visible
    /// or hidden, file or folder — with that name exists under `base`.
    /// Hidden staging directories count as taken because the rename that
    /// publishes them will land on this very name.
    public static func unique(for date: Date, in base: URL, taken: (String) -> Bool = { _ in false }) -> String {
        let root = make(for: date)
        let fm = FileManager.default
        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: base.appendingPathComponent(name).path) || taken(name)
        }
        if !exists(root) { return root }
        var n = 2
        while exists("\(root)-\(n)") { n += 1 }
        return "\(root)-\(n)"
    }
}
