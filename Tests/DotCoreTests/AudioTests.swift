import Foundation
import Testing
@testable import DotCore

struct AudioTests {
    @Test func wavRoundTripAndTruncation() throws {
        let pcm = Data(repeating: 0x10, count: 4800)
        let wav = try PCM16Audio.wav(samples: pcm)
        #expect(try PCM16Audio(wav: wav).samples == pcm)
        #expect(throws: DotError.invalidAudio) { try PCM16Audio(wav: wav.dropLast()) }
    }

    @Test func rejectsWrongFormatAndOversizedInput() throws {
        #expect(throws: DotError.invalidAudio) { try PCM16Audio(wav: PCM16Audio.wav(samples: Data(repeating: 0, count: 4800), sampleRate: 16000)) }
        #expect(throws: DotError.invalidAudio) { try PCM16Audio(wav: PCM16Audio.wav(samples: Data(repeating: 0, count: 24000 * 2 * 31))) }
    }
}
