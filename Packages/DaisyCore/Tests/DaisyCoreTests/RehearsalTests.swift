import Foundation
import Testing
@testable import DaisyCore

private let pitch = """
Привет! Меня зовут Мария, и мы делаем сервис для записи встреч.

Каждый день мы теряем решения, которые приняли на звонках. Мы теряем их, потому что никто не записывает.

Daisy записывает встречу и сама пишет итоги. Попробуйте сегодня.
"""

@Suite("Rehearsal: the script")
struct RehearsalScriptTests {
    @Test func paragraphsWordsAndAnEstimate() {
        let script = RehearsalScript(text: pitch)
        #expect(script.paragraphs.count == 3)
        #expect(script.words.first?.key == "привет")
        #expect(script.words.first?.text == "Привет!")
        #expect(script.words.last?.paragraph == 2)
        // 32 words at 140 wpm ≈ 13.7 s.
        #expect(abs(script.estimatedSeconds() - Double(script.words.count) / 140 * 60) < 0.001)
    }

    @Test func similarWordsTolerateWhatWhisperDoes() {
        #expect(WordKey.similar("договору", "договора"))
        #expect(WordKey.similar("записывает", "записывают"))
        #expect(!WordKey.similar("мы", "вы"))
        #expect(WordKey.normalize("Ёлка,") == "елка")
        // Heard on the phone's Whisper, 23.09: the script said «Daisy».
        #expect(WordKey.similar("daisy", "дэйзи"))
        #expect(WordKey.similar("zoom", "зуме"))
    }
}

@Suite("Rehearsal: the prompter follows the voice")
struct PrompterFollowerTests {
    private func words(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

    @Test func readingMovesItForward() {
        var f = PrompterFollower(script: RehearsalScript(text: pitch))
        f.hear(words("Привет меня зовут"))
        #expect(f.position == 3)
        f.hear(words("Привет меня зовут Мария и мы делаем"))
        #expect(f.position == 7)
    }

    @Test func silenceAndStumblingDoNotMoveIt() {
        var f = PrompterFollower(script: RehearsalScript(text: pitch))
        f.hear(words("Привет меня зовут Мария"))
        let here = f.position
        f.hear(words("Привет меня зовут Мария"))
        #expect(f.position == here)
        f.hear(words("Привет меня зовут Мария э-э ну как бы"))
        #expect(f.position == here)
    }

    /// «мы теряем» appears twice in paragraph two: having read past the
    /// second, a stray echo of the first must not pull the prompter back.
    @Test func aRepeatedPhraseDoesNotPullItBack() {
        let script = RehearsalScript(text: pitch)
        var f = PrompterFollower(script: script)
        f.jump(to: script.words.firstIndex { $0.key == "потому" }!)
        let here = f.position
        f.hear(words("мы теряем"))
        #expect(f.position >= here)
    }

    @Test func aSkippedParagraphIsJumpedOver() {
        var f = PrompterFollower(script: RehearsalScript(text: pitch))
        f.hear(words("Привет меня зовут Мария"))
        f.hear(words("Daisy записывает встречу и сама пишет"))
        let script = f.script
        #expect(script.words[f.position - 1].key == "пишет")
    }
}

@Suite("Rehearsal: the take, word by word")
struct TakeAnalysisTests {
    private func timed(_ text: String, start: Double = 0, step: Double = 0.4, pauseAfter: [Int: Double] = [:]) -> [WordTiming] {
        var t = start
        return text.split(separator: " ").enumerated().map { index, word in
            defer { t += step + (pauseAfter[index] ?? 0) }
            return WordTiming(w: String(word), s: t, e: t + step * 0.9)
        }
    }

    @Test func omissionsSubstitutionsAndInsertionsAreFound() {
        let script = RehearsalScript(text: "Мы делаем сервис для записи встреч.")
        let take = TakeAnalysis(script: script, spoken: timed("Мы ну делаем продукт для встреч"))
        #expect(take.inserted == 1)       // «ну»
        #expect(take.substituted == 1)    // сервис → продукт
        #expect(take.omitted == 1)        // записи
        #expect(take.accuracy > 0.6 && take.accuracy < 0.7)
    }

    @Test func theMarkedTextSaysWhatHappened() {
        let script = RehearsalScript(text: "Мы делаем сервис для записи встреч.")
        let spoken = timed("Мы ну делаем продукт для встреч")
        let take = TakeAnalysis(script: script, spoken: spoken)
        #expect(take.markedText(script: script, spoken: spoken)
                == "Мы [+ну] делаем [сервис → продукт] для [−записи] встреч.")
        let range = TakeAnalysis.speechRange(of: spoken)
        #expect(range?.lowerBound == 0)
        #expect((range?.upperBound ?? 0) > spoken.last!.e)
    }

    @Test func paceIsPerParagraphNotOneAverage() {
        let script = RehearsalScript(text: "раз два три четыре\n\nпять шесть семь восемь")
        var spoken = timed("раз два три четыре", step: 0.25)
        spoken += timed("пять шесть семь восемь", start: 1.2, step: 0.6)
        let take = TakeAnalysis(script: script, spoken: spoken)
        #expect(take.paces.count == 2)
        #expect(take.paces[0].wordsPerMinute > take.paces[1].wordsPerMinute * 2)
    }

    @Test func longGapsArePausesAndTheLengthMeetsTheTarget() {
        let script = RehearsalScript(text: "раз два три")
        let take = TakeAnalysis(script: script, spoken: timed("раз два три", pauseAfter: [0: 1.5]), target: 60)
        #expect(take.pauses.count == 1)
        #expect(take.pauses[0].seconds >= 1.5)
        #expect(take.target == 60)
        #expect(take.duration > 2)
    }
}

@Suite("Rehearsal: subtitles")
struct SubtitlesTests {
    @Test func shortCuesBrokenAtSentencesAndPauses() {
        let words = [
            WordTiming(w: "Привет!", s: 0.0, e: 0.4),
            WordTiming(w: "Меня", s: 0.5, e: 0.7), WordTiming(w: "зовут", s: 0.7, e: 1.0), WordTiming(w: "Мария,", s: 1.0, e: 1.4),
            WordTiming(w: "и", s: 2.3, e: 2.4), WordTiming(w: "это", s: 2.4, e: 2.6), WordTiming(w: "Daisy.", s: 2.6, e: 3.0),
        ]
        let cues = Subtitles.cues(from: words)
        #expect(cues.map(\.text) == ["Привет!", "Меня зовут Мария,", "и это Daisy."])
        let srt = Subtitles.srt(cues)
        #expect(srt.hasPrefix("1\n00:00:00,000 --> 00:00:00,400\nПривет!\n"))
        #expect(Subtitles.vtt(cues).hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:00.400\nПривет!\n"))
        #expect(cues.allSatisfy { $0.text.count <= Subtitles.maxCharacters })
    }
}

@Suite("Rehearsal: script.md")
struct ScriptDocumentTests {
    @Test func aTakeCarriesItsTextAndIdentity() throws {
        let doc = ScriptDocument(title: "Питч \"Daisy\"", text: "Первый абзац.\n\nВторой абзац.", targetSeconds: 60)
        let back = try #require(ScriptDocument.parse(doc.render()))
        #expect(back == doc)
        #expect(doc.frontmatterFields.map(\.key) == ["daisy_script_id", "daisy_target_sec"])
        #expect(RehearsalScript(text: back.text).paragraphs.count == 2)
    }
}
