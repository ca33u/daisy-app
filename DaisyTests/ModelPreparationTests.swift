import Foundation
import Testing
@testable import Daisy

@Suite("Model preparation safety")
struct ModelPreparationTests {
    @Test("Every tour path has the models step, once, right before the end")
    func modelsStepInEveryPath() {
        // It can be skipped (the model finishes in the background) but
        // every path still passes through it, and a resume lands on it.
        for path in [OnboardingTour.Path.full, .dictationOnly] {
            let steps = OnboardingTour.steps(for: path)
            #expect(steps.suffix(2) == [.models, .done])
            #expect(steps.filter { $0 == .models }.count == 1)
            #expect(OnboardingTour.resumeStep(savedRaw: "models", path: path) == .models)
        }
    }

    @Test("Disk budget includes staging and grows with model size; cached load is exempt")
    func diskBudget() {
        #expect(ModelPreparationPolicy.requiredFreeBytes(downloadMB: 0) == 0)
        #expect(ModelPreparationPolicy.requiredFreeBytes(downloadMB: 626) > 2 * 1_073_741_824)
        #expect(ModelPreparationPolicy.requiredFreeBytes(downloadMB: 1500) > ModelPreparationPolicy.requiredFreeBytes(downloadMB: 626))
    }

    @Test("Three empty model directories are not a complete cache")
    func emptyBundles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("\(name).mlmodelc"), withIntermediateDirectories: true)
        }
        #expect(!ModelPreparationPolicy.isCompleteWhisperFolder(root))
    }

    @Test("Missing, empty, and Git LFS placeholder weights invalidate a cache")
    func truncatedCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let bundle = root.appendingPathComponent("\(name).mlmodelc")
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("weights"), withIntermediateDirectories: true)
            for file in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
                try Data([1, 2, 3, 4]).write(to: bundle.appendingPathComponent(file))
            }
        }
        #expect(ModelPreparationPolicy.isCompleteWhisperFolder(root))
        let weights = root.appendingPathComponent("MelSpectrogram.mlmodelc/weights/weight.bin")
        try Data().write(to: weights)
        #expect(!ModelPreparationPolicy.isCompleteWhisperFolder(root))
        try Data("version https://git-lfs.github.com/spec/v1\noid sha256:placeholder".utf8).write(to: weights)
        #expect(!ModelPreparationPolicy.isCompleteWhisperFolder(root))
        try FileManager.default.removeItem(at: weights)
        #expect(!ModelPreparationPolicy.isCompleteWhisperFolder(root))
    }
}
