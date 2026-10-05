import XCTest
import UIKit
import CarPlay
@testable import DotCore

@MainActor private final class SimulatorSignaling: DotVoiceSignaling {
    var allocations = 0
    var stops = 0
    var failStop = false
    var allocationNeedsReconciliation = false
    func create(dot: DotIdentity, offerSDP: String) async throws -> DotVoiceConnection {
        allocations += 1
        return try DotVoiceConnection(dotID: dot.dotID, location: "/rtc_fixture_\(allocations)", answer: Data("v=0\r\n".utf8))
    }
    func attach(_ call: DotVoiceConnection) async throws {}
    func stop(_ call: DotVoiceConnection) async throws {
        stops += 1
        if failStop { throw DotError.disconnected }
    }
}

@MainActor private final class SimulatorMedia: DotVoiceMedia {
    var capturing = false
    var closed = false
    func prepareOffer() async throws -> String { "v=0\r\n" }
    func acceptAnswer(_ sdp: String) async throws {}
    func waitUntilReady() async throws {}
    func enableAudio(muted: Bool) throws { guard !closed else { throw DotError.disconnected }; capturing = !muted }
    func setMuted(_ muted: Bool) { capturing = !closed && !muted }
    func close() { capturing = false; closed = true }
}

@MainActor private final class SimulatorOwner: CarPlaySessionOwner {
    var configured = true
    var microphoneGranted = true
    var character: UIImage? = UIImage(systemName: "circle.fill") // Synthetic fixture, never substitutes for the user's avatar.
    let signaling = SimulatorSignaling()
    lazy var coordinator = DotSessionCoordinator(signaling: signaling)
    var media: [SimulatorMedia] = []
    var startCalls = 0
    var delayStart = false
    var startContinuation: CheckedContinuation<Void, Never>?
    var state: DotSessionState { coordinator.state }
    var status: String {
        switch state {
        case .idle: "Ready"
        case .starting: "Connecting"
        case .active(_, let muted): muted ? "Microphone muted" : "Listening"
        case .stopping: "Ending"
        case .blocked: "Retry End"
        }
    }
    func start(_ surface: DotSurface) async {
        startCalls += 1
        if delayStart { await withCheckedContinuation { startContinuation = $0 } }
        let file = Bundle(for: CarPlayRuntimeTests.self).url(forResource: "primary", withExtension: "json")!
        let primary = try! JSONValue.decode(Data(contentsOf: file))
        // The fixture uses the same identity decoder and session coordinator.
        guard let dot = try? DotIdentity(primary: primary) else { XCTFail("Identity fixture invalid"); return }
        coordinator.start(surface: surface, dot: dot) { [self] in
            let value = SimulatorMedia(); media.append(value); return value
        }
    }
    func toggleMute() { if case .active(_, let muted) = state { coordinator.setMuted(!muted) } }
    func end() { coordinator.end() }
}

@MainActor final class CarPlayRuntimeTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("State transition timed out")
        throw DotError.timeout
    }
    private func controls(_ experience: CarPlayExperience) -> [CPButton] { experience.template().voiceControlStates[0].actionButtons }

    func testUnconfiguredAndPermissionDeniedCannotStart() async {
        let owner = SimulatorOwner(), experience: CarPlayExperience
        experience = CarPlayExperience(owner: owner)
        experience.connect()
        owner.configured = false
        XCTAssertTrue(controls(experience).isEmpty)
        XCTAssertEqual(experience.template().voiceControlStates[0].titleVariants, ["Finish setup in Dot on iPhone"])
        await experience.perform(.talk)
        owner.configured = true; owner.microphoneGranted = false
        XCTAssertTrue(controls(experience).isEmpty)
        await experience.perform(.talk)
        XCTAssertEqual(owner.startCalls, 0)
        XCTAssertEqual(owner.signaling.allocations, 0)
    }

    func testConnectTalkMuteEndAndReconnect() async throws {
        let owner = SimulatorOwner(), experience: CarPlayExperience
        experience = CarPlayExperience(owner: owner)
        experience.connect()
        XCTAssertEqual(owner.signaling.allocations, 0)
        XCTAssertEqual(controls(experience).compactMap(\.title), ["Talk"])
        await experience.perform(.talk)
        try await wait { owner.state == .active(.carPlay, muted: false) }
        XCTAssertTrue(owner.media[0].capturing)
        XCTAssertEqual(controls(experience).compactMap(\.title), ["Mute", "End"])
        XCTAssertLessThanOrEqual(controls(experience).count, CPVoiceControlState.maximumActionButtonCount)
        await experience.perform(.mute)
        XCTAssertEqual(owner.state, .active(.carPlay, muted: true))
        XCTAssertFalse(owner.media[0].capturing)
        XCTAssertEqual(controls(experience).compactMap(\.title), ["Unmute", "End"])
        await experience.perform(.mute)
        XCTAssertTrue(owner.media[0].capturing)
        await experience.perform(.end)
        XCTAssertFalse(owner.media[0].capturing)
        try await wait { owner.state == .idle }
        XCTAssertEqual(owner.signaling.stops, 1)
        experience.disconnect(); experience.connect()
        XCTAssertEqual(owner.signaling.allocations, 1)
        XCTAssertEqual(controls(experience).compactMap(\.title), ["Talk"])
    }

    func testDisconnectStopsAndRejectsStaleTalk() async throws {
        let owner = SimulatorOwner(), experience: CarPlayExperience
        experience = CarPlayExperience(owner: owner)
        experience.connect(); await experience.perform(.talk)
        try await wait { owner.state == .active(.carPlay, muted: false) }
        experience.disconnect()
        XCTAssertFalse(owner.media[0].capturing)
        await experience.perform(.talk)
        try await wait { owner.state == .idle }
        XCTAssertEqual(owner.signaling.allocations, 1)
    }

    func testDisconnectDuringDelayedStartupCannotLeaveAudioActive() async throws {
        let owner = SimulatorOwner(), experience: CarPlayExperience
        experience = CarPlayExperience(owner: owner)
        experience.connect(); owner.delayStart = true
        let start = Task { await experience.perform(.talk) }
        try await wait { owner.startContinuation != nil }
        experience.disconnect()
        owner.startContinuation?.resume()
        await start.value
        try await wait { owner.state == .idle }
        XCTAssertFalse(owner.media.contains { $0.capturing })
    }

    func testWatchTransferAndCarDisconnectDoNotEndWatch() async throws {
        let owner = SimulatorOwner(), experience: CarPlayExperience
        experience = CarPlayExperience(owner: owner)
        await owner.start(.watch)
        try await wait { owner.state == .active(.watch, muted: false) }
        experience.connect(); experience.disconnect()
        XCTAssertEqual(owner.state, .active(.watch, muted: false))
        experience.connect()
        XCTAssertEqual(controls(experience).compactMap(\.title), ["Talk here"])
        await experience.perform(.talk)
        try await wait { owner.state == .active(.carPlay, muted: false) }
        XCTAssertTrue(owner.media[0].closed)
        XCTAssertEqual(owner.media.filter(\.capturing).count, 1)
        experience.disconnect()
        try await wait { owner.state == .idle }
    }

    func testReconnectDuringDelayedTalkCannotReviveOldConversation() async throws {
        let owner = SimulatorOwner(), experience: CarPlayExperience
        experience = CarPlayExperience(owner: owner)
        experience.connect(); owner.delayStart = true
        let start = Task { await experience.perform(.talk) }
        try await wait { owner.startContinuation != nil }
        experience.disconnect(); experience.connect()
        owner.startContinuation?.resume()
        await start.value
        try await wait { owner.state == .idle }
        XCTAssertFalse(owner.media.contains { $0.capturing })
    }

    func testFailedStopBlocksDuplicateTalkAndCanRetryEnd() async throws {
        let owner = SimulatorOwner(), experience: CarPlayExperience
        experience = CarPlayExperience(owner: owner)
        experience.connect(); await experience.perform(.talk)
        try await wait { owner.state == .active(.carPlay, muted: false) }
        owner.signaling.failStop = true
        await experience.perform(.end)
        try await wait { owner.state == .blocked(.carPlay) }
        XCTAssertFalse(controls(experience)[0].isEnabled)
        XCTAssertTrue(controls(experience)[1].isEnabled)
        await experience.perform(.talk)
        XCTAssertEqual(owner.signaling.allocations, 1)
        owner.signaling.failStop = false
        await experience.perform(.end)
        try await wait { owner.state == .idle }
    }

    func testAvatarRefreshChangesRenderingKeyAndKeepsNativeVoiceTemplate() {
        let owner = SimulatorOwner(), experience: CarPlayExperience
        experience = CarPlayExperience(owner: owner)
        let key = experience.renderingKey
        let template = experience.template()
        XCTAssertEqual(template.voiceControlStates.count, 1)
        XCTAssertNotNil(template.voiceControlStates[0].image)
        XCTAssertEqual(template.voiceControlStates[0].image?.size, CGSize(width: 150, height: 150))
        XCTAssertFalse(template.voiceControlStates[0].repeats)
        owner.character = UIImage(systemName: "square.fill")
        XCTAssertNotEqual(experience.renderingKey, key)
        owner.character = nil
        XCTAssertNil(experience.template().voiceControlStates[0].image)
    }
}
