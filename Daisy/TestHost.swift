//
//  TestHost.swift
//  Daisy
//
//  DaisyTests run inside Daisy.app (TEST_HOST): the whole app, on the real
//  defaults, caches and Application Support of the Daisy in /Applications.
//  What starts by itself at launch and touches that shared state skips it
//  there — every test run opened «What's New» and marked it seen on Egor's
//  Mac, could install a beta over the debug build, and share Sentry's crash
//  store with the real app (22.10).
//

import Foundation

nonisolated enum TestHost {
    static let isActive = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
