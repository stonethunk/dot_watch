import Foundation

/// The diagnostic accepts only the format exposed by the inspected client: 24 kHz mono PCM16.
public struct PCM16Audio: Sendable {
    public let samples: Data
    public let sampleRate: Int

    public init(wav: Data) throws {
        guard wav.count >= 44, wav.prefix(4) == Data("RIFF".utf8), wav[8..<12] == Data("WAVE".utf8) else { throw DotError.invalidAudio }
        var position = 12
        var formatOK = false
        var data: Data?
        while position <= wav.count - 8 {
            let size = Int(Self.read32(wav, position + 4))
            let start = position + 8
            guard size <= wav.count - start else { throw DotError.invalidAudio }
            let kind = wav[position..<(position + 4)]
            if kind == Data("fmt ".utf8) {
                guard size >= 16 else { throw DotError.invalidAudio }
                formatOK = Self.read16(wav, start) == 1 && Self.read16(wav, start + 2) == 1
                    && Self.read32(wav, start + 4) == 24000 && Self.read16(wav, start + 14) == 16
                    && Self.read16(wav, start + 12) == 2 && Self.read32(wav, start + 8) == 48000
            } else if kind == Data("data".utf8) { data = wav.subdata(in: start..<(start + size)) }
            position = start + size + size % 2
        }
        guard formatOK, let data, !data.isEmpty, data.count % 2 == 0, data.count <= 24000 * 2 * 30 else { throw DotError.invalidAudio }
        samples = data
        sampleRate = 24000
    }

    public static func wav(samples: Data, sampleRate: Int = 24000, channels: Int = 1) throws -> Data {
        guard sampleRate > 0, sampleRate <= 192000, channels > 0, channels <= 2,
              samples.count <= 32 * 1024 * 1024, samples.count % (channels * 2) == 0 else { throw DotError.invalidAudio }
        var result = Data("RIFF".utf8)
        append32(UInt32(36 + samples.count), to: &result)
        result.append(Data("WAVEfmt ".utf8))
        append32(16, to: &result)
        append16(1, to: &result)
        append16(UInt16(channels), to: &result)
        append32(UInt32(sampleRate), to: &result)
        append32(UInt32(sampleRate * channels * 2), to: &result)
        append16(UInt16(channels * 2), to: &result)
        append16(16, to: &result)
        result.append(Data("data".utf8))
        append32(UInt32(samples.count), to: &result)
        result.append(samples)
        return result
    }

    static func read16(_ data: Data, _ index: Int) -> UInt16 { UInt16(data[index]) | UInt16(data[index + 1]) << 8 }
    static func read32(_ data: Data, _ index: Int) -> UInt32 { UInt32(read16(data, index)) | UInt32(read16(data, index + 2)) << 16 }
    static func append16(_ value: UInt16, to data: inout Data) { data.append(UInt8(value & 255)); data.append(UInt8(value >> 8)) }
    static func append32(_ value: UInt32, to data: inout Data) { append16(UInt16(value & 65535), to: &data); append16(UInt16(value >> 16), to: &data) }
}
