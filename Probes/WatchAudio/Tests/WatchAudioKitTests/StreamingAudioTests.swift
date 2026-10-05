import AVFAudio
import Testing
@testable import WatchAudioKit

@Test func streamingMuteOverflowAndCloseDiscardSpeech() throws {
    let capture = try StreamingCaptureBuffer(sampleRate: 48_000)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
    buffer.frameLength = 8192
    buffer.floatChannelData![0].update(repeating: 0.2, count: 8192)
    capture.append(buffer)
    #expect(capture.drain().isEmpty)
    capture.setMuted(false)
    capture.append(buffer)
    #expect(capture.drain().count == 5760)
    capture.append(buffer); capture.setMuted(true)
    #expect(capture.drain().isEmpty)
    capture.setMuted(false); capture.close(); capture.append(buffer)
    #expect(capture.drain().isEmpty)
}

@Test func jitterOrdersWrapAndRejectsDuplicateLatePackets() {
    var jitter = OpusJitterBuffer()
    let start = ContinuousClock.now
    jitter.insert(sequence: 65535, payload: Data([2]), at: start)
    jitter.insert(sequence: 65534, payload: Data([1]), at: start)
    jitter.insert(sequence: 0, payload: Data([3]), at: start)
    #expect(jitter.pop(at: start.advanced(by: .milliseconds(120))) == Data([1]))
    #expect(jitter.pop(at: start.advanced(by: .milliseconds(120))) == Data([2]))
    jitter.insert(sequence: 65535, payload: Data([4]))
    #expect(jitter.pop(at: start.advanced(by: .milliseconds(120))) == Data([3]))
    #expect(jitter.count == 0)
}

@Test func jitterLossResetsWithoutUnboundedBacklog() {
    var jitter = OpusJitterBuffer()
    for n in 0..<100 { jitter.insert(sequence: UInt16(n), payload: Data([1])) }
    #expect(jitter.count <= 32)
    jitter.reset()
    for n in 0..<3 { jitter.insert(sequence: UInt16(n), payload: Data([1])) }
    let time = ContinuousClock.now.advanced(by: .milliseconds(120))
    for _ in 0..<6 { _ = jitter.pop(at: time) }
    #expect(jitter.count == 0)
    jitter.insert(sequence: 400, payload: Data([1]))
    #expect(jitter.pop() == nil)
}

@Test func captureOverflowRetainsAllFreshFramesThatFit() throws {
    let capture = try StreamingCaptureBuffer(sampleRate: 48_000)
    capture.setMuted(false)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let old = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 5000)!
    old.frameLength = 5000; old.floatChannelData![0].update(repeating: 0.1, count: 5000)
    let fresh = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    fresh.frameLength = 1024; fresh.floatChannelData![0].update(repeating: 0.2, count: 1024)
    capture.append(old); capture.append(fresh)
    let samples = capture.drain()
    #expect(samples.count == 5760)
    #expect(samples.prefix(4736).allSatisfy { $0 == 0.1 })
    #expect(samples.suffix(1024).allSatisfy { $0 == 0.2 })
    #expect(capture.droppedFrames == 264)
}

@Test func delayedMicrophoneTickDrainsThreeFramesInOrder() {
    var framer = StreamingPCMFramer()
    let input = (0..<2880).map { Float($0) / 2880 }
    framer.append(input)
    let frames = framer.takeFrames()
    #expect(frames.count == 3)
    #expect(frames.flatMap { $0 } == input)
    framer.append(Array(repeating: 0.1, count: 480))
    #expect(framer.takeFrames().isEmpty)
    framer.append(Array(repeating: 0.2, count: 480))
    #expect(framer.takeFrames().first == Array(repeating: Float(0.1), count: 480) + Array(repeating: Float(0.2), count: 480))
    #expect(framer.droppedFrames == 0)
}

@Test func microphoneFramerIsBoundedAndMuteDiscardsRemainder() {
    var framer = StreamingPCMFramer()
    framer.append(Array(repeating: 0.1, count: 7000))
    #expect(framer.droppedFrames == 1240)
    #expect(framer.takeFrames(limit: 100).count == 3)
    framer.clear()
    #expect(framer.takeFrames().isEmpty)
}

@Test func jitterWaitsForReorderingInsteadOfSkippingOnEachDecoderCall() {
    var jitter = OpusJitterBuffer()
    let start = ContinuousClock.now
    let ready = start.advanced(by: .milliseconds(120))
    for n in [0, 2, 3, 4, 5, 6, 7] { jitter.insert(sequence: UInt16(n), payload: Data([UInt8(n + 1)]), at: start) }
    #expect(jitter.pop(at: ready) == Data([1]))
    for _ in 0..<100 { #expect(jitter.pop(at: ready) == nil) }
    jitter.insert(sequence: 1, payload: Data([2]), at: ready.advanced(by: .milliseconds(30)))
    #expect(jitter.pop(at: ready.advanced(by: .milliseconds(30))) == Data([2]))
    #expect(jitter.lostPackets == 0)
}

@Test func jitterSkipsRealGapOnlyAfterDeadlineAndRejectsLatePacket() {
    var jitter = OpusJitterBuffer()
    let start = ContinuousClock.now
    let ready = start.advanced(by: .milliseconds(120))
    for n in [0, 2, 3, 4, 5, 6] { jitter.insert(sequence: UInt16(n), payload: Data([UInt8(n + 1)]), at: start) }
    #expect(jitter.pop(at: ready) == Data([1]))
    #expect(jitter.pop(at: ready) == nil)
    #expect(jitter.pop(at: ready.advanced(by: .milliseconds(59))) == nil)
    #expect(jitter.lostPackets == 0)
    #expect(jitter.pop(at: ready.advanced(by: .milliseconds(60))) == nil)
    #expect(jitter.lostPackets == 1)
    #expect(jitter.pop(at: ready.advanced(by: .milliseconds(60))) == Data([3]))
    jitter.insert(sequence: 1, payload: Data([2]))
    #expect(jitter.latePackets == 1)
}

@Test func playbackCompletionOnAudioQueueCannotDebitAnInterruptedQueue() async {
    let counter = PlaybackFrameCounter()
    let previous = counter.enqueue(960)
    counter.clear()
    let current = counter.enqueue(1920)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            counter.complete(960, generation: previous)
            continuation.resume()
        }
    }
    #expect(counter.frames == 1920)
    counter.complete(960, generation: current)
    #expect(counter.frames == 960)
}

@Test func burstPacketLossHasOneBoundedReorderWait() {
    var jitter = OpusJitterBuffer()
    let start = ContinuousClock.now
    let ready = start.advanced(by: .milliseconds(120))
    for n in [0, 4, 5, 6, 7, 8, 9] { jitter.insert(sequence: UInt16(n), payload: Data([UInt8(n + 1)]), at: start) }
    #expect(jitter.pop(at: ready) == Data([1]))
    #expect(jitter.pop(at: ready) == nil)
    #expect(jitter.pop(at: ready.advanced(by: .milliseconds(60))) == nil)
    #expect(jitter.lostPackets == 3)
    #expect(jitter.pop(at: ready.advanced(by: .milliseconds(60))) == Data([5]))
}

@Test func shortServerPacketsAndShortRepliesGetTimedStartupCushion() {
    var jitter = OpusJitterBuffer()
    let start = ContinuousClock.now
    // Packet count does not imply duration; even six small packets must wait.
    for n in 0..<6 { jitter.insert(sequence: UInt16(n), payload: Data([1]), at: start) }
    #expect(jitter.pop(at: start.advanced(by: .milliseconds(60))) == nil)
    #expect(jitter.pop(at: start.advanced(by: .milliseconds(120))) == Data([1]))
    jitter.reset()
    jitter.insert(sequence: 70, payload: Data([2]), at: start)
    #expect(jitter.pop(at: start.advanced(by: .milliseconds(120))) == Data([2]))
}

@Test func newResponseRebuffersAfterSilence() {
    var jitter = OpusJitterBuffer()
    let start = ContinuousClock.now
    jitter.insert(sequence: 1, payload: Data([1]), at: start)
    #expect(jitter.pop(at: start.advanced(by: .milliseconds(120))) == Data([1]))
    let reply = start.advanced(by: .seconds(2))
    jitter.insert(sequence: 2, payload: Data([2]), at: reply)
    #expect(jitter.pop(at: reply) == nil)
    #expect(jitter.pop(at: reply.advanced(by: .milliseconds(120))) == Data([2]))
}
