import Foundation
import Testing
@testable import Daisy

@Suite("Model preparation safety")
struct ModelPreparationTests {
    @Test("Every onboarding path ends on the preparation step")
    func preparationIsTheLastStep() {
        // Last, and exactly once. It can be SKIPPED ("Skip for now",
        // models finish in the background) but never bypassed — every
        // path still lands on it, and `finish()` redirects there.
        for path in [FirstRunView.SetupPath.full, .dictationOnly] {
            for layouts in [1, 2, 5] {
                let steps = FirstRunView.steps(for: path, installedLayoutCount: layouts)
                #expect(steps.last == .preparation)
                #expect(steps.filter { $0 == .preparation }.count == 1)
                #expect(FirstRunView.resumeStep(savedRaw: "preparation", in: steps) == .preparation)
            }
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
