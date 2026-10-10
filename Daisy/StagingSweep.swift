//
//  StagingSweep.swift
//  Daisy
//
//  Import (`AudioImporter.materialize`) and re-transcription
//  (`SessionAudioProcessing`) build a session in a hidden staging folder
//  next to the sessions and rename it into place at the end; a failure
//  removes it. Only a process that dies mid-way — force quit, crash,
//  power loss — leaves one behind, and nothing ever looked at it again:
//  a copy of the audio, sometimes gigabytes, hidden in the user's folder.
//
//  Swept once per launch, on the first Library scan (not under tests,
//  which run inside the app against the real folders). A folder counts
//  as abandoned only when neither it nor anything in it has changed for
//  `minimumAge`. The folder's own date is what moves: it is set when the
//  folder is made and each time a file lands in it (a copied file keeps
//  the original's old date). Every staging folder this launch could have
//  made is younger than the process, so only an earlier run's remain.
//  Removed, not trashed — the same as the staging code's own failure
//  path. Staging never holds the only copy: the import's original is
//  trashed only after the rename, and re-transcription copies from a
//  session that stays where it is.
//

import Foundation
import os

nonisolated enum StagingSweep {
    static let prefixes = [".daisy-import-", ".daisy-retranscribe-"]
    static let minimumAge: TimeInterval = 6 * 3600

    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "StagingSweep")

    /// Removes abandoned staging folders directly inside each root and
    /// returns their names.
    @discardableResult
    static func sweep(roots: [URL], now: Date = Date(), minimumAge: TimeInterval = minimumAge) -> [String] {
        let fm = FileManager.default
        var removed: [String] = []
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsSubdirectoryDescendants]
            ) else { continue }
            for url in entries {
                let name = url.lastPathComponent
                guard prefixes.contains(where: { name.hasPrefix($0) }),
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      let changed = lastChange(of: url),
                      now.timeIntervalSince(changed) >= minimumAge
                else { continue }
                do {
                    try fm.removeItem(at: url)
                    removed.append(name)
                    log.notice("Removed abandoned staging folder \(name, privacy: .public), untouched since \(changed, privacy: .public)")
                } catch {
                    log.warning("Couldn't remove abandoned staging folder \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return removed
    }

    /// The newest modification date of the folder and everything in it.
    static func lastChange(of folder: URL) -> Date? {
        let key = URLResourceKey.contentModificationDateKey
        var newest = (try? folder.resourceValues(forKeys: [key]))?.contentModificationDate
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [key])
        while let item = walker?.nextObject() as? URL {
            if let date = (try? item.resourceValues(forKeys: [key]))?.contentModificationDate,
               date > (newest ?? .distantPast) {
                newest = date
            }
        }
        return newest
    }
}
