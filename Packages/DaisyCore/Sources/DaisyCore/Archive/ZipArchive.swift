//
//  ZipArchive.swift
//  DaisyCore
//
//  backlog 8 G-3: the phone opens a `.daisy` the Mac exported. iOS has
//  no `ditto`, and Foundation zips (NSFileCoordinator `.forUploading`)
//  but never unzips — so this is the smallest reader that opens what the
//  two apps write: a central directory, entries stored or deflated,
//  paths relative to the archive root. Nothing else (no encryption, no
//  spanning, no data descriptors beyond what the central directory
//  already states) — a `.daisy` never needs more, and anything odd is
//  refused rather than guessed at.
//
//  Safety: entry paths are rejected if they escape the destination
//  (`..`, absolute), symlinks are not created, sizes come from the
//  central directory and are checked after inflation.
//

import Compression
import Foundation

public nonisolated enum ZipArchive {
    public enum ZipError: LocalizedError {
        case notAZip
        case unsupported(String)
        case badEntry(String)
        case inflateFailed(String)
        public var errorDescription: String? {
            switch self {
            case .notAZip: "Not a zip archive."
            case .unsupported(let what): "Unsupported zip feature: \(what)."
            case .badEntry(let name): "Refused entry \(name)."
            case .inflateFailed(let name): "Could not inflate \(name)."
            }
        }
    }

    public struct Entry: Sendable, Equatable {
        public let path: String
        public let isDirectory: Bool
        public let compressedSize: Int
        public let uncompressedSize: Int
        let method: UInt16
        let localHeaderOffset: Int
    }

    // MARK: - Reading

    private static func u16(_ d: Data, _ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 }
    private static func u32(_ d: Data, _ i: Int) -> Int {
        Int(d[i]) | Int(d[i + 1]) << 8 | Int(d[i + 2]) << 16 | Int(d[i + 3]) << 24
    }

    /// The central directory.
    public static func entries(in data: Data) throws -> [Entry] {
        let d = Data(data)   // contiguous, zero-based indices
        // End of central directory: signature 0x06054b50, scan back over
        // the (≤ 64 KB) comment.
        guard d.count >= 22 else { throw ZipError.notAZip }
        var eocd = -1
        var i = d.count - 22
        let floor = max(0, d.count - 22 - 65_535)
        while i >= floor {
            if d[i] == 0x50, d[i + 1] == 0x4B, d[i + 2] == 0x05, d[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        let count = u16(d, eocd + 10)
        let cdSize = u32(d, eocd + 12)
        let cdOffset = u32(d, eocd + 16)
        if count == 0xFFFF || cdOffset == 0xFFFF_FFFF { throw ZipError.unsupported("zip64") }
        guard cdOffset + cdSize <= d.count else { throw ZipError.notAZip }

        var out: [Entry] = []
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= d.count, u32(d, p) == 0x0201_4B50 else { throw ZipError.notAZip }
            let flags = u16(d, p + 8)
            let method = UInt16(u16(d, p + 10))
            let compressed = u32(d, p + 20)
            let uncompressed = u32(d, p + 24)
            let nameLen = u16(d, p + 28)
            let extraLen = u16(d, p + 30)
            let commentLen = u16(d, p + 32)
            let localOffset = u32(d, p + 42)
            guard p + 46 + nameLen <= d.count else { throw ZipError.notAZip }
            let name = String(decoding: d[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            if flags & 0x1 != 0 { throw ZipError.unsupported("encryption") }
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF { throw ZipError.unsupported("zip64") }
            out.append(Entry(path: name, isDirectory: name.hasSuffix("/"), compressedSize: compressed,
                             uncompressedSize: uncompressed, method: method, localHeaderOffset: localOffset))
            p += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    /// One entry's bytes.
    public static func contents(of entry: Entry, in data: Data) throws -> Data {
        let d = Data(data)
        let h = entry.localHeaderOffset
        guard h + 30 <= d.count, u32(d, h) == 0x0403_4B50 else { throw ZipError.badEntry(entry.path) }
        let nameLen = u16(d, h + 26)
        let extraLen = u16(d, h + 28)
        let start = h + 30 + nameLen + extraLen
        guard start + entry.compressedSize <= d.count else { throw ZipError.badEntry(entry.path) }
        let raw = d[start..<(start + entry.compressedSize)]
        switch entry.method {
        case 0:
            return Data(raw)
        case 8:
            guard entry.uncompressedSize > 0 else { return Data() }
            var out = Data(count: entry.uncompressedSize)
            let written = out.withUnsafeMutableBytes { dst -> Int in
                raw.withUnsafeBytes { src -> Int in
                    compression_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, entry.uncompressedSize,
                        src.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            guard written == entry.uncompressedSize else { throw ZipError.inflateFailed(entry.path) }
            return out
        default:
            throw ZipError.unsupported("compression method \(entry.method)")
        }
    }

    /// Unpack the whole archive under `destination` (created if needed).
    /// Returns the top-level names written.
    @discardableResult
    public static func extract(_ archiveURL: URL, into destination: URL) throws -> [String] {
        let data = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let base = destination.standardizedFileURL.path
        var topLevel: [String] = []
        for entry in try entries(in: data) {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !parts.isEmpty, !parts.contains(".."), !entry.path.hasPrefix("/") else { throw ZipError.badEntry(entry.path) }
            // AppleDouble / Finder litter that `ditto` and the coordinator add.
            if parts.contains("__MACOSX") || parts.last?.hasPrefix("._") == true { continue }
            if !topLevel.contains(parts[0]) { topLevel.append(parts[0]) }
            let target = destination.appendingPathComponent(parts.joined(separator: "/"))
            guard target.standardizedFileURL.path.hasPrefix(base) else { throw ZipError.badEntry(entry.path) }
            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents(of: entry, in: data).write(to: target, options: .atomic)
            }
        }
        return topLevel
    }
}
