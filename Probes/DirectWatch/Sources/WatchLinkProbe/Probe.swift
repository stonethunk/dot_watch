import Foundation
import DotCore
import DirectWatchLink

@main struct Probe {
    static func main() async {
        guard [3, 5].contains(CommandLine.arguments.count), CommandLine.arguments[1] == "--codex-auth-file",
              CommandLine.arguments.count == 3 || CommandLine.arguments[3] == "--synthetic-opus" else {
            print("Usage: watch-link-probe --codex-auth-file PATH [--synthetic-opus PATH]"); return
        }
        var api: DotVoiceAPI?
        var call: DotVoiceConnection?
        var link: DirectWatchLink?
        var report: [String: JSONValue] = ["physical_watch_test": .bool(false), "microphone_opened": .bool(false)]
        var phase = "authentication"
        do {
            let auth = try JSONValue.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            guard let token = auth["tokens"]["access_token"].string, let account = auth["tokens"]["account_id"].string else { throw DotError.invalidCredentials }
            let http = DotHTTPClient(credentials: try ChatGPTCredentials(accessToken: token, accountID: account))
            let signaling = DotVoiceAPI(http: http)
            api = signaling
            phase = "discovery"
            let dot = try await http.discover()
            phase = "offer"
            let transport = try DirectWatchLink()
            link = transport
            phase = "create"
            let created = try await signaling.create(dot: dot, offerSDP: transport.offer)
            call = created
            phase = "answer"
            try transport.accept(created.answerSDP)
            phase = "attach"
            try await signaling.attach(created)
            phase = "connect"
            try await transport.connect()
            report["connected"] = .bool(true)
            if CommandLine.arguments.count == 5 {
                phase = "synthetic_audio"
                let packetData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4]))
                guard packetData.count <= 3 * 1024 * 1024 else { throw DotError.invalidAudio }
                let encoded = try JSONDecoder().decode([String].self, from: packetData)
                let packets = encoded.compactMap { Data(base64Encoded: $0) }
                guard packets.count == encoded.count else { throw DotError.invalidAudio }
                try await transport.sendSyntheticOpus(packets)
            }
            try await Task.sleep(for: .seconds(15))
        } catch {
            report["failed_at"] = .string(phase)
            report["transport_phase"] = .string(link?.phase ?? "uninitialized")
            report["error"] = .string((error as? DotError)?.description ?? (error as? LinkError)?.rawValue ?? "transport_failure")
        }
        if let link {
            for (key, value) in link.evidence { report[key] = .number(Double(value)) }
            link.close()
        }
        if let api, let call {
            do { try await api.stop(call); report["stop_acknowledged"] = .bool(true) }
            catch { report["stop_acknowledged"] = .bool(false) }
        }
        if let data = try? JSONValue.object(report).encoded(), let text = String(data: data, encoding: .utf8) { print(text) }
    }
}
