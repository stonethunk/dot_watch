import Foundation
import DotCore

@main
struct DotProbe {
    static func main() async {
        do { try await run() }
        catch {
            let message = (error as? DotError)?.description ?? "Diagnostic failed; private error details were suppressed."
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let mode = args.first, ["discover", "socket-check"].contains(mode),
              let authIndex = args.firstIndex(of: "--codex-auth-file"), args.indices.contains(authIndex + 1) else {
            print("Usage: dot-probe discover|socket-check --codex-auth-file PATH [--snapshot-output PATH]")
            print("Uses your existing local ChatGPT login for diagnostics. Never paste tokens into arguments.")
            return
        }
        let auth = try JSONValue.decode(Data(contentsOf: URL(fileURLWithPath: args[authIndex + 1])))
        guard let token = auth["tokens"]["access_token"].string,
              let account = auth["tokens"]["account_id"].string else { throw DotError.invalidCredentials }
        let credentials = try ChatGPTCredentials(accessToken: token, accountID: account)
        let client = DotHTTPClient(credentials: credentials)
        let dot = try await client.discover()
        print("primary_dot: verified")
        try await client.verifyThread(dot)
        print("existing_conversation: verified")
        if let index = args.firstIndex(of: "--snapshot-output"), args.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: args[index + 1])
            guard !FileManager.default.fileExists(atPath: url.path) else { throw DotError.fileExists }
            let bytes = try await client.snapshot(dot)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: url.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else { throw DotError.invalidResponse }
            print("authentic_snapshot: hash_verified (\(dot.snapshotWidth)x\(dot.snapshotHeight), \(bytes.count) bytes)")
        }
        if mode == "socket-check" {
            let socket = DotSocket(credentials: credentials)
            do {
                try await socket.connect { _ in }
                print("cloud_websocket_initialize: verified")
                let response = try await socket.call("thread/read", params: .object(["threadId": .string(dot.threadID), "includeTurns": .bool(false)]))
                guard response["thread"]["id"].string == dot.threadID else { throw DotError.identityMismatch }
                print("cloud_websocket_conversation: verified")
                await socket.close()
            } catch {
                await socket.close()
                throw error
            }
        }
    }
}
