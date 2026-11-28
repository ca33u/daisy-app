// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  MeetingPlanFileExtractor.swift
//  Daisy
//
//  Bounded, dependency-free extraction for meeting plans. DOCX is parsed as
//  the OOXML ZIP container directly; only word/document.xml is decompressed,
//  so no archive paths are ever written to disk.
//

import Foundation
import PDFKit
import UniformTypeIdentifiers
import zlib

nonisolated struct ExtractedMeetingPlanFile: Equatable, Sendable {
    let text: String
    let source: MeetingPlanSource
}

nonisolated enum MeetingPlanFileExtractionError: Error, Equatable, LocalizedError {
    case unsupportedFormat
    case fileTooLarge(maxMegabytes: Int)
    case textTooLong(maxCharacters: Int)
    case emptyDocument
    case unreadableFile
    case invalidPDF
    case invalidDOCX
    case encryptedDOCX

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return String(localized: "Choose a TXT, Markdown, PDF, or DOCX file.")
        case .fileTooLarge(let max):
            return String(localized: "The file is too large. Choose a file up to \(max) MB.")
        case .textTooLong(let max):
            return String(localized: "The extracted text is too long. Keep it under \(max.formatted()) characters.")
        case .emptyDocument:
            return String(localized: "No readable text was found in this file.")
        case .unreadableFile:
            return String(localized: "Daisy couldn’t read this file.")
        case .invalidPDF:
            return String(localized: "This PDF couldn’t be opened or contains no extractable text.")
        case .invalidDOCX:
            return String(localized: "This DOCX file is damaged or uses an unsupported structure.")
        case .encryptedDOCX:
            return String(localized: "Password-protected DOCX files aren’t supported.")
        }
    }
}

nonisolated enum MeetingPlanFileExtractor {
    static let maximumFileBytes = 15 * 1_024 * 1_024
    static let maximumTextCharacters = 120_000
    /// XML contains formatting markup in addition to visible text. Still cap
    /// it independently to make a compressed-document bomb impossible.
    private static let maximumDOCXXMLBytes = 8 * 1_024 * 1_024
    private static let markdownIdentifier = "net.daringfireball.markdown"
    private static let docxIdentifier = "org.openxmlformats.wordprocessingml.document"
    private static let markdownType = UTType(filenameExtension: "md")
        ?? UTType(importedAs: markdownIdentifier)
    private static let longMarkdownType = UTType(filenameExtension: "markdown")
        ?? markdownType
    private static let docxType = UTType(filenameExtension: "docx")
        ?? UTType(importedAs: docxIdentifier)

    static var supportedContentTypes: [UTType] {
        [.plainText, markdownType, longMarkdownType, .pdf, docxType]
    }

    static func extract(from url: URL, importedAt: Date = Date()) throws -> ExtractedMeetingPlanFile {
        guard url.isFileURL else { throw MeetingPlanFileExtractionError.unreadableFile }
        let data = try boundedRead(from: url)
        let ext = url.pathExtension.lowercased()
        let rawText: String
        let typeIdentifier: String

        switch ext {
        case "txt":
            rawText = try decodePlainText(data)
            typeIdentifier = UTType.plainText.identifier
        case "md", "markdown":
            rawText = try decodePlainText(data)
            typeIdentifier = markdownIdentifier
        case "pdf":
            rawText = try extractPDF(data)
            typeIdentifier = UTType.pdf.identifier
        case "docx":
            rawText = try extractDOCX(data)
            typeIdentifier = docxIdentifier
        default:
            throw MeetingPlanFileExtractionError.unsupportedFormat
        }

        let text = normalize(rawText)
        guard !text.isEmpty else { throw MeetingPlanFileExtractionError.emptyDocument }
        guard text.count <= maximumTextCharacters else {
            throw MeetingPlanFileExtractionError.textTooLong(maxCharacters: maximumTextCharacters)
        }

        return ExtractedMeetingPlanFile(
            text: text,
            source: MeetingPlanSource(
                fileName: url.lastPathComponent,
                typeIdentifier: typeIdentifier,
                importedAt: importedAt,
                extractedCharacterCount: text.count
            )
        )
    }

    private static func boundedRead(from url: URL) throws -> Data {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maximumFileBytes {
            throw MeetingPlanFileExtractionError.fileTooLarge(
                maxMegabytes: maximumFileBytes / 1_024 / 1_024
            )
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
            guard data.count <= maximumFileBytes else {
                throw MeetingPlanFileExtractionError.fileTooLarge(
                    maxMegabytes: maximumFileBytes / 1_024 / 1_024
                )
            }
            return data
        } catch let error as MeetingPlanFileExtractionError {
            throw error
        } catch {
            throw MeetingPlanFileExtractionError.unreadableFile
        }
    }

    private static func decodePlainText(_ data: Data) throws -> String {
        // UTF-8 first, then the Unicode encodings commonly produced by Word
        // and TextEdit. Never use lossy decoding: silent mojibake is worse
        // than a clear import error for a script the AI will later evaluate.
        let encodings: [String.Encoding] = [
            .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian,
            .utf32, .utf32LittleEndian, .utf32BigEndian
        ]
        for encoding in encodings {
            if let value = String(data: data, encoding: encoding) { return value }
        }
        throw MeetingPlanFileExtractionError.unreadableFile
    }

    private static func extractPDF(_ data: Data) throws -> String {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw MeetingPlanFileExtractionError.invalidPDF
        }
        var pages: [String] = []
        var characterCount = 0
        pages.reserveCapacity(min(document.pageCount, 500))
        for index in 0..<document.pageCount {
            if let value = document.page(at: index)?.string, !value.isEmpty {
                pages.append(value)
                characterCount += value.count
            }
            // Stop as soon as the visible text is definitely beyond the
            // accepted limit; there is no benefit in walking a huge PDF.
            if characterCount > maximumTextCharacters {
                throw MeetingPlanFileExtractionError.textTooLong(
                    maxCharacters: maximumTextCharacters
                )
            }
        }
        guard !pages.isEmpty else { throw MeetingPlanFileExtractionError.invalidPDF }
        return pages.joined(separator: "\n\n")
    }

    private static func extractDOCX(_ data: Data) throws -> String {
        let archive = try MinimalZIPArchive(data: data)
        let xml = try archive.data(
            for: "word/document.xml",
            maximumUncompressedBytes: maximumDOCXXMLBytes
        )
        let delegate = WordDocumentXMLDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw MeetingPlanFileExtractionError.invalidDOCX }
        return delegate.text
    }

    private static func normalize(_ raw: String) -> String {
        var lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0000}", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { substring -> String in
                var line = String(substring)
                while let scalar = line.unicodeScalars.last,
                      CharacterSet.whitespaces.contains(scalar) {
                    line.unicodeScalars.removeLast()
                }
                return line
            }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Minimal bounded ZIP reader (DOCX)

private nonisolated struct MinimalZIPArchive {
    private struct Entry {
        let method: UInt16
        let flags: UInt16
        let checksum: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let bytes: Data
    private let entries: [String: Entry]

    init(data: Data) throws {
        bytes = data
        guard let eocd = Self.endOfCentralDirectory(in: data),
              Self.u16(data, eocd + 4) == 0,
              Self.u16(data, eocd + 6) == 0,
              let count16 = Self.u16(data, eocd + 10),
              count16 != UInt16.max,
              let directorySize32 = Self.u32(data, eocd + 12),
              let directoryOffset32 = Self.u32(data, eocd + 16),
              directorySize32 != UInt32.max,
              directoryOffset32 != UInt32.max
        else { throw MeetingPlanFileExtractionError.invalidDOCX }

        let count = Int(count16)
        let directoryOffset = Int(directoryOffset32)
        let directorySize = Int(directorySize32)
        guard Self.range(directoryOffset, directorySize, fits: data.count) else {
            throw MeetingPlanFileExtractionError.invalidDOCX
        }

        var parsed: [String: Entry] = [:]
        var cursor = directoryOffset
        for _ in 0..<count {
            guard Self.u32(data, cursor) == 0x0201_4B50,
                  let flags = Self.u16(data, cursor + 8),
                  let method = Self.u16(data, cursor + 10),
                  let checksum = Self.u32(data, cursor + 16),
                  let compressed32 = Self.u32(data, cursor + 20),
                  let uncompressed32 = Self.u32(data, cursor + 24),
                  let nameLength = Self.u16(data, cursor + 28),
                  let extraLength = Self.u16(data, cursor + 30),
                  let commentLength = Self.u16(data, cursor + 32),
                  let localOffset32 = Self.u32(data, cursor + 42),
                  compressed32 != UInt32.max,
                  uncompressed32 != UInt32.max,
                  localOffset32 != UInt32.max
            else { throw MeetingPlanFileExtractionError.invalidDOCX }

            let nameStart = cursor + 46
            let nameCount = Int(nameLength)
            guard Self.range(nameStart, nameCount, fits: data.count),
                  let name = String(data: data[nameStart..<(nameStart + nameCount)], encoding: .utf8)
            else { throw MeetingPlanFileExtractionError.invalidDOCX }

            parsed[name] = Entry(
                method: method,
                flags: flags,
                checksum: checksum,
                compressedSize: Int(compressed32),
                uncompressedSize: Int(uncompressed32),
                localHeaderOffset: Int(localOffset32)
            )
            cursor = nameStart + nameCount + Int(extraLength) + Int(commentLength)
            guard cursor <= directoryOffset + directorySize else {
                throw MeetingPlanFileExtractionError.invalidDOCX
            }
        }
        entries = parsed
    }

    func data(for name: String, maximumUncompressedBytes: Int) throws -> Data {
        guard let entry = entries[name] else {
            throw MeetingPlanFileExtractionError.invalidDOCX
        }
        guard entry.flags & 0x0001 == 0 else {
            throw MeetingPlanFileExtractionError.encryptedDOCX
        }
        guard entry.uncompressedSize <= maximumUncompressedBytes,
              entry.compressedSize <= MeetingPlanFileExtractor.maximumFileBytes,
              Self.u32(bytes, entry.localHeaderOffset) == 0x0403_4B50,
              let nameLength = Self.u16(bytes, entry.localHeaderOffset + 26),
              let extraLength = Self.u16(bytes, entry.localHeaderOffset + 28)
        else { throw MeetingPlanFileExtractionError.invalidDOCX }

        let contentOffset = entry.localHeaderOffset + 30 + Int(nameLength) + Int(extraLength)
        guard Self.range(contentOffset, entry.compressedSize, fits: bytes.count) else {
            throw MeetingPlanFileExtractionError.invalidDOCX
        }
        let compressed = Data(bytes[contentOffset..<(contentOffset + entry.compressedSize)])
        let result: Data
        switch entry.method {
        case 0:
            result = compressed
        case 8:
            result = try Self.inflateRaw(compressed, expectedSize: entry.uncompressedSize)
        default:
            throw MeetingPlanFileExtractionError.invalidDOCX
        }
        guard result.count == entry.uncompressedSize,
              Self.crc32(of: result) == entry.checksum else {
            throw MeetingPlanFileExtractionError.invalidDOCX
        }
        return result
    }

    private static func endOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lower = max(0, data.count - (65_535 + 22))
        var index = data.count - 22
        while index >= lower {
            if u32(data, index) == 0x0605_4B50,
               let commentLength = u16(data, index + 20),
               index + 22 + Int(commentLength) == data.count {
                return index
            }
            if index == 0 { break }
            index -= 1
        }
        return nil
    }

    private static func inflateRaw(_ input: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        var stream = z_stream()
        let initialized = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else { throw MeetingPlanFileExtractionError.invalidDOCX }
        defer { inflateEnd(&stream) }

        let status: Int32 = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer<Bytef>(
                    mutating: source.bindMemory(to: Bytef.self).baseAddress
                )
                stream.avail_in = uInt(input.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(expectedSize)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, Int(stream.total_out) == expectedSize else {
            throw MeetingPlanFileExtractionError.invalidDOCX
        }
        return output
    }

    private static func crc32(of data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            UInt32(zlib.crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)))
        }
    }

    private static func range(_ offset: Int, _ count: Int, fits total: Int) -> Bool {
        offset >= 0 && count >= 0 && offset <= total && count <= total - offset
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16? {
        guard range(offset, 2, fits: data.count) else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32? {
        guard range(offset, 4, fits: data.count) else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

// MARK: - WordprocessingML text projection

private nonisolated final class WordDocumentXMLDelegate: NSObject, XMLParserDelegate {
    private var paragraphs: [String] = []
    private var current = ""
    private var insideText = false

    var text: String {
        flushParagraph()
        return paragraphs.joined(separator: "\n")
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch name {
        case "t": insideText = true
        case "tab": current.append("\t")
        case "br", "cr": current.append("\n")
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideText { current.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "t" { insideText = false }
        if name == "p" { flushParagraph() }
    }

    private func flushParagraph() {
        let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { paragraphs.append(value) }
        current = ""
    }
}
