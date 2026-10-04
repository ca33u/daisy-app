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
            // The size comes from the archive itself. Deflate cannot grow
            // data more than ~1032 times, so a larger claim is a lie made
            // to have us allocate gigabytes.
            guard !raw.isEmpty, entry.uncompressedSize / 1100 <= raw.count else {
                throw ZipError.badEntry(entry.path)
            }
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

    /// One entry straight to a file, a megabyte at a time: the archive is
    /// memory-mapped and the inflated bytes never sit in memory whole
    /// (audit 02.10 — an hour of audio used to be inflated into one
    /// buffer). The size written must be the size the directory states.
    static func write(_ entry: Entry, from data: Data, to target: URL) throws {
        let h = entry.localHeaderOffset
        guard h + 30 <= data.count, u32(data, h) == 0x0403_4B50 else { throw ZipError.badEntry(entry.path) }
        let start = h + 30 + u16(data, h + 26) + u16(data, h + 28)
        guard start + entry.compressedSize <= data.count else { throw ZipError.badEntry(entry.path) }
        let fm = FileManager.default
        let partial = target.deletingLastPathComponent().appendingPathComponent(".zip-\(UUID().uuidString)")
        guard fm.createFile(atPath: partial.path, contents: nil) else { throw ZipError.badEntry(entry.path) }
        var finished = false
        defer { if !finished { try? fm.removeItem(at: partial) } }
        let out = try FileHandle(forWritingTo: partial)
        defer { try? out.close() }
        let chunk = 1 << 20
        var written = 0
        switch entry.method {
        case 0:
            var offset = start
            let end = start + entry.compressedSize
            while offset < end {
                let next = min(end, offset + chunk)
                try out.write(contentsOf: data.subdata(in: (data.startIndex + offset)..<(data.startIndex + next)))
                written += next - offset
                offset = next
            }
        case 8:
            guard entry.compressedSize > 0 || entry.uncompressedSize == 0 else { throw ZipError.badEntry(entry.path) }
            guard entry.uncompressedSize / 1100 <= max(entry.compressedSize, 1) else { throw ZipError.badEntry(entry.path) }
            let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { stream.deallocate() }
            guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                throw ZipError.inflateFailed(entry.path)
            }
            defer { compression_stream_destroy(stream) }
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
            defer { buffer.deallocate() }
            var offset = start
            let end = start + entry.compressedSize
            var status = COMPRESSION_STATUS_OK
            while status == COMPRESSION_STATUS_OK {
                let next = min(end, offset + chunk)
                let input = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + next))
                offset = next
                let flags: Int32 = offset >= end ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(buffer)
                    stream.pointee.src_size = input.count
                    repeat {
                        stream.pointee.dst_ptr = buffer
                        stream.pointee.dst_size = chunk
                        status = compression_stream_process(stream, flags)
                        guard status != COMPRESSION_STATUS_ERROR else { throw ZipError.inflateFailed(entry.path) }
                        let produced = chunk - stream.pointee.dst_size
                        if produced > 0 {
                            written += produced
                            // More than the directory promised: a bomb or a lie.
                            guard written <= entry.uncompressedSize else { throw ZipError.inflateFailed(entry.path) }
                            try out.write(contentsOf: Data(bytes: buffer, count: produced))
                        }
                    // With the last input in, keep going until the stream
                    // says END: it hands the output over in bursts.
                    } while status == COMPRESSION_STATUS_OK
                        && (stream.pointee.src_size > 0 || stream.pointee.dst_size == 0 || flags != 0)
                }
            }
        default:
            throw ZipError.unsupported("compression method \(entry.method)")
        }
        guard written == entry.uncompressedSize else { throw ZipError.inflateFailed(entry.path) }
        try out.close()
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: partial, to: target)
        finished = true
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
                try write(entry, from: data, to: target)
            }
        }
        return topLevel
    }
}
