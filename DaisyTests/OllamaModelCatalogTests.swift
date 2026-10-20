//
//  OllamaModelCatalogTests.swift
//  DaisyTests
//
//  Backlog 33: the download catalogue, the memory hint and the
//  `/api/pull` stream parser.
//

import Foundation
import Testing
@testable import Daisy

struct OllamaModelCatalogTests {
    @Test func theMemoryTableIsEgors() {
        #expect(OllamaModelCatalog.recommendedModelID(memoryGB: 7) == nil)
        #expect(OllamaModelCatalog.recommendedModelID(memoryGB: 8) == "qwen3.5:4b")
        #expect(OllamaModelCatalog.recommendedModelID(memoryGB: 15) == "qwen3.5:4b")
        #expect(OllamaModelCatalog.recommendedModelID(memoryGB: 16) == "gemma4:e4b")
        #expect(OllamaModelCatalog.recommendedModelID(memoryGB: 24) == "gemma4:e4b")
        #expect(OllamaModelCatalog.recommendedModelID(memoryGB: 32) == "gemma4:12b")
        #expect(OllamaModelCatalog.recommendedModelID(memoryGB: 128) == "gemma4:12b")
    }

    @Test func everyRecommendationIsInTheCatalogueAndFits() throws {
        for memory in [8, 16, 32] {
            let id = try #require(OllamaModelCatalog.recommendedModelID(memoryGB: memory))
            let model = try #require(OllamaModelCatalog.model(id: id))
            #expect(OllamaModelCatalog.fits(model, memoryGB: memory))
        }
    }

    @Test func nothingInTheCatalogueIsACloudModel() {
        for model in OllamaModelCatalog.models {
            #expect(!OllamaAPISummarizer.isCloudModel(model.id))
            #expect(model.sizeGB > 0)
            #expect(model.minMemoryGB >= OllamaModelCatalog.minimumMemoryGB)
        }
        #expect(OllamaAPISummarizer.availableModels.map(\.id) == OllamaModelCatalog.models.map(\.id))
    }

    @Test func physicalMemoryRoundsToWholeGigabytes() {
        #expect(OllamaModelCatalog.physicalMemoryGB(bytes: 8 * 1_073_741_824) == 8)
        #expect(OllamaModelCatalog.physicalMemoryGB(bytes: 17_179_869_184) == 16)
    }

    @Test func pullEventsParseAndDriveProgress() throws {
        var progress = OllamaPullProgress()
        progress.apply(try #require(OllamaPullEvent.parse(#"{"status":"pulling manifest"}"#)))
        #expect(progress.fraction == nil)
        progress.apply(try #require(OllamaPullEvent.parse(#"{"status":"pulling abc","digest":"sha256:abc","total":1000,"completed":250}"#)))
        #expect(progress.fraction == 0.25)
        progress.apply(try #require(OllamaPullEvent.parse(#"{"status":"pulling abc","digest":"sha256:abc","total":1000,"completed":1000}"#)))
        #expect(progress.fraction == 1)
        progress.apply(try #require(OllamaPullEvent.parse(#"{"status":"verifying sha256 digest"}"#)))
        #expect(progress.fraction == nil)
        #expect(progress.status == "verifying sha256 digest")
        let done = try #require(OllamaPullEvent.parse(#"{"status":"success"}"#))
        #expect(done.isSuccess)
        let failed = try #require(OllamaPullEvent.parse(#"{"error":"pull model manifest: file does not exist"}"#))
        #expect(failed.error == "pull model manifest: file does not exist")
        #expect(OllamaPullEvent.parse("") == nil)
        #expect(OllamaPullEvent.parse("not json") == nil)
    }
}
