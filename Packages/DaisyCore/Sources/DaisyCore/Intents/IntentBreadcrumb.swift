//
//  IntentBreadcrumb.swift
//  DaisyCore
//
//  DEBUG-only trace of which process performs an App Intent and how it
//  ended, appended to `Library/intent-log.txt` in the App Group
//  container. `log show` / `simctl spawn` are unreliable in this
//  environment and a real device exposes only Library/Documents/tmp
//  over `devicectl device copy` — a file in Library is what can actually
//  be read back from the Mac.
//

import Foundation

public enum IntentBreadcrumb {
    static let appGroupID = "group.app.essazanov.DaisyLite"

    public static func log(_ line: @autoclosure () -> String) {
        #if DEBUG
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        let url = container.appendingPathComponent("Library/intent-log.txt")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp) [\(ProcessInfo.processInfo.processName):\(getpid())] \(line())\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
        #endif
    }
}
