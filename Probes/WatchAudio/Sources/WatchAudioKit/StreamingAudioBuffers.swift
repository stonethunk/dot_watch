import Foundation
import AVFAudio
import Synchronization

/// At most 120 ms of microphone audio. Overflow drops old speech; mute and
/// close discard everything and reject callbacks admitted before teardown.
public final class StreamingCaptureBuffer: Sendable {
    private struct State: Sendable { var samples: [Float] = []; var closed = false; var muted = true; var invalid = false; var dropped = 0 }
    private let state = Mutex(State())
    public let sampleRate: Double
    private let limit: Int
    public init(sampleRate: Double) throws {
        guard sampleRate.isFinite, (8_000...96_000).contains(sampleRate) else { throw WatchAudioError.invalidFrame }
        self.sampleRate = sampleRate; limit = Int(sampleRate * 0.12)
    }
    public var invalidInput: Bool { state.withLock { $0.invalid } }
    public var droppedFrames: Int { state.withLock { $0.dropped } }
    public func append(_ input: AVAudioPCMBuffer) {
        state.withLock { value in
            guard !value.closed, !value.muted else { return }
            guard input.frameLength <= 8192, input.format.sampleRate == sampleRate,
                  input.format.commonFormat == .pcmFormatFloat32, !input.format.isInterleaved,
                  (1...2).contains(input.format.channelCount), let channels = input.floatChannelData else { value.invalid = true; return }
            let length = Int(input.frameLength)
            let excess = max(0, value.samples.count + length - limit)
            if excess > 0 {
                value.dropped += excess
                value.samples.removeFirst(min(excess, value.samples.count))
            }
            for index in max(0, length - limit)..<length {
                let sample = input.format.channelCount == 1 ? channels[0][index] : (channels[0][index] + channels[1][index]) * 0.5
                guard sample.isFinite else { value.invalid = true; return }
                value.samples.append(min(1, max(-1, sample)))
            }
        }
    }
    public func drain() -> [Float] {
        state.withLock { value in
            let samples = value.samples; value.samples = []; return samples
        }
    }
    public func setMuted(_ muted: Bool) {
        state.withLock { value in
            value.muted = muted
            value.samples.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
            value.samples.removeAll()
        }
    }
    public func close() {
        state.withLock { value in
            value.closed = true; value.muted = true
            value.samples.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }; value.samples.removeAll()
        }
    }
    public nonisolated static func tap(into capture: StreamingCaptureBuffer) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { @Sendable buffer, _ in capture.append(buffer) }
    }
}

/// Bounded sequence-aware receive queue. Startup and missing-packet waits use
/// elapsed time, so rapid decoder calls cannot mistake reordering for loss.
/// Serial use required. All payloads are already authenticated by the transport.
public struct OpusJitterBuffer {
    private var packets: [UInt16: Data] = [:]
    private var next: UInt16?
    private var playing = false
    private var startedAt: ContinuousClock.Instant?
    private var lastArrival: ContinuousClock.Instant?
    private var missingSince: ContinuousClock.Instant?
    public private(set) var lostPackets = 0
    public private(set) var latePackets = 0
    public private(set) var duplicatePackets = 0
    public private(set) var overflowDrops = 0
    public init() {}
    public mutating func insert(sequence: UInt16, payload: Data, at now: ContinuousClock.Instant = .now) {
        guard !payload.isEmpty, payload.count <= NativeOpusCodec.maximumPacketBytes else { return }
        if packets[sequence] != nil { duplicatePackets += 1; return }
        if packets.isEmpty, let lastArrival, lastArrival.duration(to: now) >= .milliseconds(120) {
            playing = false; startedAt = now; missingSince = nil
        }
        if let next {
            let distance = Int16(bitPattern: sequence &- next)
            if distance < 0 {
                if playing || distance < -64 { latePackets += 1; return }
                self.next = sequence
            } else if distance > 64 { overflowDrops += packets.count; reset(); self.next = sequence }
        } else { next = sequence }
        if packets.count >= 32, let next,
           let oldest = packets.keys.min(by: { $0 &- next < $1 &- next }) {
            packets.removeValue(forKey: oldest)
            self.next = oldest &+ 1; overflowDrops += 1
        }
        if startedAt == nil { startedAt = now }
        lastArrival = now
        packets[sequence] = payload
    }
    public mutating func pop(at now: ContinuousClock.Instant = .now) -> Data? {
        guard let sequence = next else { return nil }
        if !playing {
            guard startedAt.map({ $0.duration(to: now) >= .milliseconds(120) }) == true else { return nil }
            playing = true
        }
        if let packet = packets.removeValue(forKey: sequence) {
            next = sequence &+ 1; missingSince = nil; return packet
        }
        guard !packets.isEmpty else { missingSince = nil; return nil }
        if let missingSince, missingSince.duration(to: now) >= .milliseconds(60),
           let available = packets.keys.min(by: { $0 &- sequence < $1 &- sequence }) {
            // A burst loss needs one reorder wait, not one wait per lost packet.
            next = available; self.missingSince = nil; lostPackets += Int(available &- sequence)
        } else if missingSince == nil { missingSince = now }
        return nil
    }
    public mutating func reset() { packets.removeAll(); next = nil; playing = false; startedAt = nil; lastArrival = nil; missingSince = nil }
    public var count: Int { packets.count }
}

/// A delayed audio cycle drains several real captured frames, without replacing
/// missing speech with generated audio or retaining an unbounded backlog.
public struct StreamingPCMFramer {
    private var samples: [Float] = []
    public private(set) var droppedFrames = 0
    public init() {}
    public mutating func append(_ input: [Float]) {
        samples.append(contentsOf: input)
        let excess = max(0, samples.count - 5_760)
        if excess > 0 { samples.removeFirst(excess); droppedFrames += excess }
    }
    public mutating func takeFrames(limit: Int = 3) -> [[Float]] {
        let count = min(max(0, min(limit, 3)), samples.count / NativeOpusCodec.frameCount)
        let result = (0..<count).map { n in
            Array(samples[(n * NativeOpusCodec.frameCount)..<((n + 1) * NativeOpusCodec.frameCount)])
        }
        samples.removeFirst(count * NativeOpusCodec.frameCount)
        return result
    }
    public mutating func clear() {
        samples.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }; samples.removeAll()
    }
}

/// Completion callbacks update the count immediately on the audio callback
/// queue. A late callback from an interrupted player cannot debit a new queue.
public final class PlaybackFrameCounter: Sendable {
    private struct State: Sendable { var generation: UInt64 = 0; var frames = 0 }
    private let state = Mutex(State())
    public init() {}
    public var frames: Int { state.withLock { $0.frames } }
    public func enqueue(_ frames: Int) -> UInt64 {
        state.withLock { value in value.frames += max(0, frames); return value.generation }
    }
    public func complete(_ frames: Int, generation: UInt64) {
        state.withLock { value in
            guard generation == value.generation else { return }
            value.frames = max(0, value.frames - max(0, frames))
        }
    }
    public func clear() { state.withLock { $0.generation &+= 1; $0.frames = 0 } }
}
