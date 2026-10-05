import Foundation
import Network
import Synchronization
import WatchWebRTC
import Logging

public enum LinkError: String, Error { case invalidAnswer, unsupportedCandidate, network, timeout, transport, closed }

public struct WatchOpusPacket: Sendable {
    public let sequence: UInt16
    public let timestamp: UInt32
    public let payload: Data
}

/// Authenticated UDP WebRTC adapter. Audio capture and session ownership stay
/// with the app; this adapter never stores credentials or microphone samples.
public final class DirectWatchLink: Sendable {
    private let clockStart = ContinuousClock.now
    private var now: Duration { clockStart.duration(to: .now) }
    private let certificate: WebRTCCertificate
    private let credentials = ICECredentials()
    private let logger = Logger(label: "dot-watch-probe", factory: { _ in SwiftLogNoOpLogHandler() })
    private struct State: Sendable {
        var wire: DatagramWire?
        var connection: WebRTCConnection?
        var channelOpen = false
        var eventCount = 0
        var rtpPackets = 0
        var markerSeen = false
        var sentPackets = 0
        var eventTask: Task<Void, Never>?
        var consentTask: Task<Void, Never>?
        var consent: ICEConsent?
        var failureCode = "none"
        var connectedAt: Duration?
        var closed = false
        var audioHandler: (@Sendable (WatchOpusPacket) -> Void)?
        var eventHandler: (@Sendable (Data) -> Void)?
        var sequence = UInt16.random(in: 0...UInt16.max)
        var timestamp = UInt32.random(in: 0...UInt32.max)
        var firstPacket = true
        var remoteSSRC: UInt32?
    }
    private let state = Mutex(State())

    public init() throws { certificate = try WebRTCCertificate.generateSelfSigned() }

    public var offer: String {
        let transport = [
            "a=ice-ufrag:\(credentials.localUfrag)", "a=ice-pwd:\(credentials.localPassword)",
            "a=fingerprint:\(certificate.fingerprint.sdpFormat)", "a=setup:actpass",
        ]
        let lines = ["v=0", "o=- 7321664 1 IN IP4 127.0.0.1", "s=-", "t=0 0",
                     "a=group:BUNDLE 0 1", "a=msid-semantic: WMS dot"] +
            ["m=audio 9 UDP/TLS/RTP/SAVPF 111", "c=IN IP4 0.0.0.0"] + transport +
            ["a=mid:0", "a=sendrecv", "a=rtcp-mux", "a=rtcp-rsize", "a=rtpmap:111 opus/48000/2",
             "a=fmtp:111 minptime=10;useinbandfec=1", "a=msid:dot microphone", "a=ssrc:7321664 cname:dot"] +
            ["m=application 9 UDP/DTLS/SCTP webrtc-datachannel", "c=IN IP4 0.0.0.0"] + transport +
            ["a=mid:1", "a=sctp-port:5000", "a=max-message-size:65536"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    public func accept(_ answer: String) throws {
        let parsed = try Answer(answer)
        let wire = DatagramWire(host: parsed.host, port: parsed.port)
        let ice = ICECredentials(localUfrag: credentials.localUfrag, localPassword: credentials.localPassword,
                                 remoteUfrag: parsed.ufrag, remotePassword: parsed.password)
        let config = try WebRTCMediaConfiguration(rtpPayloadTypes: [111], allowsReducedSizeRTCP: true)
        let connection: WebRTCConnection
        if parsed.remoteActive {
            connection = try WebRTCConnection.asServer(certificate: certificate,
                remoteFingerprint: parsed.fingerprint, iceConfiguration: .controlling(credentials: ice),
                mediaConfiguration: config, sendHandler: { wire.send(consume $0) }, logger: logger)
        } else {
            connection = try WebRTCConnection.asClient(certificate: certificate,
                remoteFingerprint: parsed.fingerprint, iceConfiguration: .controlling(credentials: ice),
                mediaConfiguration: config, sendHandler: { wire.send(consume $0) }, logger: logger)
        }
        connection.setRemoteICECredentials(ufrag: parsed.ufrag, password: parsed.password)
        connection.setRTPHandler { [weak self] packet in
            guard packet.bytes.count >= 12, !packet.payload.isEmpty, packet.payload.count <= 1275 else { return }
            let ssrc = packet.bytes[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let handler = self?.state.withLock { value -> (@Sendable (WatchOpusPacket) -> Void)? in
                guard !value.closed else { return nil }
                guard value.remoteSSRC == nil || value.remoteSSRC == ssrc else { return nil }
                value.remoteSSRC = ssrc
                value.rtpPackets += 1
                return value.audioHandler
            }
            let sequence = UInt16(packet.bytes[2]) << 8 | UInt16(packet.bytes[3])
            let timestamp = packet.bytes[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            handler?(WatchOpusPacket(sequence: sequence, timestamp: timestamp, payload: Data(packet.payload)))
        }
        wire.setReceiver { [weak self, weak connection] data in
            guard let self else { return }
            let received = self.state.withLock { value -> ICEConsent.Incoming in
                guard !value.closed else { return .discard }
                return value.consent?.receive(Array(data), at: self.now) ?? .forward
            }
            switch received {
            case .discard: return
            case .reply(let bytes):
                if case .failure = wire.send(bytes) { self.recordFailure("consent_send_failed") }
            case .forward:
                do { try connection?.receive(data, remoteAddress: parsed.remoteEndpoint) }
                catch { self.recordFailure(Self.safeCode(error)); wire.close() }
            }
        }
        let accepted = state.withLock { value in
            guard !value.closed, value.connection == nil else { return false }
            value.connection = connection
            value.wire = wire
            value.consent = ICEConsent(localUfrag: credentials.localUfrag, localPassword: credentials.localPassword,
                remoteUfrag: parsed.ufrag, remotePassword: parsed.password,
                remoteAddress: Array(parsed.remoteEndpoint.prefix(4)), remotePort: parsed.port.rawValue)
            return true
        }
        guard accepted else { connection.close(); wire.close(); throw LinkError.closed }
        wire.start()
    }

    public func connect() async throws {
        guard let (wire, connection) = state.withLock({ value -> (DatagramWire, WebRTCConnection)? in
            guard let wire = value.wire, let connection = value.connection else { return nil }
            return (wire, connection)
        }) else { throw LinkError.closed }
        try await wait { wire.ready }
        try await connection.establishICEConnectivity(timeout: .seconds(10))
        state.withLock { $0.consent?.start(at: now) }
        startConsentChecks(wire: wire)
        if connection.state == .new || connection.state == .connecting { try connection.start() }
        try await wait { connection.state == .connected }
        guard connection.remoteFingerprint != nil, connection.isMediaReady else { throw LinkError.transport }
        let consumer = try connection.claimDataChannelEvents()
        let task = Task { [weak self] in
            do {
                while let event = try await consumer.next() {
                    switch event {
                    case .opened(let channel, _):
                        if channel.label == "oai-events" { self?.state.withLock { $0.channelOpen = true } }
                    case .message(_, _, let payload):
                        let containsMarker = String(bytes: payload, encoding: .utf8)?.lowercased().contains("marigold") == true
                        let handler = self?.state.withLock { value -> (@Sendable (Data) -> Void)? in
                            guard !value.closed else { return nil }
                            value.eventCount += 1; value.markerSeen = value.markerSeen || containsMarker
                            return value.eventHandler
                        }
                        if payload.count <= 64 * 1024 { handler?(Data(payload)) }
                    case .closed: self?.state.withLock {
                        $0.channelOpen = false
                        if !$0.closed, $0.failureCode == "none" { $0.failureCode = "data_channel_closed" }
                    }
                    }
                }
                self?.state.withLock {
                    $0.channelOpen = false
                    if !$0.closed, $0.failureCode == "none" { $0.failureCode = "event_stream_ended" }
                }
            } catch {
                self?.recordFailure(Self.safeCode(error))
                self?.state.withLock { $0.channelOpen = false }
            }
        }
        state.withLock { $0.eventTask = task }
        _ = try connection.openDataChannel(label: "oai-events")
        try await wait { self.state.withLock { $0.channelOpen } }
        state.withLock { $0.connectedAt = now }
    }

    public func setHandlers(audio: @escaping @Sendable (WatchOpusPacket) -> Void,
                            event: @escaping @Sendable (Data) -> Void) {
        state.withLock { if !$0.closed { $0.audioHandler = audio; $0.eventHandler = event } }
    }

    /// One live 20 ms packet. Caller serializes encoding/pacing and drops stale
    /// microphone input; this adapter never queues or persists an audio sample.
    public func sendOpus(_ payload: Data) throws {
        guard !payload.isEmpty, payload.count <= 1275 else { throw LinkError.transport }
        let context = state.withLock { value -> (WebRTCConnection, UInt16, UInt32, Bool)? in
            value.consent?.expire(at: now)
            guard !value.closed, value.channelOpen, value.consent?.usable == true,
                  let connection = value.connection else { return nil }
            let result = (connection, value.sequence, value.timestamp, value.firstPacket)
            value.sequence &+= 1; value.timestamp &+= 960; value.firstPacket = false
            return result
        }
        guard let (connection, sequence, timestamp, first) = context else { throw LinkError.closed }
        func bytes(_ value: UInt32) -> [UInt8] {
            [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
             UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        }
        var packet: [UInt8] = [0x80, first ? 0xef : 0x6f, UInt8(truncatingIfNeeded: sequence >> 8), UInt8(truncatingIfNeeded: sequence)]
        packet += bytes(timestamp) + bytes(7321664) + Array(payload)
        try connection.sendRTP(packet)
        state.withLock { if !$0.closed { $0.sentPackets += 1 } }
    }

    /// Bounded synthetic Opus packets only. No microphone is opened by this probe.
    public func sendSyntheticOpus(_ packets: [Data]) async throws {
        guard packets.count <= 1500, packets.allSatisfy({ !$0.isEmpty && $0.count <= 1200 }),
              let connection = state.withLock({ $0.connection }),
              state.withLock({ $0.channelOpen && !$0.closed }) else { throw LinkError.transport }
        var sequence = UInt16.random(in: 0...UInt16.max)
        var timestamp = UInt32.random(in: 0...UInt32.max)
        func bytes(_ value: UInt32) -> [UInt8] { [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }
        for (index, payload) in packets.enumerated() {
            guard healthy else { throw LinkError.closed }
            var packet: [UInt8] = [0x80, index == 0 ? 0xef : 0x6f, UInt8(truncatingIfNeeded: sequence >> 8), UInt8(truncatingIfNeeded: sequence)]
            packet += bytes(timestamp) + bytes(7321664) + Array(payload)
            try connection.sendRTP(packet)
            state.withLock { $0.sentPackets += 1 }
            sequence &+= 1; timestamp &+= 960
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    public var evidence: [String: Int] { state.withLock {
        ["authenticated_rtp_packets": $0.rtpPackets, "sent_rtp_packets": $0.sentPackets,
         "data_events": $0.eventCount, "data_channel_open": $0.channelOpen ? 1 : 0,
         "synthetic_marker_in_events": $0.markerSeen ? 1 : 0]
    } }
    public var phase: String { state.withLock { $0.connection?.state.label ?? "uninitialized" } }
    public var healthy: Bool { state.withLock {
        $0.consent?.expire(at: now)
        if $0.consent?.expired == true, $0.failureCode == "none" { $0.failureCode = "consent_expired" }
        return !$0.closed && $0.channelOpen && $0.failureCode == "none" && $0.consent?.usable == true &&
        $0.connection?.state == .connected && $0.wire?.failed != true
    } }

    /// Fixed labels and numbers only. Never return SDP, endpoint addresses,
    /// certificate bytes, ICE passwords, transaction IDs or event payloads.
    public var diagnostics: [String: Any] {
        let current = now
        let snapshot = state.withLock { value in
            (value.connection, value.wire, value.failureCode, value.channelOpen, value.consent, value.connectedAt)
        }
        let wire = snapshot.1?.diagnostics ?? [:]
        let age = snapshot.5.map { current - $0 } ?? .zero
        return ["failure_code": snapshot.2,
                "protocol_failure": snapshot.0?.terminalFailure.map(Self.safeCode) ?? "none",
                "connection_state": snapshot.0?.state.label ?? "uninitialized",
                "data_channel_open": snapshot.3,
                "connected_milliseconds": max(0, age.components.seconds * 1000 + age.components.attoseconds / 1_000_000_000_000_000),
                "consent_requests": snapshot.4?.requests ?? 0,
                "consent_responses": snapshot.4?.responses ?? 0,
                "consent_peer_replies": snapshot.4?.peerReplies ?? 0,
                "consent_invalid_responses": snapshot.4?.invalidResponses ?? 0,
                "consent_expired": snapshot.4?.expired ?? false,
                "consent_revoked": snapshot.4?.revoked ?? false,
                "consent_age_milliseconds": snapshot.4?.ageMilliseconds(at: current) ?? 0,
                "wire": wire]
    }

    private func startConsentChecks(wire: DatagramWire) {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let action = self.state.withLock { value -> ([UInt8]?, Bool) in
                    guard !value.closed else { return (nil, true) }
                    let bytes = value.consent?.poll(at: self.now, interval: .milliseconds(Int.random(in: 4000...6000)))
                    if value.consent?.expired == true || value.consent?.revoked == true {
                        if value.failureCode == "none" {
                            value.failureCode = value.consent?.revoked == true ? "consent_revoked" : "consent_expired"
                        }
                        return (nil, true)
                    }
                    return (bytes, false)
                }
                if action.1 {
                    let connection = self.state.withLock { $0.connection }
                    connection?.close(); wire.close(); return
                }
                if let bytes = action.0, case .failure = wire.send(bytes) {
                    self.recordFailure("consent_send_failed"); return
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        let accepted = state.withLock { value in
            guard !value.closed else { return false }
            value.consentTask = task; return true
        }
        if !accepted { task.cancel() }
    }

    private func recordFailure(_ code: String) {
        state.withLock { if !$0.closed, $0.failureCode == "none" { $0.failureCode = code } }
    }

    private static func safeCode(_ error: Error) -> String {
        guard let error = error as? WebRTCError else { return "protocol_error" }
        switch error {
        case .iceFailed: return "ice_failed"
        case .dtlsHandshakeFailed: return "dtls_failed"
        case .sctpWireFailed: return "sctp_wire_failed"
        case .sctpProtocolFailed: return "sctp_protocol_failed"
        case .dataChannelFailed: return "data_channel_failed"
        case .dataChannelEventBufferExceeded: return "event_count_limit"
        case .dataChannelEventByteBufferExceeded: return "event_byte_limit"
        case .dataChannelEventStreamTerminated: return "event_stream_terminated"
        case .datagramSendFailed: return "datagram_send_failed"
        case .mediaProtectionFailed: return "media_protection_failed"
        case .closed: return "protocol_closed"
        default: return "protocol_error"
        }
    }

    public func close() {
        let cleanup = state.withLock { value in
            value.closed = true
            value.channelOpen = false
            let owned = (value.connection, value.wire, value.eventTask, value.consentTask)
            value.connection = nil; value.wire = nil; value.eventTask = nil
            value.consentTask = nil; value.consent = nil
            value.audioHandler = nil; value.eventHandler = nil
            return owned
        }
        cleanup.2?.cancel(); cleanup.3?.cancel(); cleanup.0?.close(); cleanup.1?.close()
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate() {
            if state.withLock({ $0.closed || $0.failureCode != "none" || $0.connection?.state.isTerminal == true || $0.wire?.failed == true }) { throw LinkError.transport }
            if ContinuousClock.now >= deadline { throw LinkError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct Answer {
    let host: NWEndpoint.Host
    let port: NWEndpoint.Port
    let fingerprint: CertificateFingerprint
    let ufrag: String
    let password: String
    let remoteActive: Bool
    let remoteEndpoint: Data

    init(_ sdp: String) throws {
        guard sdp.utf8.count < 128 * 1024 else { throw LinkError.invalidAnswer }
        let lines = sdp.components(separatedBy: .newlines)
        func attribute(_ prefix: String) throws -> String {
            let matches = Set(lines.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
            guard matches.count == 1, let value = matches.first, !value.isEmpty else { throw LinkError.invalidAnswer }
            return value
        }
        ufrag = try attribute("a=ice-ufrag:")
        password = try attribute("a=ice-pwd:")
        let role = try attribute("a=setup:")
        guard role == "active" || role == "passive" else { throw LinkError.invalidAnswer }
        remoteActive = role == "active"
        let digest = try attribute("a=fingerprint:sha-256 ").split(separator: ":")
        let bytes = digest.compactMap { UInt8($0, radix: 16) }
        guard digest.count == 32, bytes.count == 32 else { throw LinkError.invalidAnswer }
        fingerprint = CertificateFingerprint.fromDigest(bytes)
        guard lines.contains(where: { $0.lowercased() == "a=rtpmap:111 opus/48000/2" }),
              lines.contains("a=rtcp-mux") else { throw LinkError.invalidAnswer }
        // This initial probe supports public IPv4 UDP candidates only. No DNS,
        // private-network routing or silent fallback to prevalidated ICE.
        var endpoint: (NWEndpoint.Host, NWEndpoint.Port)?
        for line in lines where line.hasPrefix("a=candidate:") {
            let fields = line.split(separator: " ")
            guard fields.count >= 8, fields[1] == "1", fields[2].lowercased() == "udp",
                  let address = IPv4Address(String(fields[4])),
                  let rawPort = UInt16(fields[5]), rawPort > 0,
                  let port = NWEndpoint.Port(rawValue: rawPort) else { continue }
            let octets = Array(address.rawValue)
            guard octets[0] > 0, octets[0] < 224, octets[0] != 10, octets[0] != 127,
                  !(octets[0] == 169 && octets[1] == 254),
                  !(octets[0] == 172 && (16...31).contains(octets[1])),
                  !(octets[0] == 192 && octets[1] == 168),
                  !(octets[0] == 100 && (64...127).contains(octets[1])) else { continue }
            endpoint = (.ipv4(address), port); break
        }
        guard let endpoint else { throw LinkError.unsupportedCandidate }
        host = endpoint.0; port = endpoint.1
        guard case .ipv4(let address) = host else { throw LinkError.unsupportedCandidate }
        remoteEndpoint = address.rawValue + Data([UInt8(port.rawValue >> 8), UInt8(truncatingIfNeeded: port.rawValue)])
    }
}

private final class DatagramWire: Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.dotwatch.app.transport-probe")
    private struct State: Sendable {
        var ready = false
        var failed = false
        var closed = false
        var pending = 0
        var phase = "setup"
        var errorFamily = "none"
        var errorCode = 0
        var errorOperation = "none"
        var receiver: (@Sendable (Data) -> Void)?
    }
    private let state = Mutex(State())
    init(host: NWEndpoint.Host, port: NWEndpoint.Port) { connection = NWConnection(host: host, port: port, using: .udp) }
    var ready: Bool { state.withLock { $0.ready } }
    var failed: Bool { state.withLock { $0.failed } }
    var diagnostics: [String: Any] { state.withLock {
        ["state": $0.phase, "error_family": $0.errorFamily, "error_code": $0.errorCode,
         "error_operation": $0.errorOperation, "pending_datagrams": $0.pending]
    } }
    func setReceiver(_ receiver: @escaping @Sendable (Data) -> Void) { state.withLock { $0.receiver = receiver } }
    func start() {
        connection.stateUpdateHandler = { [weak self] value in
            switch value {
            case .ready: self?.state.withLock { $0.ready = true; $0.phase = "ready" }
            case .failed(let error): self?.recordError(error, operation: "state")
            case .waiting(let error): self?.recordError(error, operation: "waiting", terminal: false)
            case .cancelled: self?.state.withLock { $0.failed = true; $0.phase = "cancelled" }
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }
    func send(_ bytes: consuming [UInt8]) -> Result<Void, WebRTCDatagramSendFailure> {
        guard bytes.count <= 2048 else { return .failure(.datagramTooLarge(actualByteCount: bytes.count, maximumByteCount: 2048)) }
        let admission = state.withLock { value -> Result<Void, WebRTCDatagramSendFailure> in
            guard !value.closed, !value.failed else { return .failure(.closed) }
            guard value.pending < 64 else { return .failure(.backpressured) }
            value.pending += 1
            return .success(())
        }
        guard case .success = admission else { return admission }
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            self?.state.withLock { $0.pending -= 1 }
            if let error { self?.recordError(error, operation: "send") }
        })
        return .success(())
    }
    private func receive() {
        guard !state.withLock({ $0.closed }) else { return }
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { self.recordError(error, operation: "receive"); return }
            if let data, data.count <= 2048 {
                let receiver = self.state.withLock { $0.closed ? nil : $0.receiver }
                receiver?(data)
            }
            self.receive()
        }
    }
    func close() {
        state.withLock { $0.closed = true; $0.receiver = nil }
        connection.cancel()
    }
    private func recordError(_ error: NWError, operation: String, terminal: Bool = true) {
        state.withLock {
            guard !$0.closed else { return }
            $0.failed = $0.failed || terminal
            $0.phase = terminal ? "failed" : "waiting"
            guard $0.errorOperation == "none" else { return }
            $0.errorOperation = operation
            switch error {
            case .posix(let code): $0.errorFamily = "posix"; $0.errorCode = Int(code.rawValue)
            case .dns(let code): $0.errorFamily = "dns"; $0.errorCode = Int(code)
            case .tls(let code): $0.errorFamily = "tls"; $0.errorCode = Int(code)
            default: $0.errorFamily = "other"
            }
        }
    }
}
