//
//  ModelStore.swift
//  DaisyCore
//
//  Where the Parakeet TDT v3 model lives on the phone, and whether it is
//  all there. NOT in the app bundle (~600 MB): downloaded on request
//  into `Application Support/Models/parakeet-tdt-0.6b-v3/`.
//
//  The folder name is FluidAudio's (`AsrModels.load(from:)` derives the
//  repo folder from its parent + `repo.folderName`, which for v3 is the
//  HuggingFace repo name minus `-coreml`), so a download that lands
//  there and the load can never disagree about the path.
//
//  This type ONLY answers "is the model on disk and intact" — it no
//  longer downloads anything itself (backlog B-2). The transfer that
//  survives the app being killed lives in the app target's
//  `ModelDownloader` (a background `URLSessionConfiguration`, since
//  FluidAudio's own `AsrModels.download` runs a plain foreground
//  session that dies with the process). `ModelDownloader` calls
//  `writeManifest(at:)` once every required file is on disk.
//
//  Integrity: FluidAudio's `modelsExist` (every required top-level file
//  present) plus a byte-count manifest written after a successful
//  download, so a half-copied or truncated model reads `.missing`, not
//  `.ready`, even though `modelsExist` only checks presence.
//

import Foundation
import Observation
import os
#if canImport(FluidAudio)
import FluidAudio
#endif

@MainActor
@Observable
public final class ModelStore {
    public enum State: Equatable, Sendable {
        case missing
        case ready
        case failed(String)
    }

    /// Approximate download size for the UI ("Model not downloaded — 600 MB").
    public static let approximateBytes: Int64 = 600 * 1_048_576
    public static let folderName = "parakeet-tdt-0.6b-v3"   // FluidAudio: repo name minus "-coreml"

    public private(set) var state: State = .missing
    /// Bytes on disk right now (0 when missing).
    public private(set) var bytesOnDisk: Int64 = 0

    public let directory: URL
    @ObservationIgnored private let log = Logger(subsystem: DaisyCore.logSubsystem, category: "ModelStore")

    /// `Application Support/Models/<folderName>`.
    public static func defaultDirectory() -> URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    public init(directory: URL = ModelStore.defaultDirectory()) {
        self.directory = directory
        refresh()
    }

    public var isReady: Bool { state == .ready }

    /// Re-check the disk. Cheap; call on launch, and after
    /// `ModelDownloader` finalizes a download.
    public func refresh() {
        let dir = directory
        let ok = Self.verify(at: dir)
        bytesOnDisk = Self.directorySize(at: dir)
        state = ok ? .ready : .missing
    }

    /// Mark a download attempt as failed (called by `ModelDownloader`,
    /// which owns the actual transfer).
    public func reportFailure(_ message: String) {
        state = .failed(message)
    }

    /// Delete the model. Returns freed bytes. Does not touch any
    /// in-flight `ModelDownloader` transfer — cancel that separately.
    @discardableResult
    public func remove() -> Int64 {
        let size = Self.directorySize(at: directory)
        try? FileManager.default.removeItem(at: directory)
        state = .missing
        bytesOnDisk = 0
        return size
    }

    // MARK: - Integrity

    public nonisolated static let manifestName = "manifest.json"

    private nonisolated struct Manifest: Codable, Sendable {
        var version: String
        var bytes: Int64
        var files: [String: Int64]
    }

    /// Every required file present (FluidAudio's own check) AND the
    /// byte total matches what we recorded after the download. Without
    /// a manifest (model copied in by hand) the presence check alone
    /// decides.
    public nonisolated static func verify(at directory: URL) -> Bool {
        #if canImport(FluidAudio)
        guard AsrModels.modelsExist(at: directory, version: .v3) else { return false }
        #else
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        #endif
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(manifestName)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return true
        }
        for (name, expected) in manifest.files {
            let actual = itemSize(at: directory.appendingPathComponent(name))
            if actual != expected { return false }
        }
        return true
    }

    /// Called by `ModelDownloader` once every manifest entry has landed —
    /// records each top-level item's byte size so a later `verify()` can
    /// tell a complete model from one silently truncated after the fact.
    public nonisolated static func writeManifest(at directory: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        var files: [String: Int64] = [:]
        for name in entries where name != manifestName && !name.hasPrefix(".") {
            files[name] = itemSize(at: directory.appendingPathComponent(name))
        }
        let manifest = Manifest(version: "v3", bytes: files.values.reduce(0, +), files: files)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(manifest).write(to: directory.appendingPathComponent(manifestName), options: .atomic)
    }

    /// Size of a file, or the sum of a bundle directory (`.mlmodelc`).
    public nonisolated static func itemSize(at url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return -1 }
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return directorySize(at: url)
    }

    public nonisolated static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true, let s = v?.fileSize { total += Int64(s) }
        }
        return total
    }
}
