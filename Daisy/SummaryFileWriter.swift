//
//  SummaryFileWriter.swift
//  Daisy
//
//  Every write of an existing `summary.json` on the Mac goes through here
//  (2026-09-28). The phone adds `actions` beside `actionItems` — the same
//  next steps as typed records, with what each became (a calendar event,
//  a sent mail) — and this app's `MeetingSummary` does not know that key.
//  Re-encoding the file dropped it, and sync carried the stripped file
//  back to the phone: the steps and their statuses were gone.
//
//  The rule (session-format.md §4): when `actionItems` are unchanged,
//  the file's `actions` are kept as they are; when they changed, they no
//  longer describe the list and are dropped — the phone reads the new
//  strings as plain steps.
//

import Foundation

nonisolated enum SummaryFileWriter {
    static func write(_ summary: MeetingSummary, to url: URL) throws {
        let fresh = try JSONEncoder().encode(summary)
        try merged(fresh, existing: try? Data(contentsOf: url)).write(to: url, options: .atomic)
    }

    /// `fresh` with the existing file's `actions`, when the steps are the same.
    static func merged(_ fresh: Data, existing: Data?) -> Data {
        guard let existing,
              let old = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any],
              let actions = old["actions"],
              var new = (try? JSONSerialization.jsonObject(with: fresh)) as? [String: Any],
              new["actions"] == nil,
              let oldItems = old["actionItems"] as? [String],
              let newItems = new["actionItems"] as? [String],
              oldItems == newItems else { return fresh }
        new["actions"] = actions
        return (try? JSONSerialization.data(withJSONObject: new, options: [.sortedKeys])) ?? fresh
    }
}
