//
//  RegistryCloud.swift
//  DaisyCore
//
//  iCloud's key-value store as the two registries use it (`FolderRegistry`,
//  `VocabularyRegistry`): one value per key, written whole, and a notice
//  when another device changed it.
//
//  A protocol for two reasons (16.11). A store told not to use iCloud must
//  not touch the real one at all — on the Mac, sync is off until the
//  person turns it on, and until then the project list and the vocabulary
//  stay on this Mac. And a test can stand in for iCloud, which a bare
//  `swift test` binary has none of.
//

import Foundation

@MainActor
public protocol RegistryCloud: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    /// Take the value out of iCloud, on every device's copy of the store.
    func removeValue(forKey key: String)
    /// Call `changed` whenever another device wrote. One observer at a
    /// time: a second call replaces the first.
    func startObserving(_ changed: @escaping @MainActor () -> Void)
    func stopObserving()
}

/// The real one. `NSUbiquitousKeyValueStore.default` is reached only from
/// the calls below, never from `init`: a store that is never asked to use
/// iCloud never opens it.
@MainActor
public final class ICloudKeyValueCloud: RegistryCloud {
    private var observer: (any NSObjectProtocol)?

    public init() {}

    public func data(forKey key: String) -> Data? {
        NSUbiquitousKeyValueStore.default.data(forKey: key)
    }

    public func set(_ data: Data, forKey key: String) {
        let kvs = NSUbiquitousKeyValueStore.default
        kvs.set(data, forKey: key)
        kvs.synchronize()
    }

    public func removeValue(forKey key: String) {
        let kvs = NSUbiquitousKeyValueStore.default
        kvs.removeObject(forKey: key)
        kvs.synchronize()
    }

    public func startObserving(_ changed: @escaping @MainActor () -> Void) {
        stopObserving()
        let kvs = NSUbiquitousKeyValueStore.default
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: kvs, queue: .main
        ) { _ in
            MainActor.assumeIsolated { changed() }
        }
        kvs.synchronize()
    }

    public func stopObserving() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
