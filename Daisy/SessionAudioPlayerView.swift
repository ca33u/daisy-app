// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  SessionAudioPlayerView.swift
//  Daisy
//
//  Lightweight playback for audio retained inside a Library session.
//  A recording may be split into rotated CAF parts, so the controller
//  presents them as one continuous timeline and advances automatically.
//

import AVFoundation
import Observation
import SwiftUI

nonisolated struct SessionAudioTimeline: Equatable, Sendable {
    struct Location: Equatable, Sendable {
        let partIndex: Int
        let localTime: TimeInterval
    }

    let durations: [TimeInterval]

    var totalDuration: TimeInterval {
        durations.reduce(0) { $0 + max(0, $1) }
    }

    func location(for time: TimeInterval) -> Location? {
        guard !durations.isEmpty else { return nil }
        let clamped = min(max(0, time), totalDuration)
        var start: TimeInterval = 0
        for (index, duration) in durations.enumerated() {
            let safeDuration = max(0, duration)
            let end = start + safeDuration
            if clamped < end || index == durations.count - 1 {
                return Location(
                    partIndex: index,
                    localTime: min(max(0, clamped - start), safeDuration)
                )
            }
            start = end
        }
        return nil
    }

    func startTime(of partIndex: Int) -> TimeInterval {
        guard partIndex > 0 else { return 0 }
        return durations.prefix(partIndex).reduce(0) { $0 + max(0, $1) }
    }
}

@Observable
@MainActor
final class SessionAudioTrackPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var isReady = false
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var totalDuration: TimeInterval = 0
    private(set) var errorMessage: String?

    @ObservationIgnored private var files: [URL] = []
    @ObservationIgnored private var timeline = SessionAudioTimeline(durations: [])
    @ObservationIgnored private var activePartIndex = 0
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var displayTimer: Timer?
    @ObservationIgnored private var accessTicket: SessionsFolder.AccessTicket?

    func load(_ newFiles: [URL]) {
        unload()
        guard !newFiles.isEmpty else { return }

        accessTicket = SessionsFolder.acquireAccess(
            to: newFiles[0].deletingLastPathComponent()
        )
        do {
            let durations = try newFiles.map { url -> TimeInterval in
                let file = try AVAudioFile(forReading: url)
                guard file.processingFormat.sampleRate > 0 else { return 0 }
                return Double(file.length) / file.processingFormat.sampleRate
            }
            let candidate = SessionAudioTimeline(durations: durations)
            guard candidate.totalDuration > 0 else {
                throw PlayerError.emptyAudio
            }
            files = newFiles
            timeline = candidate
            totalDuration = candidate.totalDuration
            isReady = true
        } catch {
            errorMessage = error.localizedDescription
            accessTicket?.release()
            accessTicket = nil
        }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard isReady else { return }
        if currentTime >= totalDuration - 0.05 {
            currentTime = 0
        }
        do {
            if audioPlayer == nil {
                try preparePlayer(at: currentTime)
            }
            guard audioPlayer?.play() == true else {
                throw PlayerError.couldNotPlay
            }
            isPlaying = true
            startDisplayTimer()
        } catch {
            isPlaying = false
            errorMessage = error.localizedDescription
        }
    }

    func pause() {
        updateCurrentTime()
        audioPlayer?.pause()
        isPlaying = false
        stopDisplayTimer()
    }

    func seek(to requestedTime: TimeInterval) {
        guard isReady else { return }
        let target = min(max(0, requestedTime), totalDuration)
        let shouldResume = isPlaying
        audioPlayer?.stop()
        audioPlayer = nil
        currentTime = target
        do {
            try preparePlayer(at: target)
            if shouldResume {
                guard audioPlayer?.play() == true else {
                    throw PlayerError.couldNotPlay
                }
                startDisplayTimer()
            }
        } catch {
            isPlaying = false
            stopDisplayTimer()
            errorMessage = error.localizedDescription
        }
    }

    func unload() {
        stopDisplayTimer()
        audioPlayer?.stop()
        audioPlayer = nil
        accessTicket?.release()
        accessTicket = nil
        files = []
        timeline = SessionAudioTimeline(durations: [])
        activePartIndex = 0
        isReady = false
        isPlaying = false
        currentTime = 0
        totalDuration = 0
        errorMessage = nil
    }

    private func preparePlayer(at globalTime: TimeInterval) throws {
        guard let location = timeline.location(for: globalTime),
              files.indices.contains(location.partIndex) else {
            throw PlayerError.emptyAudio
        }
        let next = try AVAudioPlayer(contentsOf: files[location.partIndex])
        next.delegate = self
        next.currentTime = location.localTime
        next.prepareToPlay()
        activePartIndex = location.partIndex
        audioPlayer = next
    }

    private func advanceAfterFinishedPart() {
        let nextPart = activePartIndex + 1
        guard files.indices.contains(nextPart) else {
            isPlaying = false
            currentTime = totalDuration
            audioPlayer = nil
            stopDisplayTimer()
            return
        }
        do {
            try preparePlayer(at: timeline.startTime(of: nextPart))
            guard audioPlayer?.play() == true else {
                throw PlayerError.couldNotPlay
            }
            isPlaying = true
        } catch {
            isPlaying = false
            stopDisplayTimer()
            errorMessage = error.localizedDescription
        }
    }

    private func updateCurrentTime() {
        guard let audioPlayer else { return }
        currentTime = min(
            totalDuration,
            timeline.startTime(of: activePartIndex) + audioPlayer.currentTime
        )
    }

    private func startDisplayTimer() {
        stopDisplayTimer()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCurrentTime()
            }
        }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.advanceAfterFinishedPart()
        }
    }
}

private enum PlayerError: LocalizedError {
    case emptyAudio
    case couldNotPlay

    var errorDescription: String? {
        switch self {
        case .emptyAudio:
            String(localized: "The audio track is empty.")
        case .couldNotPlay:
            String(localized: "Daisy couldn't play this audio track.")
        }
    }
}

struct SessionAudioPlayerView: View {
    let title: String
    let files: [URL]

    @State private var player = SessionAudioTrackPlayer()

    private var fileSignature: String {
        files.map(\.path).joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Title row spans the full width; the play button sits on the
            // NEXT row so it is vertically centered against the slider
            // (Egor 2026-08-21 — the old layout floated it against the
            // title+slider stack).
            HStack {
                Text(title)
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(formatTime(player.currentTime)) / \(formatTime(player.totalDuration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    player.togglePlayback()
                } label: {
                    // Neutral round container — no accent tint (Egor
                    // 2026-08-21: the orange pill read as a highlighted
                    // state rather than a control).
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.daisyBgElevated))
                        .overlay(Circle().strokeBorder(Color.daisyDivider, lineWidth: 0.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!player.isReady)
                .help(player.isPlaying ? String(localized: "Pause audio") : String(localized: "Play audio"))

                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(0.01, player.totalDuration)
                )
                .disabled(!player.isReady)
            }

            if let error = player.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if !player.isReady {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading audio…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: fileSignature) {
            player.load(files)
        }
        .onDisappear {
            player.unload()
        }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
