// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  MeetingPlanFileExtractorTests.swift
//  DaisyTests
//

import Foundation
import Testing
import zlib
@testable import Daisy

@Suite("Meeting plan file extraction")
struct MeetingPlanFileExtractorTests {
    @Test("TXT import normalizes text and stores metadata without a path")
    func textImport() throws {
        try withTemporaryFile(name: "agenda.txt", data: Data("  Intro\r\nBudget  \r\n".utf8)) { url in
            let importedAt = Date(timeIntervalSince1970: 1_787_100_000)
            let result = try MeetingPlanFileExtractor.extract(from: url, importedAt: importedAt)
            #expect(result.text == "  Intro\nBudget")
            #expect(result.source.fileName == "agenda.txt")
            #expect(result.source.typeIdentifier == "public.plain-text")
            #expect(result.source.importedAt == importedAt)
            #expect(result.source.extractedCharacterCount == 14)
        }
    }

    @Test("Markdown import preserves nested indentation and uses stable metadata")
    func markdownImport() throws {
        let markdown = "- Discovery\n  - Confirm constraints  \n"
        try withTemporaryFile(name: "agenda.markdown", data: Data(markdown.utf8)) { url in
            let result = try MeetingPlanFileExtractor.extract(from: url)
            #expect(result.text == "- Discovery\n  - Confirm constraints")
            #expect(result.source.typeIdentifier == "net.daringfireball.markdown")
        }
    }

    @Test("Text longer than the accepted plan limit is rejected")
    func textLengthLimit() throws {
        let data = Data(String(
            repeating: "a",
            count: MeetingPlanFileExtractor.maximumTextCharacters + 1
        ).utf8)
        try withTemporaryFile(name: "long.md", data: data) { url in
            #expect(throws: MeetingPlanFileExtractionError.textTooLong(
                maxCharacters: MeetingPlanFileExtractor.maximumTextCharacters
            )) {
                try MeetingPlanFileExtractor.extract(from: url)
            }
        }
    }

    @Test("File reads stop at the hard byte limit")
    func fileSizeLimit() throws {
        let data = Data(count: MeetingPlanFileExtractor.maximumFileBytes + 1)
        try withTemporaryFile(name: "large.txt", data: data) { url in
            #expect(throws: MeetingPlanFileExtractionError.fileTooLarge(maxMegabytes: 15)) {
                try MeetingPlanFileExtractor.extract(from: url)
            }
        }
    }

    @Test("A deflated DOCX extracts paragraphs, tabs and line breaks")
    func docxExtraction() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>Discovery</w:t></w:r><w:r><w:tab/><w:t>questions</w:t></w:r></w:p>
            <w:p><w:r><w:t>Confirm budget</w:t><w:br/><w:t>Agree next steps</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """
        let docx = try makeSingleEntryZIP(
            name: "word/document.xml",
            content: Data(xml.utf8),
            deflated: true
        )
        try withTemporaryFile(name: "sales-script.docx", data: docx) { url in
            let result = try MeetingPlanFileExtractor.extract(from: url)
            #expect(result.text == "Discovery\tquestions\nConfirm budget\nAgree next steps")
            #expect(result.source.fileName == "sales-script.docx")
        }
    }

    @Test("DOCX without the Word document entry is rejected")
    func invalidDOCX() throws {
        let archive = try makeSingleEntryZIP(
            name: "other.xml",
            content: Data("<xml/>".utf8),
            deflated: false
        )
        try withTemporaryFile(name: "broken.docx", data: archive) { url in
            #expect(throws: MeetingPlanFileExtractionError.invalidDOCX) {
                try MeetingPlanFileExtractor.extract(from: url)
            }
        }
    }

    private func withTemporaryFile(
        name: String,
        data: Data,
        body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaisyPlanImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic])
        try body(url)
    }

    private func makeSingleEntryZIP(name: String, content: Data, deflated: Bool) throws -> Data {
        let compressed = deflated ? try rawDeflate(content) : content
        let method: UInt16 = deflated ? 8 : 0
        let checksum = content.withUnsafeBytes { raw in
            UInt32(zlib.crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(content.count)))
        }
        let nameData = Data(name.utf8)

        var local = Data()
        local.appendLE(UInt32(0x0403_4B50))
        local.appendLE(UInt16(20))
        local.appendLE(UInt16(0))
        local.appendLE(method)
        local.appendLE(UInt16(0)); local.appendLE(UInt16(0))
        local.appendLE(checksum)
        local.appendLE(UInt32(compressed.count))
        local.appendLE(UInt32(content.count))
        local.appendLE(UInt16(nameData.count))
        local.appendLE(UInt16(0))
        local.append(nameData)
        local.append(compressed)

        var central = Data()
        central.appendLE(UInt32(0x0201_4B50))
        central.appendLE(UInt16(20)); central.appendLE(UInt16(20))
        central.appendLE(UInt16(0)); central.appendLE(method)
        central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
        central.appendLE(checksum)
        central.appendLE(UInt32(compressed.count))
        central.appendLE(UInt32(content.count))
        central.appendLE(UInt16(nameData.count))
        central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
        central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
        central.appendLE(UInt32(0)); central.appendLE(UInt32(0))
        central.append(nameData)

        var result = local
        let centralOffset = result.count
        result.append(central)
        result.appendLE(UInt32(0x0605_4B50))
        result.appendLE(UInt16(0)); result.appendLE(UInt16(0))
        result.appendLE(UInt16(1)); result.appendLE(UInt16(1))
        result.appendLE(UInt32(central.count))
        result.appendLE(UInt32(centralOffset))
        result.appendLE(UInt16(0))
        return result
    }

    private func rawDeflate(_ input: Data) throws -> Data {
        var stream = z_stream()
        let initialized = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else { throw MeetingPlanFileExtractionError.invalidDOCX }
        defer { deflateEnd(&stream) }

        let outputCapacity = max(64, Int(deflateBound(&stream, uLong(input.count))))
        var output = Data(count: outputCapacity)
        let status: Int32 = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer<Bytef>(
                    mutating: source.bindMemory(to: Bytef.self).baseAddress
                )
                stream.avail_in = uInt(input.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputCapacity)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw MeetingPlanFileExtractionError.invalidDOCX }
        output.count = Int(stream.total_out)
        return output
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
