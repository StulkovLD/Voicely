import Foundation
import XCTest
@testable import Voicely
@testable import VoicelyCore

final class CallCaptureHonestyTests: XCTestCase {
    private let rate = 48_000.0

    private func truth(
        duration: Double,
        silent: Bool = false,
        droppedSampleCount: Int = 0,
        zeroFilledSampleCount: Int = 0,
        timelineOriginOffsetSeconds: Double = 0,
        maxClockDriftSeconds: Double = 0,
        discontinuityCount: Int = 0,
        failure: String? = nil,
        isDegraded: Bool = false
    ) -> CallRecorder.ChannelCaptureTruth {
        let sampleCount = Int(duration * rate)
        return CallRecorder.ChannelCaptureTruth(
            sampleCount: sampleCount,
            sampleRate: rate,
            durationSeconds: duration,
            rms: silent ? 0.00001 : 0.05,
            peakAmplitude: silent ? 0.00001 : 0.1,
            meanVolumeDBFS: silent ? -100 : -26,
            peakVolumeDBFS: silent ? -100 : -20,
            isEffectivelySilent: silent,
            droppedSampleCount: droppedSampleCount,
            zeroFilledSampleCount: zeroFilledSampleCount,
            timelineOriginOffsetSeconds: timelineOriginOffsetSeconds,
            maxClockDriftSeconds: maxClockDriftSeconds,
            discontinuityCount: discontinuityCount,
            failure: failure,
            isDegraded: isDegraded
        )
    }

    func testAnalyzeChannelCaptureFlagsNearSilentArtifact() {
        let truth = CallRecorder.analyzeChannelCapture(
            samples: [Float](repeating: 0.00001, count: Int(rate * 3)),
            sampleRate: rate
        )

        XCTAssertTrue(truth.isEffectivelySilent)
        XCTAssertLessThan(truth.meanVolumeDBFS, -80)
        XCTAssertLessThan(truth.peakVolumeDBFS, -80)
    }

    func testAnalyzeChannelCaptureKeepsHealthySpeechNonSilent() {
        let truth = CallRecorder.analyzeChannelCapture(
            samples: [Float](repeating: 0.05, count: Int(rate * 3)),
            sampleRate: rate
        )

        XCTAssertFalse(truth.isEffectivelySilent)
        XCTAssertGreaterThan(truth.peakVolumeDBFS, -40)
    }

    func testCallCaptureMetadataMarksPartialWhenSystemChannelIsEffectivelySilent() {
        let system = CallRecorder.analyzeChannelCapture(
            samples: [Float](repeating: 0.00001, count: Int(rate * 3)),
            sampleRate: rate
        )
        let mic = CallRecorder.analyzeChannelCapture(
            samples: [Float](repeating: 0.05, count: Int(rate * 3)),
            sampleRate: rate
        )

        let metadata = AppDelegate.callCaptureMetadata(system: system, mic: mic)

        XCTAssertEqual(metadata.state, .partial)
        XCTAssertEqual(metadata.partialReason, AppDelegate.partialCallReasonSystemChannelEffectivelySilent)
        XCTAssertEqual(metadata.missingChannels, ["system"])
        XCTAssertTrue(metadata.note?.contains("effectively silent") == true)
        XCTAssertEqual(metadata.micDurationSeconds ?? .nan, 3, accuracy: 1e-9)
        XCTAssertEqual(metadata.systemDurationSeconds ?? .nan, 3, accuracy: 1e-9)
        XCTAssertEqual(metadata.channelEndGapSeconds ?? .nan, 0, accuracy: 1e-9)
        XCTAssertTrue(AppDelegate.shouldSkipSystemChannel(metadata))
    }

    func testHealthyUserStopStaysCompleteForHealthyTwoChannelCall() {
        let system = CallRecorder.analyzeChannelCapture(
            samples: [Float](repeating: 0.03, count: Int(rate * 3)),
            sampleRate: rate
        )
        let mic = CallRecorder.analyzeChannelCapture(
            samples: [Float](repeating: 0.05, count: Int(rate * 3)),
            sampleRate: rate
        )

        XCTAssertEqual(AppDelegate.callCaptureMetadata(system: system, mic: mic), .complete)
    }

    func testSynchronizedRouteInterruptionIsPartialWithHealthyEqualLengthChannels() {
        let reason = "Microphone configuration changed during call recording"
        let metadata = AppDelegate.callCaptureMetadata(
            system: truth(duration: 120),
            mic: truth(duration: 120),
            interruptionReason: reason
        )

        XCTAssertEqual(metadata.state, .partial)
        XCTAssertEqual(
            metadata.partialReason,
            AppDelegate.partialCallReasonCaptureInterrupted
        )
        XCTAssertEqual(metadata.interruptionReason, reason)
        XCTAssertEqual(metadata.missingChannels, [])
        XCTAssertEqual(metadata.channelEndGapSeconds ?? .nan, 0, accuracy: 1e-9)
        XCTAssertTrue(metadata.note?.contains(reason) == true)
        XCTAssertTrue(metadata.note?.contains("durable prefix") == true)
        XCTAssertFalse(AppDelegate.shouldSkipSystemChannel(metadata))

        let markdown = TranscriptStorage.callMarkdown(
            segments: [],
            startTime: Date(timeIntervalSince1970: 0),
            sourceApp: "Tests",
            captureMetadata: metadata
        )
        XCTAssertTrue(markdown.contains("interruption_reason: \"\(reason)\""))

        let jsonl = CallTranscriptMerger.jsonlFormat(
            segments: [],
            captureMetadata: metadata
        )
        let firstLine = try? XCTUnwrap(jsonl.split(separator: "\n").first)
        let object = firstLine.flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        XCTAssertEqual(object?["interruption_reason"] as? String, reason)
    }

    func testInterruptedCaptureSkipsOnlyAnUnavailableSystemChannel() {
        let metadata = AppDelegate.callCaptureMetadata(
            system: truth(duration: 0),
            mic: truth(duration: 30),
            interruptionReason: "Screen recording stream stopped"
        )

        XCTAssertEqual(
            metadata.partialReason,
            AppDelegate.partialCallReasonCaptureInterrupted
        )
        XCTAssertEqual(metadata.missingChannels, ["system"])
        XCTAssertTrue(AppDelegate.shouldSkipSystemChannel(metadata))
    }

    func testCallCaptureMetadataMarksMissingMicSymmetrically() {
        let metadata = AppDelegate.callCaptureMetadata(
            system: truth(duration: 30),
            mic: truth(duration: 0, silent: true)
        )

        XCTAssertEqual(metadata.state, .partial)
        XCTAssertEqual(metadata.partialReason, AppDelegate.partialCallReasonMicChannelMissing)
        XCTAssertEqual(metadata.missingChannels, ["mic"])
        XCTAssertEqual(metadata.micDurationSeconds ?? .nan, 0, accuracy: 1e-9)
        XCTAssertEqual(metadata.systemDurationSeconds ?? .nan, 30, accuracy: 1e-9)
        XCTAssertEqual(metadata.channelEndGapSeconds ?? .nan, 30, accuracy: 1e-9)
    }

    func testCallCaptureMetadataMarksMissingSystemChannel() {
        let metadata = AppDelegate.callCaptureMetadata(
            system: truth(duration: 0, silent: true),
            mic: truth(duration: 30)
        )

        XCTAssertEqual(metadata.state, .partial)
        XCTAssertEqual(metadata.partialReason, AppDelegate.partialCallReasonSystemChannelMissing)
        XCTAssertEqual(metadata.missingChannels, ["system"])
    }

    func testCallCaptureMetadataMarksSilentMicSymmetrically() {
        let metadata = AppDelegate.callCaptureMetadata(
            system: truth(duration: 30),
            mic: truth(duration: 30, silent: true)
        )

        XCTAssertEqual(metadata.state, .partial)
        XCTAssertEqual(metadata.partialReason, AppDelegate.partialCallReasonMicChannelEffectivelySilent)
        XCTAssertEqual(metadata.missingChannels, ["mic"])
    }

    func testCallCaptureMetadataReportsBothUnavailableChannelsAndSkipsSilentSystem() {
        let metadata = AppDelegate.callCaptureMetadata(
            system: truth(duration: 30, silent: true),
            mic: truth(duration: 0, silent: true)
        )

        XCTAssertEqual(metadata.state, .partial)
        XCTAssertEqual(metadata.partialReason, AppDelegate.partialCallReasonMultipleChannelsUnavailable)
        XCTAssertEqual(metadata.missingChannels, ["system", "mic"])
        XCTAssertTrue(metadata.note?.contains("System audio channel was effectively silent") == true)
        XCTAssertTrue(metadata.note?.contains("Microphone audio channel was not captured") == true)
        XCTAssertTrue(AppDelegate.shouldSkipSystemChannel(metadata))
    }

    func testCallCaptureMetadataMarksLiveArtifactMicAsTruncated() {
        let metadata = AppDelegate.callCaptureMetadata(
            system: truth(duration: 2_643.58),
            mic: truth(duration: 47.4)
        )

        XCTAssertEqual(metadata.state, .partial)
        XCTAssertEqual(metadata.partialReason, AppDelegate.partialCallReasonMicChannelTruncated)
        XCTAssertEqual(metadata.missingChannels, ["mic"])
        XCTAssertTrue(metadata.note?.contains("47.4") == true)
        XCTAssertTrue(metadata.note?.contains("2643.6") == true)
        XCTAssertEqual(metadata.micDurationSeconds ?? .nan, 47.4, accuracy: 1e-9)
        XCTAssertEqual(metadata.systemDurationSeconds ?? .nan, 2_643.58, accuracy: 1e-9)
        XCTAssertEqual(metadata.channelEndGapSeconds ?? .nan, 2_596.18, accuracy: 1e-9)
        XCTAssertFalse(AppDelegate.shouldSkipSystemChannel(metadata))
    }

    func testCallCaptureMetadataMarksFiveMinuteLossInLongCallAsPartial() {
        let metadata = AppDelegate.callCaptureMetadata(
            system: truth(duration: 3_600),
            mic: truth(duration: 3_300)
        )

        XCTAssertEqual(metadata.state, .partial)
        XCTAssertEqual(metadata.partialReason, AppDelegate.partialCallReasonMicChannelTruncated)
        XCTAssertEqual(metadata.missingChannels, ["mic"])
        XCTAssertFalse(AppDelegate.shouldSkipSystemChannel(metadata))
    }

    func testCallCaptureMetadataMarksSystemAsTruncatedSymmetrically() {
        let metadata = AppDelegate.callCaptureMetadata(
            system: truth(duration: 47.4),
            mic: truth(duration: 2_643.58)
        )

        XCTAssertEqual(metadata.state, .partial)
        XCTAssertEqual(metadata.partialReason, AppDelegate.partialCallReasonSystemChannelTruncated)
        XCTAssertEqual(metadata.missingChannels, ["system"])
        XCTAssertFalse(AppDelegate.shouldSkipSystemChannel(metadata))
    }

    func testCallCaptureMetadataReportsBoundedQueueDropsAsPartial() {
        let metadata = AppDelegate.callCaptureMetadata(
            system: truth(
                duration: 30,
                droppedSampleCount: 8_192,
                isDegraded: true
            ),
            mic: truth(duration: 30)
        )

        XCTAssertEqual(metadata.state, .partial)
        XCTAssertEqual(metadata.partialReason, AppDelegate.partialCallReasonCaptureDroppedFrames)
        XCTAssertEqual(metadata.missingChannels, ["system"])
        XCTAssertTrue(metadata.note?.contains("8192") == true)
        XCTAssertEqual(metadata.channelEndGapSeconds ?? .nan, 0, accuracy: 1e-9)
        XCTAssertFalse(AppDelegate.shouldSkipSystemChannel(metadata),
                       "the intact prefix must still be transcribed")
    }

    func testCallCaptureMetadataReportsClockDiscontinuityWithoutClaimingDrops() {
        let metadata = AppDelegate.callCaptureMetadata(
            system: truth(
                duration: 30,
                zeroFilledSampleCount: 4_800,
                timelineOriginOffsetSeconds: 0.1,
                maxClockDriftSeconds: 0.2,
                discontinuityCount: 1,
                failure: "Capture clock discontinuity detected",
                isDegraded: true
            ),
            mic: truth(duration: 30)
        )

        XCTAssertEqual(metadata.state, .partial)
        XCTAssertEqual(
            metadata.partialReason,
            AppDelegate.partialCallReasonCaptureTimelineDegraded
        )
        XCTAssertTrue(metadata.note?.contains("clock discontinuities") == true)
        XCTAssertFalse(metadata.note?.contains("dropped 0") == true)
    }

    func testAlreadyRunningCallStartRequiresConfirmedRecorderHealth() {
        XCTAssertFalse(AppDelegate.canAcceptAlreadyRunningCallRecorder(isHealthy: false))
        XCTAssertTrue(AppDelegate.canAcceptAlreadyRunningCallRecorder(isHealthy: true))
    }

    func testCallMarkdownIncludesPartialFrontMatterAndWarning() {
        let metadata = CallTranscriptCaptureMetadata(
            state: .partial,
            partialReason: AppDelegate.partialCallReasonSystemChannelEffectivelySilent,
            note: "System audio channel was effectively silent (mean -91.0 dBFS, peak -90.0 dBFS). The remote/system side may be missing from this transcript.",
            missingChannels: ["system"],
            systemMeanVolumeDBFS: -91.0,
            systemPeakVolumeDBFS: -90.0,
            micDurationSeconds: 30,
            systemDurationSeconds: 3,
            channelEndGapSeconds: 27
        )
        let segments = [
            DialogueSegment(speaker: .you, start: 0, end: 1, text: "hello", language: "en"),
        ]

        let markdown = TranscriptStorage.callMarkdown(
            segments: segments,
            startTime: Date(timeIntervalSince1970: 0),
            sourceApp: "Zoom",
            captureMetadata: metadata
        )

        XCTAssertTrue(markdown.contains("partial_capture: true"))
        XCTAssertTrue(markdown.contains("capture_state: partial"))
        XCTAssertTrue(markdown.contains("partial_reason: \"system_channel_effectively_silent\""))
        XCTAssertTrue(markdown.contains("missing_channels:\n  - system"))
        XCTAssertTrue(markdown.contains("system_mean_dbfs: -91.00"))
        XCTAssertTrue(markdown.contains("mic_duration_seconds: 30.00"))
        XCTAssertTrue(markdown.contains("system_duration_seconds: 3.00"))
        XCTAssertTrue(markdown.contains("channel_end_gap_seconds: 27.00"))
        XCTAssertTrue(markdown.contains("[Partial capture] System audio channel was effectively silent"))
        XCTAssertTrue(markdown.contains("[00:00] You"))
    }

    func testPartialJSONLPrependsCaptureMetadataLine() {
        let metadata = CallTranscriptCaptureMetadata(
            state: .partial,
            partialReason: AppDelegate.partialCallReasonSystemChannelEffectivelySilent,
            note: "System audio channel was effectively silent.",
            missingChannels: ["system"],
            systemMeanVolumeDBFS: -91.0,
            systemPeakVolumeDBFS: -90.0,
            micDurationSeconds: 30,
            systemDurationSeconds: 3,
            channelEndGapSeconds: 27
        )
        let segments = [
            DialogueSegment(speaker: .you, start: 0, end: 1, text: "hello", language: "en"),
        ]

        let jsonl = CallTranscriptMerger.jsonlFormat(
            segments: segments,
            captureMetadata: metadata
        )
        let lines = jsonl.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"type\":\"capture_meta\""))
        XCTAssertTrue(lines[0].contains("\"capture_state\":\"partial\""))
        XCTAssertTrue(lines[0].contains("\"partial_reason\":\"system_channel_effectively_silent\""))
        XCTAssertTrue(lines[0].contains("\"missing_channels\":[\"system\"]"))
        XCTAssertTrue(lines[0].contains("\"mic_duration_seconds\":30"))
        XCTAssertTrue(lines[0].contains("\"system_duration_seconds\":3"))
        XCTAssertTrue(lines[0].contains("\"channel_end_gap_seconds\":27"))
        XCTAssertTrue(lines[1].contains("\"speaker\":\"you\""))
        XCTAssertTrue(lines[1].contains("\"text\":\"hello\""))
    }
}
