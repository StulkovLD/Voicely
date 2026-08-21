import AVFoundation
import Foundation

// MARK: - Call mixdown (the accepted call architecture, 2026-08-19)
//
// One mixed file carries the whole conversation: system audio + mic summed
// into calls/<id>/mix.wav. The mix is what gets transcribed and diarized —
// so an echo (speakers leaking into the mic) can no longer produce two
// transcripts of the same sentence, and several people sharing one mic
// separate into distinct diarized voices. The mic channel stays on disk as
// the identification reference: whichever diarized speaker overlaps the
// mic's own speech activity the most is "You".

public enum CallMixdownError: Error, LocalizedError {
    case readFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .readFailed(let detail): return "Could not read call audio for mixing. \(detail)"
        case .writeFailed(let detail): return "Could not write the call mix. \(detail)"
        }
    }
}

public enum CallMixdown {
    public static let sampleRate: Double = 16000

    /// Sum two call channels into one 16 kHz mono WAV. Either channel may be
    /// missing on disk; mixing a single present channel is legal (the mix is
    /// then a resampled copy). Returns the mix duration in seconds.
    @discardableResult
    public static func mixdown(
        system systemURL: URL?,
        mic micURL: URL?,
        to outputURL: URL
    ) throws -> Double {
        let system = try systemURL.map { try readMono16k(from: $0) } ?? []
        let mic = try micURL.map { try readMono16k(from: $0) } ?? []
        guard !system.isEmpty || !mic.isEmpty else {
            throw CallMixdownError.readFailed("both channels are empty")
        }

        var mixed = [Float](repeating: 0, count: max(system.count, mic.count))
        for i in system.indices { mixed[i] = system[i] }
        for i in mic.indices {
            mixed[i] = max(-1, min(1, mixed[i] + mic[i]))
        }

        try writeMono16k(mixed, to: outputURL)
        return Double(mixed.count) / sampleRate
    }

    /// Time ranges where the mic actually carries speech: RMS over `frame`
    /// windows against a floor, adjacent active windows merged. This is the
    /// identification signal for "You" — not a transcription input.
    public static func speechIntervals(
        in samples: [Float],
        frameSeconds: Double = 0.3,
        rmsFloor: Float = 0.012
    ) -> [(start: Double, end: Double)] {
        let frame = max(1, Int(frameSeconds * sampleRate))
        var intervals: [(start: Double, end: Double)] = []
        var i = 0
        while i < samples.count {
            let j = min(i + frame, samples.count)
            var acc: Float = 0
            for k in i..<j { acc += samples[k] * samples[k] }
            let rms = (acc / Float(j - i)).squareRoot()
            if rms >= rmsFloor {
                let start = Double(i) / sampleRate
                let end = Double(j) / sampleRate
                if let last = intervals.last, start - last.end < frameSeconds {
                    intervals[intervals.count - 1].end = end
                } else {
                    intervals.append((start, end))
                }
            }
            i = j
        }
        return intervals
    }

    public static func speechIntervals(
        micURL: URL,
        frameSeconds: Double = 0.3,
        rmsFloor: Float = 0.012
    ) throws -> [(start: Double, end: Double)] {
        speechIntervals(
            in: try readMono16k(from: micURL),
            frameSeconds: frameSeconds,
            rmsFloor: rmsFloor
        )
    }

    /// The diarized speaker whose turns the mic's own speech covers best —
    /// that cluster is the local user. `nil` when nothing overlaps enough
    /// (the user never spoke): every voice stays a remote speaker.
    public static func youSpeakerIndex(
        turns: [SpeakerTurn],
        micActivity: [(start: Double, end: Double)],
        minimumCoverage: Double = 0.3
    ) -> Int? {
        guard !turns.isEmpty, !micActivity.isEmpty else { return nil }
        var spoken: [Int: Double] = [:]
        var covered: [Int: Double] = [:]
        for turn in turns {
            spoken[turn.speakerIndex, default: 0] += turn.end - turn.start
            for window in micActivity {
                let overlap = min(turn.end, window.end) - max(turn.start, window.start)
                if overlap > 0 { covered[turn.speakerIndex, default: 0] += overlap }
            }
        }
        let best = covered
            .map { (index: $0.key, coverage: $0.value / max(spoken[$0.key] ?? 1, 0.001)) }
            .max { $0.coverage < $1.coverage }
        guard let best, best.coverage >= minimumCoverage else { return nil }
        return best.index
    }

    /// Apply the You verdict: the winning cluster's segments become `.you`
    /// (no speaker id), every other cluster stays `.other` renumbered 1..K by
    /// first appearance, so transcripts always read Speaker 1, Speaker 2 —
    /// never a gap where You used to sit.
    public static func applyYou(
        to segments: [DialogueSegment],
        youSpeakerIndex: Int?
    ) -> [DialogueSegment] {
        var remap: [Int: Int] = [:]
        var next = 1
        return segments.map { segment in
            guard let id = segment.speakerID else { return segment }
            if let youSpeakerIndex, id == youSpeakerIndex {
                return DialogueSegment(
                    speaker: .you,
                    start: segment.start,
                    end: segment.end,
                    text: segment.text,
                    language: segment.language,
                    speakerID: nil
                )
            }
            let mapped: Int
            if let existing = remap[id] {
                mapped = existing
            } else {
                mapped = next
                remap[id] = next
                next += 1
            }
            return DialogueSegment(
                speaker: .other,
                start: segment.start,
                end: segment.end,
                text: segment.text,
                language: segment.language,
                speakerID: mapped
            )
        }
    }

    // MARK: - 16 kHz mono IO

    static func readMono16k(from url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw CallMixdownError.readFailed(error.localizedDescription)
        }
        let srcFormat = file.processingFormat
        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw CallMixdownError.readFailed("could not create the 16 kHz mono format")
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw CallMixdownError.readFailed("could not allocate the input buffer")
        }
        do {
            try file.read(into: inBuf)
        } catch {
            throw CallMixdownError.readFailed(error.localizedDescription)
        }

        if abs(srcFormat.sampleRate - sampleRate) < 1,
           srcFormat.channelCount == 1,
           srcFormat.commonFormat == .pcmFormatFloat32 {
            guard let ch = inBuf.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: ch, count: Int(inBuf.frameLength)))
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw CallMixdownError.readFailed("could not create the audio converter")
        }
        let ratio = sampleRate / srcFormat.sampleRate
        let outCapacity = AVAudioFrameCount(ceil(Double(inBuf.frameLength) * ratio)) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outCapacity) else {
            throw CallMixdownError.readFailed("could not allocate the output buffer")
        }
        var convError: NSError?
        let input = SingleBufferAudioConverterInput(inBuf)
        converter.convert(to: outBuf, error: &convError) { _, outStatus in
            input.provide(status: outStatus)
        }
        if let convError {
            throw CallMixdownError.readFailed("resample failed: \(convError.localizedDescription)")
        }
        guard let ch = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
    }

    /// Hand-rolled 16-bit PCM WAV: deterministic to the last sample, where
    /// AVAudioFile's write path was measured dropping the tail block.
    static func writeMono16k(_ samples: [Float], to url: URL) throws {
        let pcm = samples.map { sample -> Int16 in
            let clamped = max(-1, min(1, sample))
            return Int16(clamped * Float(Int16.max))
        }
        let dataSize = UInt32(pcm.count * 2)
        var header = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8))
        append(36 + dataSize)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        append(16)
        append16(1)                                   // PCM
        append16(1)                                   // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)                // byte rate
        append16(2)                                   // block align
        append16(16)                                  // bits per sample
        header.append(contentsOf: Array("data".utf8))
        append(dataSize)

        var payload = header
        pcm.withUnsafeBufferPointer { buf in
            buf.baseAddress.map {
                payload.append(UnsafeBufferPointer(
                    start: UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self),
                    count: pcm.count * 2
                ))
            }
        }
        do {
            try payload.write(to: url, options: [.atomic])
        } catch {
            throw CallMixdownError.writeFailed(error.localizedDescription)
        }
    }
}
