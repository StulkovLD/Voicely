import Foundation

public enum CallTranscriptionProgressPhase: Sendable, Equatable {
    case preparing
    case transcribing(completedWindows: Int, totalWindows: Int)
    case diarizing
    case saving
    case finished
}

public enum CallTranscriptionProgress {
    private static let transcriptionStart = 0.05
    private static let transcriptionEnd = 0.85

    public static func fraction(for phase: CallTranscriptionProgressPhase) -> Double {
        switch phase {
        case .preparing:
            return 0.0
        case .transcribing(let completedWindows, let totalWindows):
            guard totalWindows > 0 else { return transcriptionEnd }
            let completed = min(max(0, completedWindows), totalWindows)
            let local = Double(completed) / Double(totalWindows)
            return transcriptionStart + (transcriptionEnd - transcriptionStart) * local
        case .diarizing:
            return 0.90
        case .saving:
            return 0.97
        case .finished:
            return 1.0
        }
    }

    public static func menuBarTitle(for fraction: Double) -> String {
        " \(percent(for: fraction))%"
    }

    public static func menuItemTitle(for fraction: Double) -> String {
        "Transcribing call... \(percent(for: fraction))%"
    }

    public static func windowCount(
        sampleCount: Int,
        sampleRate: Double,
        windowSeconds: Double = 30
    ) -> Int {
        guard sampleCount > 0, sampleRate > 0, windowSeconds > 0 else { return 0 }
        let windowSamples = max(1, Int(sampleRate * windowSeconds))
        return Int(ceil(Double(sampleCount) / Double(windowSamples)))
    }

    private static func percent(for fraction: Double) -> Int {
        Int((min(1.0, max(0.0, fraction)) * 100).rounded())
    }
}
