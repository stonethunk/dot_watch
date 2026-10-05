import AVFAudio
import Foundation

public enum WatchAudioError: String, Error, Sendable {
    case codecUnavailable, invalidFrame, invalidPacket, conversionFailed
}

/// Serial-use native codec. No microphone, playback, network or persistent data.
/// Encoder input is mono 48 kHz float PCM in 20 ms frames. Converter priming may
/// consume a frame without returning a packet; callers must never replay input.
public final class NativeOpusCodec {
    public static let sampleRate = 48_000.0
    public static let frameCount = 960
    public static let maximumPacketBytes = 1275
    public let pcmFormat: AVAudioFormat
    private let opusFormat: AVAudioFormat
    private let encoder: AVAudioConverter
    private let decoder: AVAudioConverter

    public init() throws {
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let opus = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatOpus,
                  AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1]),
              let encoder = AVAudioConverter(from: pcm, to: opus),
              let decoder = AVAudioConverter(from: opus, to: pcm) else {
            throw WatchAudioError.codecUnavailable
        }
        self.pcmFormat = pcm
        self.opusFormat = opus
        self.encoder = encoder
        self.decoder = decoder
        encoder.primeMethod = .none
        decoder.primeMethod = .none
        encoder.bitRate = 24_000
    }

    public func encode(_ samples: [Float]) throws -> [Data] {
        guard samples.count == Self.frameCount, samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }),
              let input = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(Self.frameCount)),
              let channel = input.floatChannelData?[0] else { throw WatchAudioError.invalidFrame }
        input.frameLength = AVAudioFrameCount(Self.frameCount)
        samples.withUnsafeBufferPointer { source in channel.update(from: source.baseAddress!, count: source.count) }
        let output = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 2,
                                             maximumPacketSize: Self.maximumPacketBytes)
        var supplied = false
        var failure: NSError?
        let status = encoder.convert(to: output, error: &failure) { _, state in
            guard !supplied else { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, failure == nil else { throw WatchAudioError.conversionFailed }
        guard output.packetCount <= 2, output.byteLength <= 2 * Self.maximumPacketBytes else {
            throw WatchAudioError.conversionFailed
        }
        guard output.packetCount > 0 else { return [] }
        guard let descriptions = output.packetDescriptions else { throw WatchAudioError.conversionFailed }
        var result: [Data] = []
        for index in 0..<Int(output.packetCount) {
            let description = descriptions[index]
            let offset = description.mStartOffset
            let count = Int(description.mDataByteSize)
            guard offset >= 0, count > 0, count <= Self.maximumPacketBytes,
                  offset + Int64(count) <= Int64(output.byteLength) else { throw WatchAudioError.conversionFailed }
            result.append(Data(bytes: output.data.advanced(by: Int(offset)), count: count))
        }
        return result
    }

    public func decode(_ packet: Data) throws -> [Float] {
        guard !packet.isEmpty, packet.count <= Self.maximumPacketBytes else { throw WatchAudioError.invalidPacket }
        let input = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1,
                                            maximumPacketSize: Self.maximumPacketBytes)
        input.packetCount = 1
        input.byteLength = UInt32(packet.count)
        packet.withUnsafeBytes { bytes in input.data.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count) }
        guard let descriptions = input.packetDescriptions else { throw WatchAudioError.conversionFailed }
        descriptions[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                       mDataByteSize: UInt32(packet.count))
        // Opus packets may contain up to 120 ms. Bound every decoded output.
        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 5760) else {
            throw WatchAudioError.conversionFailed
        }
        var supplied = false
        var failure: NSError?
        let status = decoder.convert(to: output, error: &failure) { _, state in
            guard !supplied else { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, failure == nil, output.frameLength <= 5760,
              let samples = output.floatChannelData?[0] else { throw WatchAudioError.conversionFailed }
        let result = Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        guard result.allSatisfy(\.isFinite) else { throw WatchAudioError.conversionFailed }
        return result
    }

    public func reset() { encoder.reset(); decoder.reset() }
    public func resetEncoder() { encoder.reset() }
}
