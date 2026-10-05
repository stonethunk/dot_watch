import AVFAudio
import Testing
@testable import WatchAudioKit

private func buffer(rate: Double = 8_000, channels: AVAudioChannelCount = 1, frames: AVAudioFrameCount = 8192) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    result.frameLength = frames
    for channel in 0..<Int(channels) {
        result.floatChannelData![channel].update(repeating: channel == 0 ? 0.2 : 0.4, count: Int(frames))
    }
    return result
}

@Test func captureIsBoundedToFiveSeconds() throws {
    let capture = try BoundedCaptureBuffer(sampleRate: 8_000)
    let input = buffer()
    for _ in 0..<10 { capture.append(input) }
    let output = capture.take()
    #expect(output.count == 40_000)
    #expect(output.allSatisfy { $0 == 0.2 })
    #expect(!capture.invalidInput)
}

@Test func takeAndCloseRejectLateCallbacks() throws {
    let capture = try BoundedCaptureBuffer(sampleRate: 8_000)
    capture.append(buffer(frames: 10))
    #expect(capture.take().count == 10)
    capture.append(buffer(frames: 10))
    #expect(capture.take().isEmpty)
    let cancelled = try BoundedCaptureBuffer(sampleRate: 8_000)
    cancelled.append(buffer(frames: 10))
    cancelled.close()
    cancelled.append(buffer(frames: 10))
    #expect(cancelled.take().isEmpty)
}

@Test func stereoInputIsDownmixed() throws {
    let capture = try BoundedCaptureBuffer(sampleRate: 8_000)
    capture.append(buffer(channels: 2, frames: 10))
    let output = capture.take()
    #expect(output.count == 10)
    #expect(output.allSatisfy { abs($0 - 0.3) < 0.00001 })
}

@Test func badCaptureFormatsAndSamplesAreRejected() throws {
    #expect(throws: WatchAudioError.invalidFrame) { try BoundedCaptureBuffer(sampleRate: .nan) }
    let wrongRate = try BoundedCaptureBuffer(sampleRate: 8_000)
    wrongRate.append(buffer(rate: 48_000, frames: 10))
    #expect(wrongRate.invalidInput)
    #expect(wrongRate.take().isEmpty)
    let nonfinite = try BoundedCaptureBuffer(sampleRate: 8_000)
    let invalid = buffer(frames: 10)
    invalid.floatChannelData![0][0] = .nan
    nonfinite.append(invalid)
    #expect(nonfinite.invalidInput)
    #expect(nonfinite.take().isEmpty)
}
