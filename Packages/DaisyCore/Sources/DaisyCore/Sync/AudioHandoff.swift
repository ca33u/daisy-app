//
//  AudioHandoff.swift
//  DaisyCore
//
//  backlog 9 Ф3-B: audio goes to the Mac on request, directly, never
//  through the cloud. A gigabyte per meeting through CloudKit would eat
//  the person's quota and crawl; over the local network (or peer-to-peer
//  Wi-Fi when there is no network in common — `includePeerToPeer`) it
//  takes seconds.
//
//  Roles: the Mac LISTENS (a Bonjour service, `_daisy-audio._tcp`, TLS
//  with a pre-shared key); the phone CONNECTS whenever it is up and has
//  audio the Mac has not confirmed. One TCP connection, one conversation:
//
//      phone → hello   { device, name }
//      phone → offer   [ session id, files (name, size, sha256) ]
//      Mac   → want    [ session id, file names ]     — only what it lacks
//      phone → file    { id, name, size, sha256 } + the bytes
//      Mac   → ack     { id, name, sha256, ok }       — after hashing what
//                                                       it wrote to disk
//      phone → bye
//
//  An `ack` is the ONLY thing that lets the phone count a file as taken
//  (backlog 9: "checksum matched, an explicit 'took it' — not 'the
//  transfer started', or a torn transfer is a loss").
//
//  Pairing: both apps run under the same Apple ID, and the shared
//  keychain group already carries the summary-provider keys from the
//  Mac to the phone through iCloud Keychain. The pre-shared key travels
//  the same way: the Mac makes it once, the phone finds it. There is
//  nothing to scan.
//
//  Framing: 4 bytes big-endian length + JSON for messages; a `file`
//  message is followed by exactly `size` raw bytes.
//

import CryptoKit
import Foundation
import Network
import os

public nonisolated enum AudioHandoff {
    public static let serviceType = "_daisy-audio._tcp"
    /// Keychain accounts (shared group, iCloud-synchronised).
    public static let pskAccount = "daisy.audio-handoff.psk"
    public static let macNameAccount = "daisy.audio-handoff.mac-name"
    static let pskHint = "daisy-audio"
    static let chunk = 256 * 1024
    static let maxMessage = 4 * 1024 * 1024

    // MARK: - Pairing secret

    /// The Mac's side: the secret, made once and kept in the shared
    /// keychain so the phone finds it. `nil` when the keychain refused.
    public static func ensureSecret(macName: String) -> Data? {
        if let hex = KeychainStore.get(account: pskAccount), let data = Data(hex: hex), data.count == 32 {
            if KeychainStore.get(account: macNameAccount) != macName {
                try? KeychainStore.set(macName, account: macNameAccount)
            }
            return data
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let data = Data(bytes)
        do {
            try KeychainStore.set(data.hex, account: pskAccount)
            try KeychainStore.set(macName, account: macNameAccount)
        } catch {
            return nil
        }
        return data
    }

    /// The phone's side: the secret the Mac left, if it has arrived.
    public static func secret() -> Data? {
        guard let hex = KeychainStore.get(account: pskAccount), let data = Data(hex: hex), data.count == 32 else { return nil }
        return data
    }

    public static func pairedMacName() -> String? {
        KeychainStore.get(account: macNameAccount)
    }

    // MARK: - Transport parameters

    /// TCP + TLS 1.2 with the pre-shared key; peer-to-peer allowed so a
    /// phone and a Mac with no network in common still find each other.
    public static func parameters(psk: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let hint = Data(pskHint.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, hint as __DispatchData)
        if let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_256_GCM_SHA384)) {
            sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, suite)
        }
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    // MARK: - Messages

    public struct OfferedFile: Codable, Sendable, Equatable {
        public var name: String
        public var size: Int64
        public var sha256: String
        public init(name: String, size: Int64, sha256: String) { self.name = name; self.size = size; self.sha256 = sha256 }
    }

    public struct OfferedSession: Codable, Sendable, Equatable {
        public var id: String
        public var files: [OfferedFile]
        public init(id: String, files: [OfferedFile]) { self.id = id; self.files = files }
    }

    public struct WantedSession: Codable, Sendable, Equatable {
        public var id: String
        public var files: [String]
        public init(id: String, files: [String]) { self.id = id; self.files = files }
    }

    public struct FileHeader: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var size: Int64
        public var sha256: String
        public init(id: String, name: String, size: Int64, sha256: String) { self.id = id; self.name = name; self.size = size; self.sha256 = sha256 }
    }

    public struct FileAck: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var sha256: String
        public var ok: Bool
        public init(id: String, name: String, sha256: String, ok: Bool) { self.id = id; self.name = name; self.sha256 = sha256; self.ok = ok }
    }

    public enum Message: Codable, Sendable, Equatable {
        case hello(device: String, name: String)
        case offer([OfferedSession])
        case want([WantedSession])
        case file(FileHeader)
        case ack(FileAck)
        case bye
    }

    public enum LinkError: LocalizedError {
        case closed
        case oversized(Int)
        case badFrame
        case cancelled
        public var errorDescription: String? {
            switch self {
            case .closed: "The connection closed."
            case .oversized(let n): "Frame of \(n) bytes refused."
            case .badFrame: "Unreadable frame."
            case .cancelled: "Cancelled."
            }
        }
    }

    // MARK: - Hashing

    /// SHA-256 of a file, streamed.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The files of a session folder the Mac may want: the raw audio
    /// (§2), with size and hash.
    public static func offer(for directory: URL) -> [OfferedFile] {
        SessionAudioFiles.discover(in: directory).all.compactMap { url in
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  let hash = try? sha256(of: url) else { return nil }
            return OfferedFile(name: url.lastPathComponent, size: Int64(size), sha256: hash)
        }
    }
}

// MARK: - The link

/// One `NWConnection`, spoken to with async calls. Not thread-safe
/// beyond what `NWConnection` gives: one task drives a link at a time.
public nonisolated final class AudioHandoffLink: @unchecked Sendable {
    public let connection: NWConnection
    private let queue = DispatchQueue(label: "app.essazanov.daisy.audio-handoff")
    private let log = Logger(subsystem: DaisyCore.logSubsystem, category: "AudioHandoff")

    public init(connection: NWConnection) {
        self.connection = connection
    }

    /// Start and wait until ready (or fail).
    public func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            nonisolated(unsafe) var done = false
            connection.stateUpdateHandler = { [weak self] state in
                guard !done else { return }
                switch state {
                case .ready:
                    done = true
                    continuation.resume()
                case .failed(let error):
                    done = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    done = true
                    continuation.resume(throwing: AudioHandoff.LinkError.cancelled)
                case .waiting(let error):
                    self?.log.notice("Link waiting: \(error.localizedDescription, privacy: .public)")
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func close() {
        connection.cancel()
    }

    // MARK: Messages

    public func send(_ message: AudioHandoff.Message) async throws {
        let payload = try JSONEncoder().encode(message)
        var frame = Data(capacity: payload.count + 4)
        var length = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(payload)
        try await sendRaw(frame)
    }

    public func receive() async throws -> AudioHandoff.Message {
        let header = try await receiveExactly(4)
        let length = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard length <= AudioHandoff.maxMessage else { throw AudioHandoff.LinkError.oversized(length) }
        let payload = try await receiveExactly(length)
        do {
            return try JSONDecoder().decode(AudioHandoff.Message.self, from: payload)
        } catch {
            throw AudioHandoff.LinkError.badFrame
        }
    }

    // MARK: Bytes

    /// Stream a file after its `file` header.
    public func sendFile(at url: URL, onProgress: (@Sendable (Int64) -> Void)? = nil) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sent: Int64 = 0
        while let data = try handle.read(upToCount: AudioHandoff.chunk), !data.isEmpty {
            try await sendRaw(data)
            sent += Int64(data.count)
            onProgress?(sent)
        }
    }

    /// Receive exactly `size` bytes into `url`, hashing on the way.
    /// Returns the SHA-256 of what landed on disk.
    public func receiveFile(size: Int64, to url: URL, onProgress: (@Sendable (Int64) -> Void)? = nil) async throws -> String {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = size
        while remaining > 0 {
            let want = Int(min(Int64(1024 * 1024), remaining))
            let data = try await receiveSome(min: 1, max: want)
            try handle.write(contentsOf: data)
            hasher.update(data: data)
            remaining -= Int64(data.count)
            onProgress?(size - remaining)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Primitives

    private func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        var out = Data(capacity: count)
        while out.count < count {
            let data = try await receiveSome(min: 1, max: count - out.count)
            out.append(data)
        }
        return out
    }

    private func receiveSome(min: Int, max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: min, maximumLength: max) { data, _, isComplete, error in
                if let error { continuation.resume(throwing: error); return }
                if let data, !data.isEmpty { continuation.resume(returning: data); return }
                if isComplete { continuation.resume(throwing: AudioHandoff.LinkError.closed); return }
                continuation.resume(throwing: AudioHandoff.LinkError.badFrame)
            }
        }
    }
}

nonisolated extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
