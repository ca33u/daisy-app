//
//  ScratchDefaults.swift
//  DaisyTests
//
//  UserDefaults suites of a test's own, gone from disk when it ends.
//  A suite named the usual way lives in ~/Library/Preferences, and its file
//  outlives `removePersistentDomain` (and a deleted file comes back: cfprefsd
//  writes it again when the process exits). Every run left an empty
//  <suite>.plist there, close to ten thousand by 02.11.2026. A suite named
//  by an absolute path keeps its plist at that path instead, so each one
//  gets a folder in the temporary directory, removed with it.
//

import Foundation

/// Keep one as a stored property of a test suite: Swift Testing makes a
/// new instance for every test and drops it when the test ends, and the
/// suites go with it — so whatever holds the defaults must not write to
/// them after the test returns. A test that makes a suite by itself takes
/// its name from `suite(_:)` and removes it in a `defer`.
nonisolated final class ScratchDefaults: @unchecked Sendable {
    private let prefix: String
    private let lock = NSLock()
    private var names: [String] = []

    init(_ prefix: String) {
        self.prefix = prefix
    }

    deinit {
        for name in names { Self.remove(name) }
    }

    /// The name of a new, empty suite, removed with this instance — for a
    /// test that opens the same suite twice.
    func name() -> String {
        let name = Self.suite(prefix)
        lock.withLock { names.append(name) }
        return name
    }

    /// A new, empty suite, removed with this instance.
    func make() -> UserDefaults {
        UserDefaults(suiteName: name())!
    }

    /// The name of a new, empty suite in a folder of its own (made by the
    /// first write); `remove(_:)` it when done.
    static func suite(_ prefix: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DaisyTestDefaults/\(prefix).\(UUID().uuidString)/defaults")
            .path
    }

    /// Empties the suite and deletes its folder, which stays gone at exit.
    /// A write after this makes the folder again: remove a suite only when
    /// nothing writes to it any more.
    static func remove(_ name: String) {
        UserDefaults().removePersistentDomain(forName: name)
        CFPreferencesAppSynchronize(name as CFString)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: name).deletingLastPathComponent())
    }
}
