import AVFoundation
import Foundation

@MainActor
public final class TranscriptStorage {
    public let baseDir: URL

    public init() {
        baseDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Voicely")
        ensureDirectories()
    }

    /// Recreate directories if user deleted/moved them
    private func ensureDirectories() {
        let fm = FileManager.default
        for sub in ["dictations", "calls"] {
            let dir = baseDir.appendingPathComponent(sub)
            if !fm.fileExists(atPath: dir.path) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                } catch {
                    NSLog("[Voicely] Failed to create directory %@: %@", dir.path, error.localizedDescription)
                }
            }
        }
    }

    private func escapeYAML(_ value: String) -> String {
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

        let content = "---\ntype: dictation\ndate: \(isoFormatter.string(from: now))\nsource_app: \(escapeYAML(app))\n---\n\n\(text)\n"

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
    /// transcript.jsonl (one JSON object per dialogue segment).
    /// Either channel may be nil. Returns the call directory URL on success.
    @discardableResult
    public func saveCall(
        mic: AVAudioPCMBuffer?,
        system: AVAudioPCMBuffer?,
        segments: [DialogueSegment],
        startTime: Date,
        sourceApp: String?
    ) -> URL? {
        ensureDirectories()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let folderName = formatter.string(from: startTime)

        let callDir = baseDir.appendingPathComponent("calls").appendingPathComponent(folderName)
        do {
            try FileManager.default.createDirectory(at: callDir, withIntermediateDirectories: true)
        } catch {
            print("[Voicely] Failed to create call directory \(callDir.path): \(error)")
            return nil
        }

        if let mic {
            let micURL = callDir.appendingPathComponent("mic.wav")
            do {
                try saveWav(buffer: mic, to: micURL)
                setFilePermissions(micURL)
            } catch {
                print("[Voicely] mic.wav save failed: \(error)")
            }
        }
        if let system {
            let sysURL = callDir.appendingPathComponent("system.wav")
            do {
                try saveWav(buffer: system, to: sysURL)
                setFilePermissions(sysURL)
            } catch {
                print("[Voicely] system.wav save failed: \(error)")
            }
        }

        let isoFormatter = ISO8601DateFormatter()
        let app = sourceApp ?? "unknown"

        let mdBody = segments.isEmpty
            ? "(No speech detected)"
            : CallTranscriptMerger.humanFormat(segments: segments)
        let md = "---\ntype: call\ndate: \(isoFormatter.string(from: startTime))\nsource_app: \(escapeYAML(app))\n---\n\n\(mdBody)\n"
        let transcriptURL = callDir.appendingPathComponent("transcript.md")
        do {
            try md.write(to: transcriptURL, atomically: true, encoding: .utf8)
            setFilePermissions(transcriptURL)
        } catch {
            print("[Voicely] transcript.md save failed: \(error)")
            return nil
        }

        let jsonl = CallTranscriptMerger.jsonlFormat(segments: segments)
        if !jsonl.isEmpty {
            let jsonlURL = callDir.appendingPathComponent("transcript.jsonl")
            do {
                try jsonl.write(to: jsonlURL, atomically: true, encoding: .utf8)
                setFilePermissions(jsonlURL)
            } catch {
                print("[Voicely] transcript.jsonl save failed: \(error)")
            }
        }

        print("[Voicely] Call saved to \(callDir.path)")
        return callDir
    }

    private func saveWav(buffer: AVAudioPCMBuffer, to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try file.write(from: buffer)
    }
}
