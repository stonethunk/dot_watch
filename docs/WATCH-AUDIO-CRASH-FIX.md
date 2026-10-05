# Watch audio crash and simulator preflight

On 2026-10-04, the user reported that **Test Watch audio** closed the app immediately. The Watch crash report recorded `EXC_BREAKPOINT / SIGTRAP` on AVFAudio's `RealtimeMessenger.mServiceQueue`, with libdispatch and Swift concurrency frames. The app binary and dSYM UUID matched the crashing image before rebuilding. Symbolication resolved the app frame to `closure #2 in WatchAudioDiagnostic.run()` and its audio-buffer callback thunk.

The microphone tap closure was created inside the `@MainActor` model. The legacy SDK imports `AVAudioNodeTapBlock` as non-Sendable; that closure inherited UI actor isolation even though AVFAudio invokes it on an audio service queue. This is a callback isolation failure before the codec or Dot connection, not evidence of an account failure. Swift documents [closure isolation and incremental concurrency adoption](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/incrementaladoption/).

`WatchAudioCallbacks.captureTap(into:)` now constructs an explicitly Sendable callback outside actor isolation. It only appends to the mutex-protected, bounded capture buffer. Audio-session activation, playback completion and the WatchConnectivity refresh error handler also have explicit Sendable callbacks; UI updates still hop to MainActor. The earlier WatchConnectivity crash was not symbolicated against a matching archived dSYM, so it is not asserted to have the same resolved function.

The local hardware test now saves safe milestone labels before activation, engine startup, recording and playback, instead of writing only at the end. It still writes no recording, credential or conversation content.

## Verification

Eight synthetic package tests pass. The new regression creates the production callback from MainActor, converts it to the SDK's legacy block type, invokes it on a background queue, and checks capture and rejection of late callbacks after close. Test audio objects are created and cleared on their invocation queue.

The actual Private Watch app also runs a simulator-only preflight through `--simulate-audio-check`. The flag has no effect on a physical Watch. It invokes the production callback on a background queue and runs the app's resampling/Opus round-trip path. The headless watchOS 27 simulator run captured 48,000 frames, encoded 50 packets and decoded 47,880 frames with a signal present. No microphone, speaker, audio session, network or account was opened. Simulator compilation has no callback Sendable warnings.

Private and Beta builds pass, the private signature verifies, and the distribution verifier confirms that the public Watch app has no microphone declaration or local audio diagnostic. The corrected phone and Watch builds were installed successfully. Physical recording, heard playback, denial, interruption and Stop cleanup remain open; Watch Dot voice is still unavailable. [Sanitized results](fixtures/watch-audio-crash-fix-validation.json), [physical test](WATCH-AUDIO-TEST.md).

## Repeat headlessly

Choose an available Watch simulator UUID from `xcrun simctl list devices available`. This does not require a connected iPhone or Watch. With `WATCH_SIM_ID` set to that UUID, run from the repository root:

```sh
swift test --package-path Probes/WatchAudio
xcodebuild -project DotWatch.xcodeproj -scheme DotWatchPrivate \
  -configuration Private \
  -destination "platform=watchOS Simulator,id=$WATCH_SIM_ID" \
  -derivedDataPath /private/tmp/dot-watch-simulator \
  CODE_SIGNING_ALLOWED=NO build
python3 tools/watch_audio_simulator.py --device "$WATCH_SIM_ID" \
  --app /private/tmp/dot-watch-simulator/Build/Products/Private-watchsimulator/DotWatch.app
```

The runner boots the selected simulator if needed, installs and launches the app, rejects a stale report, checks the new result, and exits nonzero on failure or timeout. It shuts down a simulator it booted; an already-booted simulator stays running. It launches no browser or Simulator GUI. Preserve the matching physical binary/dSYM before another rebuild when investigating a new device crash. Raw crash reports contain device identifiers and stay outside the repository.
