import Foundation
import Testing
import WhisperKit
@testable import Daisy

/// Field report 2026-10-27: with Daisy's access to ~/Documents denied, the
/// Whisper tokenizer (which WhisperKit looked for and downloaded under
/// ~/Documents/huggingface) could neither be read nor have its `.metadata`
/// files removed, and every model load failed. The load config must keep
/// the tokenizer in Application Support.
@Suite("Whisper tokenizer location")
struct WhisperTokenizerLocationTests {
    private let folder = URL(fileURLWithPath: "/tmp/daisy-tests/openai_whisper-large-v3-v20240930_626MB",
                             isDirectory: true)

    @Test("The tokenizer folder is Daisy's own base in Application Support")
    func tokenizerFolderIsApplicationSupport() throws {
        let config = WhisperEngine.kitConfig(folder: folder)
        let tokenizerFolder = try #require(config.tokenizerFolder)
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: false)
        let expected = appSupport.appendingPathComponent("Daisy", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
        #expect(tokenizerFolder.standardizedFileURL.path == expected.standardizedFileURL.path)
        // The folder WhisperKit actually searches first and downloads into.
        let hubFolder = HubApiWrapper(downloadBase: config.tokenizerFolder)
            .localRepoLocation(HubApiWrapper.Repo(id: MacModelHosting.tokenizerRepo))
        #expect(hubFolder.standardizedFileURL.path.hasPrefix(expected.standardizedFileURL.path + "/"))
    }

    @Test("Nothing in the load config points into ~/Documents")
    func nothingPointsIntoDocuments() throws {
        let config = WhisperEngine.kitConfig(folder: folder)
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: false)
            .standardizedFileURL.path
        let hubFolder = HubApiWrapper(downloadBase: config.tokenizerFolder)
            .localRepoLocation(HubApiWrapper.Repo(id: MacModelHosting.tokenizerRepo))
        #expect(!hubFolder.standardizedFileURL.path.hasPrefix(documents))
        #expect(config.downloadBase.map { !$0.standardizedFileURL.path.hasPrefix(documents) } ?? true)
    }

    @Test("The model still loads from its own folder, without downloading")
    func modelFolderAndNoDownload() {
        let config = WhisperEngine.kitConfig(folder: folder)
        #expect(config.modelFolder == folder.path)
        #expect(config.download == false)
        #expect(config.load == true)
        #expect(config.prewarm == false)
    }
}
