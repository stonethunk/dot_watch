import Foundation

/// A bounded diagnostic RPC connection. This is not yet a production audio transport.
public actor DotSocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var receiveTask: Task<Void, Never>?
    private var eventSink: (@Sendable (JSONValue) -> Void)?
    private var closed = false

    public init(credentials: ChatGPTCredentials) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 25
        session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        var request = URLRequest(url: EndpointPolicy.socket)
        request.setValue(credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex", forHTTPHeaderField: "X-OpenAI-Product-Sku")
        request.setValue("codex-app-server, codex-client.desktop, openai-bearer." + credentials.accessToken,
                         forHTTPHeaderField: "Sec-WebSocket-Protocol")
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 8 * 1024 * 1024
    }

    public func connect(onEvent: @escaping @Sendable (JSONValue) -> Void) async throws {
        guard receiveTask == nil, !closed else { throw DotError.disconnected }
        eventSink = onEvent
        task.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
        _ = try await call("initialize", params: .object([
            "clientInfo": .object(["name": .string("dot_watch_probe"), "version": .string("0.1.0")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ]))
        try await send(.object(["method": .string("initialized")]))
    }

    public func call(_ method: String, params: JSONValue, timeoutSeconds: UInt64 = 25) async throws -> JSONValue {
        guard !closed else { throw DotError.disconnected }
        let id = nextID
        nextID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task {
                    do { try await self.send(.object(["id": .number(Double(id)), "method": .string(method), "params": params])) }
                    catch { self.fail(id, error: error) }
                }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    await self?.fail(id, error: DotError.timeout)
                }
            }
        } onCancel: {
            Task { await self.fail(id, error: CancellationError()) }
        }
    }

    public func close() {
        guard !closed else { return }
        closed = true
        receiveTask?.cancel()
        receiveTask = nil
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: DotError.disconnected) }
        eventSink = nil
    }

    private func send(_ value: JSONValue) async throws {
        try await task.send(.string(String(decoding: value.encoded(), as: UTF8.self)))
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .data(let bytes): data = bytes
                case .string(let string): data = Data(string.utf8)
                @unknown default: throw DotError.invalidResponse
                }
                let value = try JSONValue.decode(data)
                if value["method"].string != nil {
                    // Never approve an action or impersonate an interactive response.
                    eventSink?(value)
                } else if let id = value["id"].int, let continuation = pending.removeValue(forKey: id) {
                    if let code = value["error"]["code"].int {
                        let error = value["error"]
                        let message = [error["message"].string, error["data"]["message"].string, error["data"]["reason"].string, error["data"].string].compactMap { $0 }.joined(separator: " ").lowercased()
                        let requiresClientCall = message == "cloud realtime requires a client-created call"
                        let words = ["websocket", "webrtc", "transport", "version", "unsupported", "required", "invalid", "disabled", "experimental", "active", "already", "thread", "voice", "audio", "session", "not found", "missing", "field", "prompt", "type", "variant", "method", "params", "unknown", "auth", "permission", "denied", "subscription", "outputmodality", "model", "init", "request", "json", "response", "available", "enabled", "supported", "not", "allow", "feature"]
                        eventSink?(.object(["method": .string("diagnostic/rpcError"), "params": .object([
                            "code": .number(Double(code)), "keywords": .array(words.filter { message.contains($0) }.map(JSONValue.string)),
                            "messageLength": .number(Double(message.count)),
                            "hasMessageString": .bool(error["message"].string != nil),
                            "hasData": .bool(error.object?["data"] != nil),
                            "requiresClientCreatedCall": .bool(requiresClientCall),
                        ])]))
                        continuation.resume(throwing: DotError.rpc(code))
                    }
                    else if value.object?["result"] != nil { continuation.resume(returning: value["result"]) }
                    else { continuation.resume(throwing: DotError.invalidResponse) }
                }
            }
        } catch {
            // Raw network errors may contain the URL or authentication handshake.
            close()
        }
    }

    private func fail(_ id: Int, error: Error) { pending.removeValue(forKey: id)?.resume(throwing: error) }
}
