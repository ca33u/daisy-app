//
//  FrontmatterMerge.swift
//  DaisyCore
//
//  backlog 9, the third fork: last-write-wins is the floor, not the
//  rule. The real conflict is the Mac adding diarization while the
//  phone renames the session — two keys, no overlap, both must survive.
//
//  Frontmatter merges by key against the last synced base: a key changed
//  on one side only takes that side; changed on both — the newer stamp;
//  `daisy_speaker_map` never goes from something to `{}` (the Mac, which
//  diarizes, is nearly always right; an empty map is "not done yet",
//  not "nobody"). The body is one value: last write wins, and the losing
//  text is handed back so the caller can keep it beside the file (§7.2).
//

import CryptoKit
import Foundation

public nonisolated enum FrontmatterMerge {
    public struct Side: Sendable {
        public var values: [String: String]
        public var stamps: [String: Double]
        public init(values: [String: String], stamps: [String: Double]) {
            self.values = values
            self.stamps = stamps
        }
        /// Every key with one stamp — a side whose keys changed together
        /// (the local file, stamped with its mtime).
        public init(values: [String: String], stamp: Double) {
            self.values = values
            self.stamps = values.mapValues { _ in stamp }
        }
    }

    public struct Result: Sendable, Equatable {
        public var values: [String: String]
        public var stamps: [String: Double]
        /// Keys whose merged value differs from the local one.
        public var changedLocally: Set<String>
        /// Keys whose merged value differs from the remote one.
        public var changedRemotely: Set<String>
    }

    public static let speakerMapKey = "daisy_speaker_map"

    static func isEmptyMap(_ raw: String?) -> Bool {
        guard let raw else { return true }
        let t = raw.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == "{}"
    }

    public static func merge(base: [String: String], local: Side, remote: Side) -> Result {
        var values: [String: String] = [:]
        var stamps: [String: Double] = [:]
        var changedLocally = Set<String>()
        var changedRemotely = Set<String>()
        let keys = Set(local.values.keys).union(remote.values.keys)
        for key in keys {
            let l = local.values[key], r = remote.values[key], b = base[key]
            let localChanged = l != b
            let remoteChanged = r != b
            var pick: (value: String?, stamp: Double)
            switch (localChanged, remoteChanged) {
            case (false, false), (true, false):
                pick = (l, local.stamps[key] ?? 0)
            case (false, true):
                pick = (r, remote.stamps[key] ?? 0)
            case (true, true):
                if key == speakerMapKey {
                    // Never a map → `{}`; two real maps → the newer.
                    if isEmptyMap(r), !isEmptyMap(l) { pick = (l, local.stamps[key] ?? 0) }
                    else if isEmptyMap(l), !isEmptyMap(r) { pick = (r, remote.stamps[key] ?? 0) }
                    else { pick = (remote.stamps[key] ?? 0) > (local.stamps[key] ?? 0) ? (r, remote.stamps[key] ?? 0) : (l, local.stamps[key] ?? 0) }
                } else {
                    pick = (remote.stamps[key] ?? 0) > (local.stamps[key] ?? 0) ? (r, remote.stamps[key] ?? 0) : (l, local.stamps[key] ?? 0)
                }
            }
            // A key absent on the winning side stays absent — but a key
            // one side never had and the other added is an addition.
            // (A key the base HAD and one side removed is a removal: it
            // used to come back from the other side on the next pass,
            // and a take could end up «best» twice — audit 02.10.)
            if pick.value == nil, b == nil { pick.value = l ?? r }
            guard let value = pick.value else {
                if l != nil { changedLocally.insert(key) }
                if r != nil { changedRemotely.insert(key) }
                continue
            }
            values[key] = value
            stamps[key] = pick.stamp
            if value != l { changedLocally.insert(key) }
            if value != r { changedRemotely.insert(key) }
        }
        return Result(values: values, stamps: stamps, changedLocally: changedLocally, changedRemotely: changedRemotely)
    }

    public enum BodyWinner: Sendable, Equatable { case local, remote, same }

    /// Last write wins; `same` when nothing to do. `conflict` is true
    /// when both sides changed since the base — the loser deserves a
    /// copy beside the file.
    public static func mergeBody(baseHash: String, local: String, localStamp: Double, remote: String, remoteStamp: Double) -> (winner: BodyWinner, conflict: Bool) {
        if local == remote { return (.same, false) }
        let lh = hash(local), rh = hash(remote)
        let localChanged = lh != baseHash
        let remoteChanged = rh != baseHash
        switch (localChanged, remoteChanged) {
        case (true, false): return (.local, false)
        case (false, true): return (.remote, false)
        case (false, false): return (.same, false)
        case (true, true): return (remoteStamp > localStamp ? .remote : .local, true)
        }
    }

    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
