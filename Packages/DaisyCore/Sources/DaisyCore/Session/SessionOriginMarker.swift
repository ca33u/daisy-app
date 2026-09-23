//
//  SessionOriginMarker.swift
//  DaisyCore
//
//  §3.6 says the values of `daisy_origin` grow. A session folder that
//  has audio but no transcript yet has nowhere to carry its origin —
//  the frontmatter does not exist until the transcript is written, and
//  by then whoever made the recording is long gone. This is that
//  carrier: one tiny file beside the audio, written by the recorder,
//  read by the transcriber.
//
//  Deliberately NOT inferred later. Guessing the origin from what is
//  in the folder is exactly the shape of mistake §3.6 warns about.
//

import Foundation

public enum SessionOriginMarker {
    public nonisolated static let fileName = "origin.json"

    private nonisolated struct Payload: Codable {
        var origin: String
    }

    public nonisolated static func write(_ origin: String, in directory: URL) {
        guard let data = try? JSONEncoder().encode(Payload(origin: origin)) else { return }
        try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    public nonisolated static func read(in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return payload.origin.isEmpty ? nil : payload.origin
    }
}
