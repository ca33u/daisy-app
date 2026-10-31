//
//  SessionProcessingSteps.swift
//  Daisy
//
//  Where a meeting is on its way from Stop to a finished card, step by
//  step (31.10), the way the phone shows it (DaisyLite ProcessingSteps,
//  Webframes 28.09 #46): the transcript, the voices, names and terms,
//  the screen text, the summary — done, running with its percent, or
//  waiting. A step that won't run isn't listed. Under the rows, why it's
//  slow when Daisy knows. Replaces the one line the summary skeleton
//  used to carry, which went away the moment any summary.json existed
//  and said nothing at all for a meeting that got no summary.
//

import SwiftUI

/// The steps a session's processing will take, decided when it starts
/// (finalize, a queue job) and kept in `SessionStore.processingPlans`.
struct ProcessingPlan: Equatable {
    enum Step: CaseIterable, Hashable {
        case transcription, voices, namesAndTerms, screenText, summary
    }

    /// Speakers are told apart (diarization runs).
    var voices: Bool
    /// The provider's polish of names and terms, and names from the
    /// conversation (finalize Stages 2b/2c).
    var namesAndTerms: Bool
    /// Screenshots exist and their text is read (Stage 3b).
    var screenText: Bool
    /// A summary will be made.
    var summary: Bool
    /// The transcript still has to be made — false when a queue job only
    /// finishes what comes after an already-run final pass.
    var transcription = true
    /// A meeting over an hour runs names and terms after the summary
    /// (`RecordingSession.polishAfterSummaryThreshold`).
    var namesAfterSummary = false

    /// Every step in the order the pipeline runs them. Diarization rides
    /// in the final pass's own blocks (`Transcriber.runStreamingFinalPass`),
    /// so Voices sits right after it and is done when it is.
    static func pipelineOrder(namesAfterSummary: Bool) -> [Step] {
        namesAfterSummary
            ? [.transcription, .voices, .screenText, .summary, .namesAndTerms]
            : [.transcription, .voices, .namesAndTerms, .screenText, .summary]
    }

    /// The steps this session takes, in pipeline order.
    var steps: [Step] {
        Self.pipelineOrder(namesAfterSummary: namesAfterSummary).filter { step in
            switch step {
            case .transcription: transcription
            case .voices: voices
            case .namesAndTerms: namesAndTerms
            case .screenText: screenText
            case .summary: summary
            }
        }
    }

    /// Each step's state at `stage`. Nil — the job hasn't reported yet
    /// (a queue job loading its model) — is the transcript starting.
    /// A stage whose step the plan left out (a gate that changed its
    /// mind) still moves the rest along by its place in the pipeline.
    func rows(at stage: SessionStore.FinalizeStage?) -> [ProcessingRow] {
        let current: Step
        var percent: Int?
        switch stage {
        case .transcribing(let p): current = .transcription; percent = p
        case .polishing: current = .namesAndTerms
        case .readingScreens: current = .screenText
        case .summarizing: current = .summary
        case nil: current = .transcription
        }
        let order = Self.pipelineOrder(namesAfterSummary: namesAfterSummary)
        let currentIndex = order.firstIndex(of: current) ?? 0
        return steps.map { step in
            let index = order.firstIndex(of: step) ?? 0
            let state: ProcessingRow.State = index < currentIndex ? .done
                : index > currentIndex ? .waiting
                : .running(step == .transcription ? percent : nil)
            return ProcessingRow(step: step, state: state)
        }
    }

    /// Frames to read in a session folder (`ScreenshotFile.isFrame`).
    /// Lists one directory — cheap enough to call when a job starts.
    static func hasScreenshots(in directory: URL) -> Bool {
        let folder = directory.appendingPathComponent("screenshots", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.contains(where: ScreenshotFile.isFrame)
    }

    /// Notes under the rows: why it's slow, and what the transcript
    /// below is while the final one is being made.
    enum Note: Equatable {
        case lowPower
        case draftBelow
    }

    static func notes(stage: SessionStore.FinalizeStage?, lowPowerMode: Bool, hasDraft: Bool) -> [Note] {
        let transcribing: Bool
        switch stage {
        case .transcribing, nil: transcribing = true
        default: transcribing = false
        }
        guard transcribing else { return [] }
        // Low Power Mode throttles the Neural Engine work several times
        // over; the 2026-10-07 meeting took its whole final pass under
        // it without a word on screen.
        var notes: [Note] = []
        if lowPowerMode { notes.append(.lowPower) }
        // Only when there is a draft: a meeting recorded with live
        // transcription off has nothing below until the pass lands.
        if hasDraft { notes.append(.draftBelow) }
        return notes
    }
}

struct ProcessingRow: Equatable, Identifiable {
    enum State: Equatable {
        case done
        /// Whole percent when known.
        case running(Int?)
        case waiting
    }

    let step: ProcessingPlan.Step
    let state: State
    var id: ProcessingPlan.Step { step }
}

/// The card's step list. Mac design language over the phone's layout:
/// the elevated rounded panel the card's banners use, rows in callout.
struct SessionProcessingStepsView: View {
    let rows: [ProcessingRow]
    let notes: [ProcessingPlan.Note]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    rowView(row)
                    if row.id != rows.last?.id {
                        Divider().overlay(Color.daisyDivider).padding(.leading, 42)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.daisyBgElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
            )
            ForEach(notes, id: \.self) { note in
                switch note {
                case .lowPower:
                    Label("Low Power Mode is on — processing takes longer.", systemImage: "bolt.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .draftBelow:
                    Text("The transcript below is the draft from the meeting; the final one, speakers and summary come next.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    private func rowView(_ row: ProcessingRow) -> some View {
        HStack(spacing: 12) {
            Group {
                switch row.state {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(Color.daisySuccess)
                case .running(let percent?):
                    StepRing(fraction: Double(percent) / 100)
                case .running(nil):
                    ProgressView().controlSize(.small)
                case .waiting:
                    Circle().strokeBorder(Color.daisyDivider, lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                }
            }
            .frame(width: 18, height: 18)
            Text(Self.title(row.step))
                .font(.callout.weight(row.state.isRunning ? .semibold : .regular))
                .foregroundStyle(row.state == .waiting ? Color.secondary : Color.daisyTextPrimary)
            Spacer(minLength: 8)
            if case .running(let percent?) = row.state {
                Text((Double(percent) / 100).formatted(.percent.precision(.fractionLength(0))))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Color.daisyAccent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    static func title(_ step: ProcessingPlan.Step) -> String {
        // Keyed: the plain words are taken by other places in other forms
        // («Транскрипция», «Саммари» as a verb on the button).
        switch step {
        case .transcription: String(localized: "processing.step.transcription", defaultValue: "Transcription")
        case .voices: String(localized: "processing.step.voices", defaultValue: "Voices")
        case .namesAndTerms: String(localized: "processing.step.namesAndTerms", defaultValue: "Names and terms")
        case .screenText: String(localized: "processing.step.screenText", defaultValue: "Text from screenshots")
        case .summary: String(localized: "processing.step.summary", defaultValue: "Summary")
        }
    }
}

private extension ProcessingRow.State {
    var isRunning: Bool { if case .running = self { true } else { false } }
}

/// A ring that fills with the share done — the phone's ProgressRing,
/// small enough for a callout row.
private struct StepRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.daisyDivider, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(Color.daisyTextPrimary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: fraction)
        }
        .frame(width: 14, height: 14)
    }
}
