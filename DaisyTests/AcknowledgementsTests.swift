//
//  AcknowledgementsTests.swift
//  DaisyTests
//
//  Daisy.app carries the licenses of what it links and downloads
//  (Egor 22.10). Fails when a package moves on and
//  scripts/acknowledgements.py hasn't been run since.
//

import Foundation
import Testing
@testable import Daisy

struct AcknowledgementsTests {
    private func shipped() throws -> String {
        let url = try #require(Bundle(for: SparkleProgress.self).url(forResource: "Acknowledgements", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func theAppCarriesItsAcknowledgements() throws {
        let text = try shipped()
        for name in ["WhisperKit", "FluidAudio", "Sparkle", "Sentry", "Silero VAD", "OpenAI Whisper",
                     "Parakeet TDT 0.6B v3", "CC BY 4.0", "OpenMDW 1.1", "Fluid Inference speaker models"] {
            #expect(text.contains(name), "\(name)")
        }
    }

    @Test func itNamesThePinnedRevisions() throws {
        let text = try shipped()
        let resolved = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Daisy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: resolved)) as? [String: Any]
        let pins = try #require(json?["pins"] as? [[String: Any]])
        for pin in pins {
            let identity = pin["identity"] as? String ?? ""
            // Not linked into Daisy.app (a WhisperKit command-line dependency).
            if identity == "swift-argument-parser" { continue }
            let state = pin["state"] as? [String: Any] ?? [:]
            let pinned = (state["version"] as? String) ?? (state["revision"] as? String) ?? "?"
            #expect(text.contains(pinned), "\(identity) \(pinned) — run scripts/acknowledgements.py")
        }
    }

    /// The speaker models' NOTICE and LICENSE are copied in at a revision.
    @Test func itNamesTheSpeakerModelsRevision() throws {
        let text = try shipped()
        let revisions = Set(try MacModelHosting.catalog()
            .filter { $0.repo == "FluidInference/speaker-diarization-coreml" }
            .map(\.revision))
        #expect(revisions.count == 1)
        for revision in revisions {
            #expect(text.contains(revision), "speaker models \(revision) — run scripts/acknowledgements.py")
        }
    }
}
