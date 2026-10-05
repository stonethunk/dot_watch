import Foundation
import Testing
@testable import WatchAudioKit

@Test func syntheticSignalRoundTrip() throws {
    let codec = try NativeOpusCodec()
    var packets = 0
    var samples = 0
    var energy = 0.0
    for frame in 0..<25 {
        let input = (0..<960).map { index in
            Float(0.2 * sin(2 * .pi * 440 * Double(frame * 960 + index) / 48_000))
        }
        for packet in try codec.encode(input) {
            #expect(packet.count <= 1275)
            let output = try codec.decode(packet)
            #expect(output.count <= 5760)
            packets += 1
            samples += output.count
            energy += output.reduce(0.0) { $0 + Double($1 * $1) }
        }
    }
    #expect(packets >= 20)
    #expect(samples >= 19_200)
    #expect(energy > 10)
}

@Test func invalidFramesRejectedBeforeConversion() throws {
    let codec = try NativeOpusCodec()
    #expect(throws: WatchAudioError.invalidFrame) { try codec.encode([]) }
    #expect(throws: WatchAudioError.invalidFrame) { try codec.encode(Array(repeating: Float.nan, count: 960)) }
    #expect(throws: WatchAudioError.invalidFrame) { try codec.encode(Array(repeating: 2, count: 960)) }
}

@Test func packetBoundsAndReset() throws {
    let codec = try NativeOpusCodec()
    #expect(throws: WatchAudioError.invalidPacket) { try codec.decode(Data()) }
    #expect(throws: WatchAudioError.invalidPacket) { try codec.decode(Data(repeating: 0, count: 1276)) }
    for _ in 0..<3 { _ = try codec.encode(Array(repeating: 0, count: 960)) }
    codec.reset()
    let packets = try codec.encode(Array(repeating: 0, count: 960))
    #expect(packets.allSatisfy { $0.count <= 1275 })
}
