import AVFoundation
import Darwin
import Foundation

@MainActor
public final class TranscriptStorage {
    public let baseDir: URL

    public init(baseDir: URL? = nil) {
        self.baseDir = baseDir
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Voicely")
        ensureDirectories()
    }

    /// Recreate directories if user deleted/moved them
    private func ensureDirectories() {
        let fm = FileManager.default
        for sub in ["dictations", "calls", "files"] {
            let dir = baseDir.appendingPathComponent(sub)
            if !fm.fileExists(atPath: dir.path) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
                } catch {
                    NSLog("[Voicely] Failed to create directory %@: %@", dir.path, error.localizedDescription)
                }
            }
        }
    }

    private nonisolated static func escapeYAML(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private func randomSuffix() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<4).map { _ in chars.randomElement()! })
    }

    private func setFilePermissions(_ url: URL) {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("[Voicely] Failed to set permissions on %@: %@", url.path, error.localizedDescription)
        }
    }

    private func setDirectoryPermissions(_ url: URL) {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
        } catch {
            NSLog("[Voicely] Failed to set directory permissions on %@: %@", url.path, error.localizedDescription)
        }
    }

    @discardableResult
    public func saveDictation(text: String, sourceApp: String?) -> URL? {
        ensureDirectories()

        let now = Date()
        let dir = baseDir.appendingPathComponent("dictations")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let filename = formatter.string(from: now) + "-" + randomSuffix() + ".md"
        let path = dir.appendingPathComponent(filename)

        let isoFormatter = ISO8601DateFormatter()
        let app = sourceApp ?? "unknown"

        let content = "---\ntype: dictation\ndate: \(isoFormatter.string(from: now))\nsource_app: \(Self.escapeYAML(app))\n---\n\n\(text)\n"

        do {
            try content.write(to: path, atomically: true, encoding: .utf8)
            setFilePermissions(path)
            return path
        } catch {
            print("[Voicely] Failed to save dictation: \(error)")
            return nil
        }
    }

    /// Two-channel save: mic.wav + system.wav + transcript.md (human) +
    /// transcript.jsonl (one JSON object per line; partial captures prepend a
    /// `capture_meta` object). Either channel may be nil. Returns the call
    /// directory URL on success.
    @discardableResult
    public func saveCall(
        mic: AVAudioPCMBuffer?,
        system: AVAudioPCMBuffer?,
        segments: [DialogueSegment],
        startTime: Date,
        sourceApp: String?,
        captureMetadata: CallTranscriptCaptureMetadata = .complete
    ) -> URL? {
        let result = saveCallDetailed(
            mic: mic,
            system: system,
            segments: segments,
            startTime: startTime,
            sourceApp: sourceApp,
            captureMetadata: captureMetadata
        )
        return result.transcriptWasSaved ? result.directoryURL : nil
    }

    /// Saves every call artifact and reports each outcome independently.
    ///
    /// The old optional-URL API could report success after a WAV or JSONL write
    /// failed. This result is the product-facing source of truth: callers can
    /// distinguish a complete call from a transcript-only or otherwise partial
    /// artifact set without parsing logs.
    @discardableResult
    public func saveCallDetailed(
        mic: AVAudioPCMBuffer?,
        system: AVAudioPCMBuffer?,
        segments: [DialogueSegment],
        startTime: Date,
        sourceApp: String?,
        captureMetadata: CallTranscriptCaptureMetadata = .complete
    ) -> CallArtifactSaveResult {
        saveCallDetailed(
            micSource: mic.map(CallAudioArtifactSource.buffer),
            systemSource: system.map(CallAudioArtifactSource.buffer),
            callID: nil,
            expectedChannels: [],
            sourceClaim: nil,
            segments: segments,
            startTime: startTime,
            sourceApp: sourceApp,
            captureMetadata: captureMetadata
        )
    }

    /// Saves an already disk-backed call without decoding or materializing the
    /// complete channels. Source files remain untouched until every expected
    /// artifact, including the manifest, is confirmed saved.
    @discardableResult
    public func saveCallDetailed(
        sourceCapture: PendingCallClaim,
        segments: [DialogueSegment],
        sourceApp: String?,
        captureMetadata: CallTranscriptCaptureMetadata = .complete
    ) -> CallArtifactSaveResult {
        saveCallDetailed(
            micSource: sourceCapture.micFileURL.map {
                _ in CallAudioArtifactSource.claimed(sourceCapture, .mic)
            },
            systemSource: sourceCapture.systemFileURL.map {
                _ in CallAudioArtifactSource.claimed(sourceCapture, .system)
            },
            callID: sourceCapture.callID,
            expectedChannels: sourceCapture.expectedChannels,
            sourceClaim: sourceCapture,
            segments: segments,
            startTime: sourceCapture.startTime,
            sourceApp: sourceApp,
            captureMetadata: captureMetadata
        )
    }

    private enum CallAudioArtifactSource {
        case buffer(AVAudioPCMBuffer)
        case claimed(PendingCallClaim, PendingCallChannel)
    }

    private func saveCallDetailed(
        micSource: CallAudioArtifactSource?,
        systemSource: CallAudioArtifactSource?,
        callID: UUID?,
        expectedChannels: Set<PendingCallChannel>,
        sourceClaim: PendingCallClaim?,
        segments: [DialogueSegment],
        startTime: Date,
        sourceApp: String?,
        captureMetadata: CallTranscriptCaptureMetadata
    ) -> CallArtifactSaveResult {
        ensureDirectories()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let folderName = callID?.uuidString.lowercased()
            ?? formatter.string(from: startTime)

        let callDir = baseDir.appendingPathComponent("calls").appendingPathComponent(folderName)
        do {
            try prepareCallDirectory(callDir, callID: callID)
            setDirectoryPermissions(callDir)
        } catch {
            print("[Voicely] Failed to create call directory \(callDir.path): \(error)")
            var failure = CallArtifactSaveResult.directoryFailure(error.localizedDescription)
            if sourceClaim != nil { failure.sourceCleanup = .retained }
            return failure
        }

        var micStatus: CallArtifactWriteStatus
        if micSource == nil, expectedChannels.contains(.mic) {
            micStatus = .failed("captured microphone channel is missing")
        } else {
            micStatus = micSource == nil ? .notExpected : .failed("not written")
        }
        if let micSource {
            let micURL = callDir.appendingPathComponent("mic.wav")
            do {
                try saveAudioArtifact(source: micSource, to: micURL)
                setFilePermissions(micURL)
                micStatus = .saved(micURL)
            } catch {
                print("[Voicely] mic.wav save failed: \(error)")
                micStatus = .failed(error.localizedDescription)
            }
        }

        var systemStatus: CallArtifactWriteStatus
        if systemSource == nil, expectedChannels.contains(.system) {
            systemStatus = .failed("captured system channel is missing")
        } else {
            systemStatus = systemSource == nil ? .notExpected : .failed("not written")
        }
        if let systemSource {
            let sysURL = callDir.appendingPathComponent("system.wav")
            do {
                try saveAudioArtifact(source: systemSource, to: sysURL)
                setFilePermissions(sysURL)
                systemStatus = .saved(sysURL)
            } catch {
                print("[Voicely] system.wav save failed: \(error)")
                systemStatus = .failed(error.localizedDescription)
            }
        }

        let md = Self.callMarkdown(
            segments: segments,
            startTime: startTime,
            sourceApp: sourceApp,
            captureMetadata: captureMetadata
        )
        let transcriptURL = callDir.appendingPathComponent("transcript.md")
        let transcriptStatus: CallArtifactWriteStatus
        do {
            try md.write(to: transcriptURL, atomically: true, encoding: .utf8)
            setFilePermissions(transcriptURL)
            transcriptStatus = .saved(transcriptURL)
        } catch {
            print("[Voicely] transcript.md save failed: \(error)")
            transcriptStatus = .failed(error.localizedDescription)
        }

        let jsonl = Self.callJSONL(segments: segments, captureMetadata: captureMetadata)
        let jsonlStatus: CallArtifactWriteStatus
        if !jsonl.isEmpty {
            let jsonlURL = callDir.appendingPathComponent("transcript.jsonl")
            do {
                try jsonl.write(to: jsonlURL, atomically: true, encoding: .utf8)
                setFilePermissions(jsonlURL)
                jsonlStatus = .saved(jsonlURL)
            } catch {
                print("[Voicely] transcript.jsonl save failed: \(error)")
                jsonlStatus = .failed(error.localizedDescription)
            }
        } else {
            jsonlStatus = .notExpected
        }

        var result = CallArtifactSaveResult(
            directoryURL: callDir,
            directoryError: nil,
            mic: micStatus,
            system: systemStatus,
            transcript: transcriptStatus,
            jsonl: jsonlStatus,
            manifest: .failed("not written"),
            sourceCleanup: sourceClaim == nil ? .notApplicable : .retained
        )

        let manifestURL = callDir.appendingPathComponent("manifest.json")
        do {
            let data = try Self.callManifestData(
                result: result,
                callID: callID,
                sourceClaim: sourceClaim,
                startTime: startTime,
                sourceApp: sourceApp,
                captureMetadata: captureMetadata
            )
            try data.write(to: manifestURL, options: .atomic)
            setFilePermissions(manifestURL)
            result.manifest = .saved(manifestURL)
        } catch {
            print("[Voicely] manifest.json save failed: \(error)")
            result.manifest = .failed(error.localizedDescription)
        }

        if result.isComplete, let sourceClaim {
            result.sourceCleanup = sourceClaim.store.retireAndCleanup(sourceClaim)
        }

        if result.isComplete {
            print("[Voicely] Call artifacts saved to \(callDir.path)")
            if case let .failed(message) = result.sourceCleanup {
                print("[Voicely] Saved call but retained recovery source: \(message)")
            }
        } else {
            print("[Voicely] Call artifacts saved partially to \(callDir.path): \(result.failedArtifactNames.joined(separator: ", "))")
        }
        return result
    }

    nonisolated static func callMarkdown(
        segments: [DialogueSegment],
        startTime: Date,
        sourceApp: String?,
        captureMetadata: CallTranscriptCaptureMetadata = .complete
    ) -> String {
        let isoFormatter = ISO8601DateFormatter()
        let app = sourceApp ?? "unknown"

        var frontMatter: [String] = [
            "---",
            "type: call",
            "date: \(isoFormatter.string(from: startTime))",
            "source_app: \(escapeYAML(app))",
        ]
        if captureMetadata.isPartial {
            frontMatter.append("partial_capture: true")
            frontMatter.append("capture_state: \(captureMetadata.state.rawValue)")
            if let reason = captureMetadata.partialReason,
               !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                frontMatter.append("partial_reason: \(escapeYAML(reason))")
            }
            if let interruptionReason = captureMetadata.interruptionReason,
               !interruptionReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                frontMatter.append(
                    "interruption_reason: \(escapeYAML(interruptionReason))"
                )
            }
            if !captureMetadata.missingChannels.isEmpty {
                frontMatter.append("missing_channels:")
                for channel in captureMetadata.missingChannels {
                    frontMatter.append("  - \(channel)")
                }
            }
            if let mean = captureMetadata.systemMeanVolumeDBFS {
                frontMatter.append("system_mean_dbfs: \(yamlNumber(mean))")
            }
            if let peak = captureMetadata.systemPeakVolumeDBFS {
                frontMatter.append("system_peak_dbfs: \(yamlNumber(peak))")
            }
            if let duration = captureMetadata.micDurationSeconds {
                frontMatter.append("mic_duration_seconds: \(yamlNumber(duration))")
            }
            if let duration = captureMetadata.systemDurationSeconds {
                frontMatter.append("system_duration_seconds: \(yamlNumber(duration))")
            }
            if let gap = captureMetadata.channelEndGapSeconds {
                frontMatter.append("channel_end_gap_seconds: \(yamlNumber(gap))")
            }
        }
        frontMatter.append("---")

        let body: String
        if captureMetadata.isPartial {
            body = CallTranscriptMerger.humanFormat(
                segments: segments,
                captureMetadata: captureMetadata
            )
        } else {
            body = segments.isEmpty
                ? "(No speech detected)"
                : CallTranscriptMerger.humanFormat(segments: segments)
        }

        return frontMatter.joined(separator: "\n") + "\n\n" + body + "\n"
    }

    nonisolated static func callJSONL(
        segments: [DialogueSegment],
        captureMetadata: CallTranscriptCaptureMetadata = .complete
    ) -> String {
        CallTranscriptMerger.jsonlFormat(
            segments: segments,
            captureMetadata: captureMetadata
        )
    }

    private nonisolated static func yamlNumber(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private nonisolated static func callManifestData(
        result: CallArtifactSaveResult,
        callID: UUID?,
        sourceClaim: PendingCallClaim?,
        startTime: Date,
        sourceApp: String?,
        captureMetadata: CallTranscriptCaptureMetadata
    ) throws -> Data {
        var capture: [String: Any] = [
            "state": captureMetadata.state.rawValue,
            "missing_channels": captureMetadata.missingChannels,
        ]
        if let reason = captureMetadata.partialReason { capture["reason"] = reason }
        if let interruptionReason = captureMetadata.interruptionReason {
            capture["interruption_reason"] = interruptionReason
        }
        if let note = captureMetadata.note { capture["note"] = note }
        if let duration = captureMetadata.micDurationSeconds {
            capture["mic_duration_seconds"] = duration
        }
        if let duration = captureMetadata.systemDurationSeconds {
            capture["system_duration_seconds"] = duration
        }
        if let gap = captureMetadata.channelEndGapSeconds {
            capture["channel_end_gap_seconds"] = gap
        }

        var object: [String: Any] = [
            "schema_version": 1,
            "type": "call",
            "started_at": ISO8601DateFormatter().string(from: startTime),
            "source_app": sourceApp ?? "unknown",
            "capture": capture,
            "artifacts": [
                "mic.wav": result.mic.manifestValue,
                "system.wav": result.system.manifestValue,
                "transcript.md": result.transcript.manifestValue,
                "transcript.jsonl": result.jsonl.manifestValue,
            ],
        ]
        if let callID {
            object["call_id"] = callID.uuidString.lowercased()
        }
        if let sourceClaim {
            object["configured_channels"] = sourceClaim.configuredChannels
                .map(\.rawValue)
                .sorted()
            object["captured_channels"] = sourceClaim.capturedChannels
                .map(\.rawValue)
                .sorted()
            object["source_channels"] = Self.sourceChannelManifest(sourceClaim)
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func saveWav(buffer: AVAudioPCMBuffer, to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try file.write(from: buffer)
    }

    private func saveAudioArtifact(
        source: CallAudioArtifactSource,
        to destinationURL: URL
    ) throws {
        switch source {
        case let .buffer(buffer):
            try saveWav(buffer: buffer, to: destinationURL)
        case let .claimed(claim, channel):
            try installClaimedAudioFile(claim, channel: channel, at: destinationURL)
        }
    }

    /// Copies from the descriptor pinned by `PendingCallClaim`, then atomically
    /// publishes the sibling staging file. No caller-controlled source path is
    /// accepted by storage.
    private func installClaimedAudioFile(
        _ claim: PendingCallClaim,
        channel: PendingCallChannel,
        at destinationURL: URL
    ) throws {
        let fm = FileManager.default
        let staging = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? fm.removeItem(at: staging) }
        let fd = Darwin.open(
            staging.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard fd >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            try claim.copyChannel(channel, to: fd)
            guard fchmod(fd, 0o600) == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
            Darwin.close(fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
        if fm.fileExists(atPath: destinationURL.path) {
            _ = try fm.replaceItemAt(
                destinationURL,
                withItemAt: staging,
                backupItemName: nil,
                options: []
            )
        } else {
            try fm.moveItem(at: staging, to: destinationURL)
        }
    }

    private func prepareCallDirectory(_ callDir: URL, callID: UUID?) throws {
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: callDir.path)
        if !existed {
            try fm.createDirectory(at: callDir, withIntermediateDirectories: false)
        }
        var directoryInfo = stat()
        guard lstat(callDir.path, &directoryInfo) == 0,
              directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryInfo.st_uid == geteuid() else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard let callID else { return }
        let ownerURL = callDir.appendingPathComponent(".call-id")
        let expected = callID.uuidString.lowercased() + "\n"
        var ownerInfo = stat()
        let ownerLookup = lstat(ownerURL.path, &ownerInfo)
        if ownerLookup == 0 {
            guard
                  ownerInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  ownerInfo.st_uid == geteuid(),
                  ownerInfo.st_nlink == 1,
                  ownerInfo.st_mode & 0o077 == 0,
                  ownerInfo.st_size <= 64 else {
                throw CocoaError(.fileReadNoPermission)
            }
            let actual = try String(contentsOf: ownerURL, encoding: .utf8)
            guard actual == expected else {
                throw CocoaError(.fileWriteFileExists)
            }
        } else if errno != ENOENT {
            throw CocoaError(.fileReadUnknown)
        } else if existed {
            throw CocoaError(.fileWriteFileExists)
        } else {
            try expected.write(to: ownerURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownerURL.path)
        }
    }

    private nonisolated static func sourceChannelManifest(
        _ claim: PendingCallClaim
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        for channel in PendingCallChannel.allCases {
            guard let metadata = claim.metadata(for: channel) else { continue }
            var value: [String: Any] = [
                "sample_rate": metadata.sampleRate,
                "sample_count": metadata.sampleCount,
                "dropped_sample_count": metadata.droppedSampleCount,
                "zero_filled_sample_count": metadata.zeroFilledSampleCount,
                "timeline_origin_offset_seconds": metadata.timelineOriginOffsetSeconds,
                "max_clock_drift_seconds": metadata.maxClockDriftSeconds,
                "discontinuity_count": metadata.discontinuityCount,
                "is_degraded": metadata.isDegraded,
            ]
            if let failure = metadata.failure { value["failure"] = failure }
            result[channel.rawValue] = value
        }
        return result
    }
}

public enum CallArtifactWriteStatus: Sendable, Equatable {
    case saved(URL)
    case notExpected
    case failed(String)

    public var wasSaved: Bool {
        if case .saved = self { return true }
        return false
    }

    fileprivate var manifestValue: [String: Any] {
        switch self {
        case .saved(let url):
            return ["state": "saved", "file": url.lastPathComponent]
        case .notExpected:
            return ["state": "not_expected"]
        case .failed(let message):
            return ["state": "failed", "error": message]
        }
    }
}

public struct CallArtifactSaveResult: Sendable, Equatable {
    public let directoryURL: URL?
    public let directoryError: String?
    public let mic: CallArtifactWriteStatus
    public let system: CallArtifactWriteStatus
    public let transcript: CallArtifactWriteStatus
    public let jsonl: CallArtifactWriteStatus
    public internal(set) var manifest: CallArtifactWriteStatus
    public internal(set) var sourceCleanup: PendingCallCleanupStatus

    public static func directoryFailure(_ message: String) -> Self {
        Self(
            directoryURL: nil,
            directoryError: message,
            mic: .notExpected,
            system: .notExpected,
            transcript: .notExpected,
            jsonl: .notExpected,
            manifest: .notExpected,
            sourceCleanup: .notApplicable
        )
    }

    public var transcriptWasSaved: Bool { transcript.wasSaved }

    public var failedArtifactNames: [String] {
        var failures: [String] = []
        if directoryURL == nil { failures.append("call directory") }
        for (name, status) in [
            ("mic.wav", mic),
            ("system.wav", system),
            ("transcript.md", transcript),
            ("transcript.jsonl", jsonl),
            ("manifest.json", manifest),
        ] {
            if case .failed = status { failures.append(name) }
        }
        return failures
    }

    public var isComplete: Bool {
        directoryURL != nil && failedArtifactNames.isEmpty
    }

    public var isFullyFinalized: Bool {
        isComplete && !sourceCleanup.failed
    }
}
