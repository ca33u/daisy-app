// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  SubscriptionUsageLedger.swift
//  Daisy
//
//  Local request accounting for account-backed summary providers. These
//  transports do not expose billable token usage, so recording tokens or an
//  estimated price would be invented data. Instead Daisy persists the facts it
//  owns: provider, selected model, elapsed time, success, and request count.
//

import Foundation
import Observation

nonisolated struct SubscriptionUsageBucket: Codable, Equatable, Sendable {
    var provider: String
    var model: String
    var successfulRequests: Int = 0
    var failedRequests: Int = 0
    var totalDurationMilliseconds: Int64 = 0

    var requestCount: Int { successfulRequests + failedRequests }

    init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? container.decode(String.self, forKey: .provider)) ?? ""
        model = (try? container.decode(String.self, forKey: .model)) ?? ""
        successfulRequests = max(
            0,
            (try? container.decode(Int.self, forKey: .successfulRequests)) ?? 0
        )
        failedRequests = max(
            0,
            (try? container.decode(Int.self, forKey: .failedRequests)) ?? 0
        )
        totalDurationMilliseconds = max(
            0,
            (try? container.decode(Int64.self, forKey: .totalDurationMilliseconds)) ?? 0
        )
    }

    mutating func add(durationMilliseconds: Int64, successful: Bool) {
        if successful {
            successfulRequests += 1
        } else {
            failedRequests += 1
        }
        totalDurationMilliseconds += max(0, durationMilliseconds)
    }
}

nonisolated struct SubscriptionUsageSummary: Equatable, Sendable {
    var provider: SummaryProviderKind
    var models: [String]
    var successfulRequests: Int
    var failedRequests: Int
    var totalDurationMilliseconds: Int64

    var requestCount: Int { successfulRequests + failedRequests }
    var averageDurationSeconds: Double {
        guard requestCount > 0 else { return 0 }
        return Double(totalDurationMilliseconds) / 1_000 / Double(requestCount)
    }
}

@MainActor
@Observable
final class SubscriptionUsageLedger {
    static let shared = SubscriptionUsageLedger()
    nonisolated static let retentionDays = 90
    nonisolated static let displayWindowDays = 28

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let defaultsKey: String

    private(set) var days: [String: [SubscriptionUsageBucket]]

    init(
        defaults: UserDefaults = .standard,
        defaultsKey: String = "daisy.subscriptionUsageLedger",
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.now = now
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(
               [String: [SubscriptionUsageBucket]].self,
               from: data
           ) {
            days = decoded
        } else {
            days = [:]
        }
        pruneOldDays()
    }

    func record(
        provider: SummaryProviderKind,
        model: String,
        durationMilliseconds: Int64,
        successful: Bool
    ) {
        guard provider == .openai || provider == .cursor else { return }
        let day = UsageStats.dayKey(for: now())
        var buckets = days[day] ?? []
        if let index = buckets.firstIndex(where: {
            $0.provider == provider.rawValue && $0.model == model
        }) {
            buckets[index].add(
                durationMilliseconds: durationMilliseconds,
                successful: successful
            )
        } else {
            var bucket = SubscriptionUsageBucket(provider: provider.rawValue, model: model)
            bucket.add(durationMilliseconds: durationMilliseconds, successful: successful)
            buckets.append(bucket)
        }
        days[day] = buckets
        persist()
    }

    func recentUsage(
        provider: SummaryProviderKind,
        endingAt end: Date? = nil
    ) -> SubscriptionUsageSummary? {
        let keys = Set(Self.windowDayKeys(endingAt: end ?? now()))
        let buckets = days
            .filter { keys.contains($0.key) }
            .flatMap(\.value)
            .filter { $0.provider == provider.rawValue }
        guard !buckets.isEmpty else { return nil }

        var modelCounts: [String: Int] = [:]
        for bucket in buckets where !bucket.model.isEmpty {
            modelCounts[bucket.model, default: 0] += bucket.requestCount
        }
        return SubscriptionUsageSummary(
            provider: provider,
            models: modelCounts
                .sorted {
                    if $0.value != $1.value { return $0.value > $1.value }
                    return $0.key < $1.key
                }
                .map(\.key),
            successfulRequests: buckets.reduce(0) { $0 + $1.successfulRequests },
            failedRequests: buckets.reduce(0) { $0 + $1.failedRequests },
            totalDurationMilliseconds: buckets.reduce(0) {
                $0 + $1.totalDurationMilliseconds
            }
        )
    }

    nonisolated static func windowDayKeys(endingAt end: Date) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return (0..<displayWindowDays).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: end)
                .map { UsageStats.dayKey(for: $0) }
        }
    }

    private func pruneOldDays() {
        guard let cutoffDate = Calendar.current.date(
            byAdding: .day,
            value: -Self.retentionDays,
            to: now()
        ) else { return }
        let cutoff = UsageStats.dayKey(for: cutoffDate)
        let staleKeys = days.keys.filter { $0 < cutoff }
        guard !staleKeys.isEmpty else { return }
        for key in staleKeys { days.removeValue(forKey: key) }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(days) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

nonisolated enum SubscriptionUsageLedgerSink {
    static func record(
        provider: SummaryProviderKind,
        model: String,
        elapsed: Duration,
        successful: Bool
    ) async {
        let components = elapsed.components
        let seconds = max(0, components.seconds)
        let millisecondsFromAttoseconds = max(0, components.attoseconds / 1_000_000_000_000_000)
        let milliseconds = seconds.multipliedReportingOverflow(by: 1_000)
        let combined = milliseconds.partialValue.addingReportingOverflow(millisecondsFromAttoseconds)
        let total = milliseconds.overflow || combined.overflow
            ? Int64.max
            : combined.partialValue
        await SubscriptionUsageLedger.shared.record(
            provider: provider,
            model: model,
            durationMilliseconds: total,
            successful: successful
        )
    }
}
