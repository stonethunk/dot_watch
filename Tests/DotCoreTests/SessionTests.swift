import Foundation
import Testing
@testable import DotCore

@MainActor private final class Trace { var events: [String] = [] }

@MainActor private final class SignalingFixture: DotVoiceSignaling {
    let trace: Trace
    var allocationNeedsReconciliation = false
    var pauseCreate = false
    var createContinuation: CheckedContinuation<Void, Never>?
    var failStop = false
    var pauseStop = false
    var stopContinuation: CheckedContinuation<Void, Never>?
    var sequence = 0
    init(_ trace: Trace) { self.trace = trace }
    func create(dot: DotIdentity, offerSDP: String) async throws -> DotVoiceConnection {
        sequence += 1
        trace.events.append("create\(sequence)")
        if pauseCreate { await withCheckedContinuation { createContinuation = $0 } }
        return try DotVoiceConnection(dotID: dot.dotID, location: "/rtc_\(sequence)", answer: Data("v=0\r\n".utf8))
    }
    func attach(_ call: DotVoiceConnection) async throws { trace.events.append("attach") }
    func stop(_ call: DotVoiceConnection) async throws {
        trace.events.append("stop")
        if pauseStop { await withCheckedContinuation { stopContinuation = $0 } }
        if failStop { throw DotError.http(503) }
        trace.events.append("ack")
    }
}

@MainActor private final class MediaFixture: DotVoiceMedia {
    let trace: Trace
    var closed = false
    var failClosure = false
    var pauseActivation = false
    var activationContinuation: CheckedContinuation<Void, Never>?
    init(_ trace: Trace) { self.trace = trace }
    func prepareOffer() async throws -> String { trace.events.append("offer"); return "v=0\r\n" }
    func acceptAnswer(_ sdp: String) async throws { trace.events.append("answer") }
    func waitUntilReady() async throws { trace.events.append("ready") }
    func enableAudio(muted: Bool) async throws {
        if pauseActivation { await withCheckedContinuation { activationContinuation = $0 } }
        guard !closed else { throw DotError.disconnected }
        trace.events.append("audio")
    }
    func setMuted(_ muted: Bool) { trace.events.append(muted ? "mute" : "unmute") }
    func close() { if !closed { trace.events.append("close"); closed = true } }
    func waitUntilClosed() async throws {
        if failClosure { throw DotError.timeout }
        trace.events.append("media-closed-ack")
    }
}

@MainActor struct SessionTests {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw DotError.timeout
    }

    @Test func endDuringAllocationStopsReturnedCallWithoutOpeningMicrophone() async throws {
        let trace = Trace(), signaling: SignalingFixture
        signaling = SignalingFixture(trace)
        signaling.pauseCreate = true
        let coordinator = DotSessionCoordinator(signaling: signaling)
        let dot = try DotIdentity(primary: IdentityTests().fixture())
        coordinator.start(surface: .phone, dot: dot) { MediaFixture(trace) }
        try await wait { signaling.createContinuation != nil }
        coordinator.end()
        #expect(trace.events.contains("close"))
        signaling.createContinuation?.resume()
        try await wait { coordinator.state == .idle }
        #expect(trace.events.contains("ack"))
        #expect(!trace.events.contains("audio"))
        #expect(!trace.events.contains("attach"))
    }

    @Test func transferClosesAndAcknowledgesPreviousSessionBeforeCreatingNext() async throws {
        let trace = Trace(), signaling: SignalingFixture
        signaling = SignalingFixture(trace)
        let coordinator = DotSessionCoordinator(signaling: signaling)
        let dot = try DotIdentity(primary: IdentityTests().fixture())
        coordinator.start(surface: .phone, dot: dot) { MediaFixture(trace) }
        try await wait { coordinator.state == .active(.phone, muted: false) }
        coordinator.start(surface: .carPlay, dot: dot) { MediaFixture(trace) }
        try await wait { coordinator.state == .active(.carPlay, muted: false) }
        let close = try #require(trace.events.firstIndex(of: "close"))
        let ack = try #require(trace.events.firstIndex(of: "ack"))
        let next = try #require(trace.events.firstIndex(of: "create2"))
        #expect(close < ack && ack < next)
        coordinator.end()
        try await wait { coordinator.state == .idle }
    }

    @Test func failedStopBlocksTransferAndCanBeRetried() async throws {
        let trace = Trace(), signaling: SignalingFixture
        signaling = SignalingFixture(trace)
        let coordinator = DotSessionCoordinator(signaling: signaling)
        let dot = try DotIdentity(primary: IdentityTests().fixture())
        coordinator.start(surface: .phone, dot: dot) { MediaFixture(trace) }
        try await wait { coordinator.state == .active(.phone, muted: false) }
        signaling.failStop = true
        coordinator.start(surface: .carPlay, dot: dot) { MediaFixture(trace) }
        try await wait { coordinator.state == .blocked(.phone) }
        coordinator.start(surface: .carPlay, dot: dot) { MediaFixture(trace) }
        #expect(signaling.sequence == 1)
        #expect(trace.events.contains("close"))
        signaling.failStop = false
        coordinator.end()
        try await wait { coordinator.state == .idle }
        #expect(signaling.sequence == 1)
    }

    @Test func repeatedStartAndMuteDoNotAllocateMoreCalls() async throws {
        let trace = Trace(), signaling: SignalingFixture
        signaling = SignalingFixture(trace)
        let coordinator = DotSessionCoordinator(signaling: signaling)
        let dot = try DotIdentity(primary: IdentityTests().fixture())
        for _ in 0..<20 { coordinator.start(surface: .phone, dot: dot) { MediaFixture(trace) } }
        try await wait { coordinator.state == .active(.phone, muted: false) }
        coordinator.setMuted(true)
        #expect(coordinator.state == .active(.phone, muted: true))
        coordinator.setMuted(false)
        #expect(signaling.sequence == 1)
        #expect(trace.events.suffix(2) == ["mute", "unmute"])
        coordinator.end()
        try await wait { coordinator.state == .idle }
    }

    @Test func watchMustAcknowledgeClosureBeforeAnotherSurfaceCanAllocate() async throws {
        let trace = Trace(), signaling = SignalingFixture(Trace())
        let media = MediaFixture(trace)
        let coordinator = DotSessionCoordinator(signaling: signaling)
        let dot = try DotIdentity(primary: IdentityTests().fixture())
        coordinator.start(surface: .watch, dot: dot) { media }
        try await wait { coordinator.state == .active(.watch, muted: false) }
        media.failClosure = true
        coordinator.start(surface: .phone, dot: dot) { MediaFixture(trace) }
        try await wait { coordinator.state == .blocked(.watch) }
        #expect(media.closed)
        #expect(signaling.sequence == 1)
        #expect(signaling.trace.events.contains("ack")) // Server stop alone is insufficient.
        coordinator.start(surface: .phone, dot: dot) { MediaFixture(trace) }
        #expect(signaling.sequence == 1)
        media.failClosure = false
        coordinator.end()
        try await wait { coordinator.state == .idle }
        coordinator.start(surface: .phone, dot: dot) { MediaFixture(trace) }
        try await wait { coordinator.state == .active(.phone, muted: false) }
        #expect(signaling.sequence == 2)
        coordinator.end()
        try await wait { coordinator.state == .idle }
    }

    @Test func endDuringRemoteActivationCannotRestoreMicrophone() async throws {
        let trace = Trace(), signaling = SignalingFixture(Trace())
        let media = MediaFixture(trace)
        media.pauseActivation = true
        let coordinator = DotSessionCoordinator(signaling: signaling)
        let dot = try DotIdentity(primary: IdentityTests().fixture())
        coordinator.start(surface: .watch, dot: dot) { media }
        try await wait { media.activationContinuation != nil }
        coordinator.end()
        #expect(media.closed)
        media.activationContinuation?.resume()
        try await wait { coordinator.state == .idle }
        #expect(!trace.events.contains("audio"))
        #expect(signaling.trace.events.contains("ack"))
    }

    @Test func cancelledQueuedWatchStartCannotAllocateAfterPhoneStops() async throws {
        let trace = Trace(), signaling = SignalingFixture(Trace())
        let coordinator = DotSessionCoordinator(signaling: signaling)
        let dot = try DotIdentity(primary: IdentityTests().fixture())
        coordinator.start(surface: .phone, dot: dot) { MediaFixture(trace) }
        try await wait { coordinator.state == .active(.phone, muted: false) }
        signaling.pauseStop = true
        coordinator.start(surface: .watch, dot: dot) { MediaFixture(trace) }
        try await wait { signaling.stopContinuation != nil }
        coordinator.cancelPendingStart(for: .watch)
        signaling.stopContinuation?.resume()
        try await wait { coordinator.state == .idle }
        #expect(signaling.sequence == 1)
    }

    @Test func watchCancellationLeavesNewerCarPlayTransferQueued() async throws {
        let trace = Trace(), signaling = SignalingFixture(Trace())
        let coordinator = DotSessionCoordinator(signaling: signaling)
        let dot = try DotIdentity(primary: IdentityTests().fixture())
        coordinator.start(surface: .phone, dot: dot) { MediaFixture(trace) }
        try await wait { coordinator.state == .active(.phone, muted: false) }
        signaling.pauseStop = true
        coordinator.start(surface: .watch, dot: dot) { MediaFixture(trace) }
        try await wait { signaling.stopContinuation != nil }
        coordinator.start(surface: .carPlay, dot: dot) { MediaFixture(trace) }
        coordinator.cancelPendingStart(for: .watch)
        signaling.pauseStop = false
        signaling.stopContinuation?.resume()
        try await wait { coordinator.state == .active(.carPlay, muted: false) }
        #expect(signaling.sequence == 2)
        coordinator.end()
        try await wait { coordinator.state == .idle }
    }
}
