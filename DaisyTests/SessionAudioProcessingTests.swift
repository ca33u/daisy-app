import AVFoundation
import Foundation
import Testing
@testable import Daisy

@Suite("Stored session audio processing")
struct SessionAudioProcessingTests {
    @Test("Retained CAF parts are discovered in recording order")
    func discoversAudioParts() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in [
            "microphone.part10.caf",
            "microphone.caf",
            "microphone.part2.caf",
            "microphone.partial.caf",
            "microphone.partx.caf",
            "system_audio.part3.caf",
            "system_audio.caf",
            "notes.caf",
        ] {
            try Data().write(to: directory.appendingPathComponent(name))
        }

        let files = SessionAudioFiles.discover(in: directory)
        #expect(files.microphone.map(\.lastPathComponent) == [
            "microphone.caf",
            "microphone.part2.caf",
            "microphone.part10.caf",
        ])
        #expect(files.system.map(\.lastPathComponent) == [
            "system_audio.caf",
            "system_audio.part3.caf",
        ])
    }

    @Test("Derived session IDs include sub-second precision")
    func derivedIDsDoNotCollideWithinOneSecond() {
        let first = SessionAudioProcessing.derivedSessionID(
            parentID: "meeting-42",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let second = SessionAudioProcessing.derivedSessionID(
            parentID: "meeting-42",
            now: Date(timeIntervalSince1970: 1_700_000_000.125)
        )

        #expect(first.hasPrefix("meeting-42-retranscribed-"))
        #expect(first != second)
    }

    @Test("Derived transcript preserves metadata but replaces old content")
    @MainActor
    func rendersIndependentTranscript() {
        let directory = FileManager.default.temporaryDirectory
        let session = StoredSession(
            id: "source-session",
            directoryURL: directory,
            title: "Design review",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSec: 90,
            locale: "en",
            transcriptPreview: "Old words",
            transcriptText: "Old words",
            hasMicAudio: true,
            hasSystemAudio: true,
            screenshotURLs: [],
            screenshotOffsets: [:],
            screenshotHighlights: [],
            summary: nil,
            transcriptURL: nil,
            folderSlug: "inbox",
            kind: .recording,
            tag: "product",
            meetingAttendees: [],
            meetingAttendeeEmails: [],
            linkedEventTitle: nil,
            meetingPreparation: nil,
            planAnalysis: nil,
            planAnalysisError: nil,
            speakerMap: [:],
            speakerCentroidIDs: [],
            systemAudioStatus: "ok"
        )
        let segment = TranscriptSegment(
            id: UUID(),
            startedAt: session.startedAt.addingTimeInterval(2),
            text: "Fresh words",
            isFinal: true,
            source: .systemAudio,
            speakerId: "A",
            endSec: 4,
            startSec: 2
        )
        let markdown = SessionAudioProcessing.renderDerivedTranscript(
            originalMarkdown: "---\ncustom_field: keep-me\n---\n\n## Summary\nOld summary\n\n## Transcript\nOld words",
            session: session,
            options: SessionRetranscriptionOptions(
                modelID: "large-v3-v20240930_626MB",
                language: "en",
                diarize: true
            ),
            segments: [segment],
            audioFiles: ["microphone.caf", "system_audio.caf"]
        )

        #expect(markdown.contains("custom_field: keep-me"))
        #expect(markdown.contains("title: \"Design review — re-transcribed\""))
        #expect(markdown.contains("daisy_parent_session: \"source-session\""))
        #expect(markdown.contains("daisy_diarization: true"))
        #expect(markdown.contains("Fresh words"))
        #expect(markdown.contains("microphone.caf"))
        #expect(!markdown.contains("Old summary"))
        #expect(!markdown.contains("Old words"))

        let firstTranscript = SessionAudioProcessing.renderDerivedTranscript(
            originalMarkdown: "",
            session: session,
            options: SessionRetranscriptionOptions(
                modelID: "large-v3-v20240930_626MB",
                language: "en",
                diarize: true
            ),
            segments: [segment],
            audioFiles: ["microphone.caf"],
            isFirstTranscript: true
        )
        #expect(firstTranscript.contains("title: \"Design review\""))
        #expect(!firstTranscript.contains("re-transcribed"))
        #expect(!firstTranscript.contains("daisy_parent_session"))
        #expect(firstTranscript.contains("duration_sec: 90"))
    }

    @Test("Names given on the phone follow their voice into the Mac's re-diarization")
    func phoneNamesCarryIntoTheChild() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("carry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try JSONEncoder().encode(SpeakerCentroidsFile(centroids: ["A": [1, 0], "B": [0, 1]]))
            .write(to: dir.appendingPathComponent("speakers.json"))
        let parent = "---\ndaisy_origin: iphone\ndaisy_speaker_map: {B: \"Egor\"}\n---\n"
        let carried = SessionAudioProcessing.namesFromParent(originalMarkdown: parent, directory: dir,
                                                             to: ["A": [0.1, 0.99], "B": [0.99, 0.1]])
        #expect(carried == ["A": "Egor"])
        #expect(SessionAudioProcessing.namesFromParent(originalMarkdown: "---\ndaisy_speaker_map: {}\n---\n",
                                                       directory: dir, to: ["A": [1, 0]]).isEmpty)
    }

    @Test("M4A export combines retained tracks into a readable file")
    func exportsM4A() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let microphone = directory.appendingPathComponent("microphone.caf")
        let system = directory.appendingPathComponent("system_audio.caf")
        try writeSineCAF(to: microphone, sampleRate: 44_100, frames: 11_025)
        try writeSineCAF(to: system, sampleRate: 48_000, frames: 12_000)

        let destination = directory.appendingPathComponent("combined.m4a")
        try SessionM4AExporter.export(
            files: SessionAudioFiles.discover(in: directory),
            to: destination
        )

        let output = try AVAudioFile(forReading: destination)
        #expect(output.length > 0)
        #expect(output.processingFormat.channelCount == 1)
        #expect((try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-audio-processing-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSineCAF(
        to url: URL,
        sampleRate: Double,
        frames: AVAudioFrameCount
    ) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        let increment = 2 * Double.pi * 440 / sampleRate
        for index in 0..<Int(frames) {
            samples[index] = 0.25 * Float(sin(Double(index) * increment))
        }
        let output = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try output.write(from: buffer)
    }
}
