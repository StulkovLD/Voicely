import Foundation
@testable import VoicelyCore

/// Test double for `SampleTranscribing`. Records every call, returns scripted
/// results, and can be configured to throw on a specific chunk index.
final class MockSampleTranscriber: SampleTranscribing, @unchecked Sendable {

    struct Call {
        let sampleCount: Int
        let translate: Bool
        let language: String?
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] {
        withLock { _calls }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Index of the call that should throw. Set before use.
    var throwOnCallIndex: Int? = nil
    /// Error to throw. Defaults to generic whisperKitFailed.
    var errorToThrow: Error = TranscriberError.whisperKitFailed("mock failure")
    /// Optional per-call sleep so tests can race pause/cancel.
    var delayPerCall: Duration? = nil
    /// Canned transcription to return. Default: one segment "mock".
    var resultProvider: (Int) -> WhisperTranscription = { index in
        WhisperTranscription(
            text: "chunk\(index)",
            segments: [
                WhisperSegment(start: 0, end: 1, text: "chunk\(index)")
            ],
            detectedLanguage: "en"
        )
    }

    func transcribeSamples(
        _ samples: [Float],
        translate: Bool,
        language: String?
    ) async throws -> WhisperTranscription {
        let idx = withLock { () -> Int in
            let i = _calls.count
            _calls.append(Call(sampleCount: samples.count,
                               translate: translate,
                               language: language))
            return i
        }

        if let delay = delayPerCall {
            try await Task.sleep(for: delay)
        }

        if let throwIdx = throwOnCallIndex, throwIdx == idx {
            throw errorToThrow
        }
        return resultProvider(idx)
    }
}
