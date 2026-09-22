//
//  AudioHandoffServer.swift
//  Daisy
//
//  backlog 9 Ф3-B: the Mac end of "audio on request". The Mac listens
//  (Bonjour `_daisy-audio._tcp`, TLS with the key it left in the shared
//  keychain); the phone connects and offers the raw audio of sessions
//  whose text already arrived through CloudKit. The Mac takes only what
//  it lacks, writes each file to a hidden staging folder beside the
//  session (§8), hashes it, moves it into place and only then says
//  "took it" — the phone deletes nothing on less than that.
//
//  After the connection ends, every session that received audio is
//  queued for the one derived artefact the contract lets the Mac make
//  for a phone session — diarization (§3.6: owner by voice profile,
//  everyone else `Remote`) — as a child session, which then rides back
//  to the phone as text. Pending sessions are persisted, so a quit in
//  the middle loses nothing; the pass waits for the pipeline to be free.
//
//  With "delete after transcription" on, the received audio is purged
//  from the parent (and the child's copy) once the pass is done: the
//  end state is text everywhere, sound nowhere.
//

import AppKit
import DaisyCore
import Foundation
import Network
import Observation
import os

@MainActor
@Observable
final class AudioHandoffServer {
    static let shared = AudioHandoffServer()

    enum State: Equatable {
        case off
        case starting
        case listening
        case failed(String)
    }

    private(set) var state: State = .off
    private(set) var isPaired = false
    private(set) var lastPhoneName: String?
    private(set) var lastTransferAt: Date?
    private(set) var receivedFiles = 0
    private(set) var receivedBytes: Int64 = 0
    /// Session ids received but not yet diarized.
    private(set) var pendingDiarization: [String] = []
    private(set) var activeDiarization: String?

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "AudioHandoff")
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private let pendingURL: URL

    private init() {
        let appSupport = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        pendingURL = appSupport.appendingPathComponent("Daisy/audio-handoff-pending.json")
        if let data = try? Data(contentsOf: pendingURL), let ids = try? JSONDecoder().decode([String].self, from: data) {
            pendingDiarization = ids
        }
    }

    var macName: String {
        Host.current().localizedName ?? "Mac"
    }

    // MARK: - Listening

    func start() {
        guard listener == nil else { return }
        guard let psk = AudioHandoff.ensureSecret(macName: macName) else {
            state = .failed(String(localized: "Could not store the pairing key in the keychain."))
            return
        }
        isPaired = true
        do {
            let listener = try NWListener(using: AudioHandoff.parameters(psk: psk))
            listener.service = NWListener.Service(name: macName, type: AudioHandoff.serviceType)
            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    log.notice("Audio handoff listener: \(String(describing: newState), privacy: .public)")
                    switch newState {
                    case .setup, .waiting: state = .starting
                    case .ready: state = .listening
                    case .failed(let error): state = .failed(error.localizedDescription)
                    case .cancelled: state = .off
                    @unknown default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    await self?.serve(AudioHandoffLink(connection: connection))
                }
            }
            self.listener = listener
            state = .starting
            listener.start(queue: DispatchQueue(label: "app.essazanov.daisy.audio-handoff.listener"))
            log.notice("Audio handoff: listening as \(self.macName, privacy: .public)")
        } catch {
            state = .failed(error.localizedDescription)
            log.error("Audio handoff listener failed: \(error.localizedDescription, privacy: .public)")
        }
        if !pendingDiarization.isEmpty { scheduleDiarization() }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        state = .off
    }

    // MARK: - One phone

    private func serve(_ link: AudioHandoffLink) async {
        defer { link.close() }
        do {
            try await link.open()
            var received: Set<String> = []
            loop: while true {
                let message = try await link.receive()
                switch message {
                case .hello(_, let name):
                    lastPhoneName = name
                    log.notice("Audio handoff: \(name, privacy: .public) connected")
                case .offer(let sessions):
                    let wanted = await wanted(from: sessions)
                    try await link.send(.want(wanted))
                case .file(let header):
                    let ok = try await take(header, from: link)
                    if ok { received.insert(header.id) }
                case .bye:
                    break loop
                case .want, .ack:
                    // Not something the phone says; ignore.
                    continue
                }
            }
            if !received.isEmpty {
                for id in received where !pendingDiarization.contains(id) { pendingDiarization.append(id) }
                persistPending()
                await SessionStore.shared.refresh()
                scheduleDiarization()
            }
        } catch {
            log.error("Audio handoff connection ended: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Of what the phone offers, the files this Mac lacks — only for
    /// sessions the Library already knows (their text came through
    /// CloudKit) and only phone sessions.
    private func wanted(from offered: [AudioHandoff.OfferedSession]) async -> [AudioHandoff.WantedSession] {
        await SessionStore.shared.refresh()
        var out: [AudioHandoff.WantedSession] = []
        for session in offered {
            guard let stored = SessionStore.shared.sessions.first(where: { $0.id == session.id }) else { continue }
            let dir = stored.directoryURL
            guard let markdown = try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8),
                  SessionAudioProcessing.frontmatterValue("daisy_origin", in: markdown) == "iphone" else { continue }
            let missing = session.files.filter { file in
                let url = dir.appendingPathComponent(file.name)
                guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return true }
                return Int64(size) != file.size
            }
            if !missing.isEmpty {
                out.append(.init(id: session.id, files: missing.map(\.name)))
            }
        }
        return out
    }

    /// Receive one file into staging, verify, move into the session,
    /// acknowledge. Returns whether the file was taken.
    private func take(_ header: AudioHandoff.FileHeader, from link: AudioHandoffLink) async throws -> Bool {
        guard let stored = SessionStore.shared.sessions.first(where: { $0.id == header.id }),
              !header.name.contains("/"), !header.name.hasPrefix(".") else {
            // Nowhere to put it: drain the bytes so the stream stays in
            // step, then refuse.
            let sink = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-handoff-drain-\(UUID().uuidString)")
            _ = try await link.receiveFile(size: header.size, to: sink)
            try? FileManager.default.removeItem(at: sink)
            try await link.send(.ack(.init(id: header.id, name: header.name, sha256: "", ok: false)))
            return false
        }
        let fm = FileManager.default
        let dir = stored.directoryURL
        let staging = dir.deletingLastPathComponent().appendingPathComponent(".daisy-audio-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let stagedFile = staging.appendingPathComponent(header.name)
        let hash = try await link.receiveFile(size: header.size, to: stagedFile)
        guard hash == header.sha256 else {
            log.error("Audio handoff: hash mismatch for \(header.name, privacy: .public) of \(header.id, privacy: .public)")
            try await link.send(.ack(.init(id: header.id, name: header.name, sha256: hash, ok: false)))
            return false
        }
        let final = dir.appendingPathComponent(header.name)
        try? fm.removeItem(at: final)
        try fm.moveItem(at: stagedFile, to: final)
        receivedFiles += 1
        receivedBytes += header.size
        lastTransferAt = Date()
        log.notice("Audio handoff: took \(header.name, privacy: .public) (\(header.size / 1_048_576, privacy: .public) MB) for \(header.id, privacy: .public)")
        try await link.send(.ack(.init(id: header.id, name: header.name, sha256: hash, ok: true)))
        return true
    }

    // MARK: - Diarization after the fact

    private func persistPending() {
        try? JSONEncoder().encode(pendingDiarization).write(to: pendingURL, options: .atomic)
    }

    private func scheduleDiarization() {
        guard runner == nil else { return }
        runner = Task { @MainActor [weak self] in
            defer { self?.runner = nil }
            while let self, let id = pendingDiarization.first {
                let processing = SessionAudioProcessing.shared
                if processing.isRunning || processing.recordingOrFinalizeIsActive {
                    try? await Task.sleep(for: .seconds(60))
                    continue
                }
                guard let session = SessionStore.shared.sessions.first(where: { $0.id == id }) else {
                    pendingDiarization.removeFirst()
                    persistPending()
                    continue
                }
                activeDiarization = id
                do {
                    let options = SessionRetranscriptionOptions(modelID: WhisperEngine.shared.modelID, language: "auto", diarize: true)
                    let childID = try await processing.retranscribe(session, options: options)
                    log.notice("Audio handoff: diarized \(id, privacy: .public) → \(childID, privacy: .public)")
                    pendingDiarization.removeFirst()
                    persistPending()
                    purgeIfPolicySays(session.directoryURL)
                    purgeIfPolicySays(session.directoryURL.deletingLastPathComponent().appendingPathComponent(childID, isDirectory: true))
                    await SessionStore.shared.refresh()
                } catch ProcessingError.busy, ProcessingError.recordingActive {
                    try? await Task.sleep(for: .seconds(60))
                } catch {
                    log.error("Audio handoff: diarization of \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    pendingDiarization.removeFirst()
                    persistPending()
                }
                activeDiarization = nil
            }
        }
    }

    /// The Mac's own retention: "delete after transcription" purges the
    /// audio the phone handed over as soon as the pass that needed it
    /// is done — never without a transcript with content beside it.
    private func purgeIfPolicySays(_ directory: URL) {
        guard UserDefaults.standard.integer(forKey: "daisy.audioRetentionDays") == AppSettings.audioRetentionDeleteAfterTranscription else { return }
        Task.detached(priority: .utility) {
            guard RecordingSession.transcriptHasContent(in: directory) else { return }
            await AudioRetentionSweep.purgeOneSession(at: directory)
        }
    }
}
