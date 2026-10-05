import AVFAudio
import Dispatch
import Testing
@testable import WatchAudioKit

// Match the production call site: create from MainActor, then let an unrelated
// audio queue invoke it. The callback must not inherit MainActor isolation.
@Test @MainActor func microphoneCallbackWorksOnAudioQueue() async throws {
    let capture = try BoundedCaptureBuffer(sampleRate: 48_000)
    let callback = SDKTapHarness(WatchAudioCallbacks.captureTap(into: capture))
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            callback.invokeSyntheticFrame()
            continuation.resume()
        }
    }
    #expect(capture.take().count == 960)
    #expect(!capture.invalidInput)
    // Closing also rejects an already-scheduled callback after cancellation.
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            callback.invokeSyntheticFrame()
            continuation.resume()
        }
    }
    #expect(capture.take().isEmpty)
}

// Deliberately mimic the SDK's legacy non-Sendable block and external queue.
// The actual block is supplied by our Sendable production factory; this box is
// test-only, and permits verifying the Objective-C-style callback boundary.
private final class SDKTapHarness: @unchecked Sendable {
    private let callback: AVAudioNodeTapBlock
    init(_ callback: @escaping AVAudioNodeTapBlock) { self.callback = callback }
    func invokeSyntheticFrame() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
        input.frameLength = 960
        input.floatChannelData![0].update(repeating: 0.2, count: 960)
        defer { input.floatChannelData![0].update(repeating: 0, count: 960) }
        let time = AVAudioTime(sampleTime: 0, atRate: 48_000)
        callback(input, time)
    }
}
