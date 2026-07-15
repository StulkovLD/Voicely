import Foundation
import VoicelyCore

struct StatusSnapshot {
    let version: String
    let selectedModel: WhisperModel?
    let selectedModelDownloaded: Bool?
    let recommendedModel: WhisperModel
    let recommendedModelDownloaded: Bool
    let systemRAMGB: UInt64
    let transcriptBasePath: String
    let dictationsPath: String
    let callsPath: String
    let filesPath: String

    static func gather(
        version: String = VoicelyCLIVersion.current,
        defaults: UserDefaults? = nil,
        recommendedModel: WhisperModel = WhisperModel.recommended(),
        systemRAMGB: UInt64 = WhisperModel.systemRAMGB,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> StatusSnapshot {
        let selectedModel = defaults.map {
            WhisperModel.savedSelection(
                in: $0,
                systemRAMGB: systemRAMGB,
                operatingSystemVersion: operatingSystemVersion
            )
        } ?? WhisperModel.savedSelection()
        let selectedModelDownloaded = selectedModel.map { fileExists($0.modelDirectoryPath) }

        return StatusSnapshot(
            version: version,
            selectedModel: selectedModel,
            selectedModelDownloaded: selectedModelDownloaded,
            recommendedModel: recommendedModel,
            recommendedModelDownloaded: fileExists(recommendedModel.modelDirectoryPath),
            systemRAMGB: systemRAMGB,
            transcriptBasePath: TranscriptStore.baseDir.path,
            dictationsPath: TranscriptStore.directory(for: .dictations).path,
            callsPath: TranscriptStore.directory(for: .calls).path,
            filesPath: TranscriptStore.directory(for: .files).path
        )
    }

    var jsonObject: [String: Any] {
        var obj: [String: Any] = [
            "version": version,
            "recommendedModel": recommendedModel.variant,
            "recommendedModelName": recommendedModel.displayName,
            "recommendedModelDownloaded": recommendedModelDownloaded,
            "systemRAMGB": systemRAMGB,
            "paths": [
                "base": transcriptBasePath,
                "dictations": dictationsPath,
                "calls": callsPath,
                "files": filesPath,
            ],
        ]

        if let selectedModel {
            obj["selectedModel"] = selectedModel.variant
            obj["selectedModelName"] = selectedModel.displayName
            obj["selectedModelDownloaded"] = selectedModelDownloaded ?? false
            obj["modelDownloaded"] = selectedModelDownloaded ?? false
        } else {
            obj["selectedModel"] = NSNull()
            obj["selectedModelName"] = NSNull()
            obj["selectedModelDownloaded"] = NSNull()
            obj["modelDownloaded"] = recommendedModelDownloaded
        }

        return obj
    }

    var textLines: [String] {
        var lines = ["voicely \(version)"]

        if let selectedModel {
            lines.append("Selected model:     \(selectedModel.displayName) (\(selectedModel.variant)) — \(selectedModel.sizeLabel)")
            lines.append("Selected downloaded: \(Self.yesNo(selectedModelDownloaded ?? false))")
        } else {
            lines.append("Selected model:     none saved yet — app will ask on first launch")
        }

        lines.append("Recommended model:  \(recommendedModel.displayName) (\(recommendedModel.variant)) — \(recommendedModel.sizeLabel)")
        lines.append("Recommended downloaded: \(Self.yesNo(recommendedModelDownloaded))")
        lines.append("System RAM:         \(systemRAMGB) GB")
        lines.append("Transcripts:        \(transcriptBasePath)")
        lines.append("  dictations:       \(dictationsPath)")
        lines.append("  calls:            \(callsPath)")
        lines.append("  files:            \(filesPath)")
        return lines
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }
}
