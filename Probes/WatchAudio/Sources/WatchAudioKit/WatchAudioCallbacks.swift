import AVFAudio

/// AVAudioNodeTapBlock is imported as non-Sendable. A literal formed inside a
/// MainActor model would inherit that actor and trap on AVFAudio's audio thread.
/// Construct the callback outside actor isolation and retain Sendable typing
/// until the SDK converts it into its Objective-C block.
public enum WatchAudioCallbacks {
    public nonisolated static func captureTap(into capture: BoundedCaptureBuffer)
        -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { @Sendable buffer, _ in capture.append(buffer) }
    }
}
