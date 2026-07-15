@preconcurrency import AVFoundation
import Foundation

/// Thread-safe one-shot provider for `AVAudioConverter` input closures.
/// Swift 6 treats those closures as concurrently executable, so a captured
/// mutable Boolean is a real data-race warning even when a converter currently
/// invokes it synchronously.
final class SingleBufferAudioConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var consumed = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func provide(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.withLock {
            guard !consumed else {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
    }
}
