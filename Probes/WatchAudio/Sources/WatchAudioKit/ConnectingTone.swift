import Foundation

/// Original generated ringback: 440 + 480 Hz, two seconds on / four off.
/// Fixed quiet gain and a 10 ms fade avoid clipping and abrupt edges. This is
/// local interface audio, never microphone input or an uploaded recording.
public enum ConnectingTone {
    public static let sampleRate = 48_000
    public static let frameCount = sampleRate * 6
    public static func sample(at frame: Int) -> Float {
        guard frame >= 0 else { return 0 }
        let position = frame % frameCount
        guard position < sampleRate * 2 else { return 0 }
        let time = Double(position) / Double(sampleRate)
        let fade = min(1, min(time, 2 - time) / 0.01)
        return Float(0.08 * fade * (sin(2 * .pi * 440 * time) + sin(2 * .pi * 480 * time)))
    }
}
