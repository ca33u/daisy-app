// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  NetworkMonitor.swift
//  Daisy
//
//  Lightweight reachability wrapper (NWPathMonitor). Its one job today:
//  let the model engines register a one-shot "retry when the network
//  comes back" action, so a model download that failed because the Mac
//  was offline (e.g. right after a restart, before Wi-Fi reconnects)
//  finishes on its own instead of leaving the user stuck at a spinner /
//  a dead "model failed to load".
//

import Foundation
import Network
import Observation

@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// Best-effort current reachability. Starts optimistic (true) until
    /// the first path update lands.
    private(set) var isOnline: Bool = true

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "app.essazanov.Daisy.NetworkMonitor")
    /// One-shot actions to run on the next offline→online transition,
    /// keyed so repeated failures (e.g. a retry loop) don't stack.
    @ObservationIgnored private var reconnectActions: [String: () -> Void] = [:]

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            // Bind to an immutable `self` before hopping actors — a weak
            // capture is a mutable var, which Swift 6 rejects inside the
            // concurrently-executing Task closure.
            guard let self else { return }
            Task { @MainActor in self.update(online: online) }
        }
        monitor.start(queue: queue)
    }

    private func update(online: Bool) {
        let wasOffline = !isOnline
        isOnline = online
        guard online, wasOffline else { return }
        let actions = reconnectActions
        reconnectActions.removeAll()
        for (_, action) in actions { action() }
    }

    /// Run `action` once, the next time connectivity returns. If the
    /// network already looks up (the failure was likely transient), retry
    /// after a short delay instead. Re-registering the same `id` replaces
    /// the pending action rather than stacking.
    func runWhenOnline(id: String, _ action: @escaping () -> Void) {
        reconnectActions[id] = action
        if isOnline {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if let pending = reconnectActions.removeValue(forKey: id) { pending() }
            }
        }
    }

    /// Heuristic: does this error look like "we're offline" (vs a real
    /// server/parse failure)? Used to decide whether to schedule a
    /// reconnect-retry.
    nonisolated static func isOfflineError(_ error: Error) -> Bool {
        // Deliberately NOT .timedOut — a timeout while genuinely online
        // shouldn't kick off a reconnect-retry loop; only true "no network".
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost:
                return true
            default:
                break
            }
        }
        let d = error.localizedDescription.lowercased()
        return d.contains("offline") || d.contains("internet connection")
    }
}
