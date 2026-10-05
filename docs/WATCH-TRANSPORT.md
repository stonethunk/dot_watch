# Watch transport investigation

Status: **short physical dialogue demonstrated on build 3; sustained/background transport acceptance remains open.** Build 4 removes the iPhone control lease and uses a securely synced Watch token; [standalone validation](WATCH-STANDALONE.md) is pending. The verified Dot voice endpoint requires WebRTC media plus the `oai-events` data channel. WatchConnectivity is reserved for pairing, control and character transfer; it is not being treated as a continuous audio transport.

## Evidence from 2026-10-03

The phone uses `stasel/WebRTC` M154. Its XCFramework includes iOS/macOS/Catalyst, but no watchOS slice.

The candidate [1amageek/swift-webrtc](https://github.com/1amageek/swift-webrtc) version 3.0.0, commit `f35ac95e4e743b1fb6be50c184e7d3691ef7ddb1`, **successfully cross-compiled for arm64_32, watchOS 26, using Xcode 27 / Swift 6.4**. The isolated probe package now pins this revision and its resolved dependency graph. The byte-identical source snapshot is now linked into the private Watch prototype under a distinct module name; it is not selected as the finished transport until physical tests pass.

The build resolved this graph:

| Package | Version | Revision |
| --- | --- | --- |
| swift-webrtc | 3.0.0 | f35ac95e4e743b1fb6be50c184e7d3691ef7ddb1 |
| swift-networking | 0.1.0 | c5da46c2ab2fd1244b40a208cd1fa406ead43dca |
| swift-ssl | 0.4.0 | 045d6c1ccffd5adc7f2da2fd748de86f05bbde9b |
| swift-tls | 2.1.0 | cbb2f5b3e3355c51cfea2edc6a8282fed16e790d |
| swift-log | 1.15.1 | 9c6fb14227f55d8f711ce3847dc2f419fb0ecacb |

Source inspection shows caller-supplied datagram transport, authenticated ICE checks, DTLS fingerprint verification, SRTP media, and SCTP/data channels. The built-in SDP helper is data-channel-only. Our bounded audio SDP and Network.framework UDP adapter are implemented in `Probes/DirectWatch`, and the complete adapter also cross-compiles for watchOS 26. The upstream README declares MIT, but one resolved dependency lacks explicit license metadata. The public repository fetches external source locally rather than republishing its implementation. Resolve dependency licensing before binary redistribution; see [third-party provenance](../THIRD_PARTY.md).

Live Mac probe evidence (`.private/watch-link-probe-04.json`): connected, data channel opened, 384 synthetic Opus RTP packets sent, 550 authenticated RTP packets received, 54 data events, synthetic marker detected, remote stop acknowledged. No microphone or speaker was opened. Incoming Opus is not decoded by this probe. This proves authenticated protocol interoperation but does not establish Watch audio, background functionality or battery suitability.

Reproduce from the repository root with an already-created synthetic WAV:

```sh
.private/webrtc-venv/bin/python tools/encode_synthetic_opus.py \
  --input-wav .private/connection-test.wav --output .private/new-synthetic-opus.json
swift build --package-path Probes/DirectWatch
Probes/DirectWatch/.build/debug/watch-link-probe \
  --codex-auth-file "$HOME/.codex/auth.json" \
  --synthetic-opus .private/new-synthetic-opus.json
swift build --package-path Probes/DirectWatch --target DirectWatchLink \
  --triple arm64_32-apple-watchos26.0 \
  --sdk /Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS.sdk
```

The initial adapter selects one public IPv4 UDP candidate, supports the negotiated Opus payload and DTLS role, bounds datagram queues, and supplies no application-level control or approval messages. The private app now supplies bounded jitter/playback queues, live native Opus, paired iPhone signaling/control, and acknowledged session ownership. Candidate failover, IPv6, TURN and safe resumption remain unimplemented. Keep physical networking/background gates open. [Current prototype](WATCH-VOICE.md).

## Required next probe

1. Add native capture/playback, codec adaptation, bounded audio buffers, jitter/loss handling and immediate teardown. Drop unsent input on loss; do not replay it.
2. Package a signed Watch diagnostic using an active audio session and private paired sign-in. Preserve certificate verification and authenticated ICE.
3. Run a physical Watch test, then a ten-minute phone-locked/wrist-down test. Measure startup, energy and quality before committing to direct transport.
4. If direct transport fails, investigate a phone relay separately and require the same background tests before proceeding with the finished Watch UI.

The physical Watch is now paired, available to Xcode and running the signed character app (2026-10-04). User confirmation and sanitized device diagnostics establish that the authentic character appears; they do not establish Watch voice.

## Native codec milestone (2026-10-04)

`Probes/WatchAudio` implements a bounded native `AVAudioConverter` Opus encoder/decoder without introducing another codec dependency. Input is mono 48 kHz float PCM in 960-sample frames. The adapter bounds compressed packets to 1,275 bytes and decoded packets to 120 ms, rejects nonfinite input, permits converter priming without replaying input, and exposes reset for complete session cleanup. Each instance requires serial use.

Three synthetic codec tests, four bounded-capture tests and a background callback regression pass on Mac. The separate synthetic codec probe encoded 50 packets, decoded 47,880 frames and detected the decoded signal. The library also compiles for watchOS 26. No microphone, playback or network is opened by the Mac probe. The package is now linked to the Private Watch app's explicit, foreground-only local recording/playback test; public configurations exclude that diagnostic. After an immediate physical tap-callback crash, the corrected callback and app codec pipeline also pass a headless watchOS simulator preflight. Runtime microphone availability, heard playback and physical cleanup still need verification. [Local test instructions](WATCH-AUDIO-TEST.md), [crash fix](WATCH-AUDIO-CRASH-FIX.md), [sanitized codec evidence](fixtures/watch-native-codec-validation.json).

Reproduce without credentials or a recording:

```sh
swift test --package-path Probes/WatchAudio
swift run --package-path Probes/WatchAudio watch-codec-probe
swift build --package-path Probes/WatchAudio --target WatchAudioKit \
  --triple arm64_32-apple-watchos26.0 \
  --sdk /Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS.sdk
```

Apple documents [AVAudioConverter](https://developer.apple.com/documentation/avfaudio/avaudioconverter) and the [Opus format identifier](https://developer.apple.com/documentation/coreaudiotypes/kaudioformatopus); successful compilation alone does not prove physical Watch codec or audio behavior.

Apple's [TN3135: Low-level networking on watchOS](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos) explains the runtime restrictions and why simulator networking is not adequate evidence. Use [background audio guidance](https://developer.apple.com/documentation/watchkit/playing-background-audio) for an actual user-started audio experience; do not claim background privileges from merely setting a project flag.
