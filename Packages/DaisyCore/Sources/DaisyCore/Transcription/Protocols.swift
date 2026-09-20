//
//  Protocols.swift
//  DaisyCore
//
//  The two seams DaisyCore's recovery and queue code talk through, so
//  the package never names an engine or a store. On the Mac these were
//  direct calls into `WhisperEngine` and `SessionStore`.
//

import Foundation

/// Something that turns 16 kHz mono Float32 samples into timed segments.
public protocol Transcribing: AnyObject {
    /// Whether a call to `transcribe` can succeed right now.
    var isReady: Bool { get }
    /// Segments with `startSec` / `endSec` relative to the start of
    /// `samples`, in order.
    func transcribe(samples: [Float]) async throws -> [TranscriptSegment]
}

/// Something that publishes a finished transcript into a session
/// folder and drops the `.recording` marker afterwards.
public protocol SessionWriting: AnyObject {
    func finish(directory: URL, transcript: String) throws
}

/// The default `SessionWriting`: straight to `SessionWriter`.
public final class DiskSessionWriter: SessionWriting {
    public init() {}
    public func finish(directory: URL, transcript: String) throws {
        try SessionWriter.finish(directory: directory, transcript: transcript)
    }
}
