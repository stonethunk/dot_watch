import AVFAudio
import Synchronization

/// Five seconds maximum. Copies mono PCM only; close/take rejects late callbacks.
public final class BoundedCaptureBuffer: Sendable {
    private struct State: Sendable { var samples: [Float]; var closed = false; var invalid = false }
    private let state: Mutex<State>
    private let sampleRate: Double
    private let maximumFrames: Int

    public init(sampleRate: Double) throws {
        guard sampleRate.isFinite, (8_000...96_000).contains(sampleRate) else { throw WatchAudioError.invalidFrame }
        self.sampleRate = sampleRate
        maximumFrames = Int(sampleRate * 5)
        var samples: [Float] = []
        samples.reserveCapacity(maximumFrames)
        state = Mutex(State(samples: samples))
    }
    public var invalidInput: Bool { state.withLock { $0.invalid } }

    public func append(_ buffer: AVAudioPCMBuffer) {
        state.withLock { value in
            guard !value.closed else { return }
            guard buffer.frameLength <= 8192, buffer.format.sampleRate == sampleRate,
                  buffer.format.commonFormat == .pcmFormatFloat32, !buffer.format.isInterleaved,
                  (1...2).contains(buffer.format.channelCount), let channels = buffer.floatChannelData else {
                value.invalid = true
                return
            }
            let count = min(Int(buffer.frameLength), maximumFrames - value.samples.count)
            guard count > 0 else { return }
            for index in 0..<count {
                let sample = buffer.format.channelCount == 1 ? channels[0][index] : (channels[0][index] + channels[1][index]) * 0.5
                guard sample.isFinite else { value.invalid = true; return }
                value.samples.append(sample)
            }
        }
    }

    public func take() -> [Float] {
        state.withLock { $0.closed = true; let result = $0.samples; $0.samples = []; return result }
    }
    public func close() {
        state.withLock {
            $0.closed = true
            $0.samples.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
            $0.samples.removeAll()
        }
    }
}
