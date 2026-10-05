import Foundation
import Darwin
import WatchAudioKit

@main struct Probe {
    static func main() {
        var report: [String: Any] = ["physical_watch_test": false, "microphone_opened": false,
                                   "network_opened": false]
        do {
            let codec = try NativeOpusCodec()
            var packetCount = 0
            var decodedFrames = 0
            var energy = 0.0
            for frame in 0..<50 {
                let samples = (0..<NativeOpusCodec.frameCount).map { index -> Float in
                    let time = Double(frame * NativeOpusCodec.frameCount + index) / NativeOpusCodec.sampleRate
                    return Float(0.2 * sin(2 * .pi * 440 * time))
                }
                for packet in try codec.encode(samples) {
                    packetCount += 1
                    let decoded = try codec.decode(packet)
                    decodedFrames += decoded.count
                    energy += decoded.reduce(0.0) { $0 + Double($1 * $1) }
                }
            }
            report["native_codec_available"] = true
            report["encoded_packets"] = packetCount
            report["decoded_frames"] = decodedFrames
            report["decoded_signal_present"] = energy > 1
        } catch {
            report["native_codec_available"] = false
            report["error"] = (error as? WatchAudioError)?.rawValue ?? "codec_failure"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
              let result = String(data: data, encoding: .utf8) else { exit(1) }
        print(result)
        exit(report["native_codec_available"] as? Bool == true && report["decoded_signal_present"] as? Bool == true ? 0 : 1)
    }
}
