//
//  RecordingSession+ArchiveAudit.swift
//  Daisy
//
//  Post-stop audit of the on-disk .caf archives (1.0.7.1
//  silent-write-death fix): classifies each stream's archive as
//  off / captured / empty / truncated so the transcript frontmatter
//  and the post-stop toasts tell the truth about what actually
//  landed on disk. Pure code motion out of RecordingSession.swift —
//  the `ArchiveStatus` enum itself stays in the main file.
//

import Foundation

extension RecordingSession {
    /// Proxy for `systemAudio.hasReceivedAudio` so MarkdownExporter
    /// (and other read-only consumers outside this type) can persist
    /// the system-audio capture outcome without us widening
    /// `systemAudio`'s visibility. True == at least one PCM frame
    /// landed during the session; false == capture was armed but
    /// stayed silent (usually BT output, or the macOS 26 SCStream
    /// regression) OR was never armed.
    var hasCapturedSystemAudio: Bool {
        systemAudio.hasReceivedAudio
    }

    // MARK: - Archive truncation audit (1.0.7.1)

    /// Minimum on-disk byte count for a CAF file to be considered
    /// "has actual audio data". CAF header + format/data chunk
    /// metadata is typically 100-200 bytes; we use a comfortable
    /// 4 KB threshold so a file that's just chunk-headers-and-nothing
    /// gets correctly classified as truncated. Picked conservatively
    /// — even a 1-second mono float32 capture at 16 kHz is 64 KB,
    /// well above this floor.
    private static let archiveDataFloorBytes: Int64 = 4096

    /// Render-thread write-error tolerance before flipping captured →
    /// truncated. A few transient errors (disk pressure, momentary
    /// device handover) are tolerable; >25 means systemic failure
    /// and the file is almost certainly partial. Matches the toast
    /// threshold the recorder uses for its post-stop summary
    /// (CoreAudioMicRecorder.stop() `if errCount > 25`).
    private static let archiveWriteErrorTolerance: Int = 25

    /// Read on-disk byte count for an archive URL. Returns 0 for
    /// missing file (FileManager throws → treat as nothing on disk).
    /// Synchronous file-system stat — only called once per stream
    /// per stop(), not in a hot loop.
    private static func archiveBytesOnDisk(_ url: URL?) -> Int64 {
        guard let url else { return 0 }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Post-stop audit of the system-audio archive. See `ArchiveStatus`
    /// docs for the four states and the failure mode each one names.
    /// Called from `stop()` after Final pass + from `MarkdownExporter`
    /// for the frontmatter line. Idempotent and side-effect-free —
    /// only reads counters + file size.
    var systemAudioArchiveStatus: ArchiveStatus {
        guard settings.captureSystemAudio, currentMode == .meeting else {
            return .off
        }
        // No archive was OPENED for this session — low disk, or the
        // "Don't record audio" retention mode. Zero frames and zero write
        // errors is then the expected outcome, not a failure, and the
        // checks below would read it as `.truncated` (buffers arrived,
        // nothing on disk) and fire a "your audio is incomplete" toast at
        // someone who never asked for audio. `.off` is the honest answer:
        // no file was expected.
        guard !audioArchivingDisabled else { return .off }
        let bytes = Self.archiveBytesOnDisk(systemArchiveURL)
        let receivedAnything = systemAudio.hasReceivedAudio
        let receivedAudible = systemAudio.receivedAudibleAudio
        let framesWritten = systemAudio.archivedFrameCount
        let (errCount, _) = systemAudio.archiveWriteErrorsSummary

        if !receivedAnything {
            // SCKit never delivered a buffer. Same case the existing
            // silenceMonitor surfaces mid-recording.
            return .empty
        }
        // Buffers arrived but EVERY one was silence (DRM-protected
        // playback, or the macOS Tahoe all-zero-buffer glitch). The file
        // can be non-trivial in size — silence still writes frames — but
        // it holds no remote audio, so report `.empty`, not `.captured`,
        // and let the frontmatter + post-stop toast tell the truth.
        if !receivedAudible {
            return .empty
        }
        // Buffer(s) arrived. Now check whether ANY of them landed on
        // disk. Three truncation paths:
        //   1. File is missing or below the data floor — open failed
        //      silently, or every write threw before the writer
        //      could grow the data chunk beyond headers.
        //   2. Frames-written counter is zero despite hasReceivedAudio
        //      — open succeeded but every write throw triggered the
        //      catch branch. The Billions 2026-05-25 failure mode.
        //   3. Write errors above tolerance — even if some frames
        //      landed, the file is so partial that the user needs
        //      to know before they try to re-summarize.
        if bytes < Self.archiveDataFloorBytes
            || framesWritten == 0
            || errCount > Self.archiveWriteErrorTolerance
        {
            return .truncated(
                bytes: bytes,
                framesWritten: framesWritten,
                writeErrors: errCount
            )
        }
        return .captured(bytes: bytes)
    }

    /// Post-stop audit of the microphone archive. Symmetric to
    /// `systemAudioArchiveStatus`.
    ///
    /// `.off` means one thing here: no archive was opened on purpose. The
    /// mic itself is never switchable off — recording it is the entire
    /// point — so a missing-permission capture still reports `.empty`,
    /// which is a real failure the user should hear about.
    var micAudioArchiveStatus: ArchiveStatus {
        // Same deliberate-no-archive case as the system stream above:
        // without it the mic reads `.empty` and the frontmatter records a
        // failure nobody had. Note this does NOT change the
        // capture-failure gate — `anyChannelCaptured` only counts
        // `.captured`, so a quiet no-archive meeting still trips it. That
        // suppression is correct (an empty transcript has nothing to
        // summarise); what it needed was an honest reason, which is why
        // `captureFailureMessage()` branches on disk vs retention.
        guard !audioArchivingDisabled else { return .off }
        // Sum every part, not just the base file. When the input format
        // changes mid-session the archive rolls over into
        // `microphone.part2.caf` and the base file can be left at zero
        // bytes — which read as `.truncated` on a recording that is
        // completely intact, stamped `daisy_mic_status: truncated` in
        // the frontmatter, put a red toast in front of the person and,
        // via `anyChannelCaptured`, suppressed the automatic summary.
        // `stop()`'s own husk check already counts frames across parts
        // for exactly this reason; the audit was left behind
        // (audit 2026-09-01).
        let bytes = Self.archiveBytesOnDisk(micArchiveURL)
            + recorder.archivedParts
                .filter { $0 != micArchiveURL }
                .reduce(0) { $0 + Self.archiveBytesOnDisk($1) }
        let framesWritten = recorder.archivedFrameCount
        let (errCount, _) = recorder.archiveWriteErrorsSummary
        let receivedAnything = framesWritten > 0 || bytes > 0

        if !receivedAnything {
            return .empty
        }
        if bytes < Self.archiveDataFloorBytes
            || framesWritten == 0
            || errCount > Self.archiveWriteErrorTolerance
        {
            return .truncated(
                bytes: bytes,
                framesWritten: framesWritten,
                writeErrors: errCount
            )
        }
        return .captured(bytes: bytes)
    }

    /// Convenience: the same three-state status MarkdownExporter
    /// writes to `daisy_system_audio_status:` frontmatter, surfaced
    /// here so the in-process `StoredSession` snapshots used by
    /// auto-send and Send-to carry the same flag. `"ok"` /
    /// `"empty"` / `nil` (capture was off, no opinion to record).
    var systemAudioStatusValue: String? {
        guard settings.captureSystemAudio else { return nil }
        return systemAudio.hasReceivedAudio ? "ok" : "empty"
    }
}
