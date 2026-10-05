# Diagnostic evidence — 2026-10-03

## Verified service connection

The authenticated Swift discovery probe resolved the user's actual primary Dot and existing root conversation. Identity matched between the primary selection, profile, and cloud thread endpoint. No IDs or credentials are included in this record.

The authentic rendered snapshot was retrieved: 512×512 PNG, 213,729 bytes. Its SHA-256 matched the published snapshot hash. The original private asset remains at `.private/character.png`. It was inspected visually; no approximation was substituted.

The Dot-specific REST/WebRTC route was identified in the installed official client and verified using the user's existing authorized session. Successful silence probe: create 201, attach 200, connected WebRTC, stop 200, 301,408 audio bytes received. Successful synthetic-speech probe: create 201, attach 200, connected WebRTC, stop 200, 368,282 audio bytes sent and 1,948,768 received. Input/output transcript and turn events arrived. The probes opened no microphone.

The synthetic phrase included “marigold seven.” Its marker appeared in voice events. A bounded cloud-history search did not find it and was not treated as evidence of continuity. The user then checked the official iPhone Dot and reported **“Dot recalls marigold seven.”** Continuity is therefore **user-confirmed for this exchange**, not inferred from a shared identifier. The original automated report remains unchanged and still says the broader gate is incomplete.

Private evidence files (excluded from source control):

- `.private/dot-voice-silence-01.json`
- `.private/dot-voice-speech-01.json`
- `.private/connection-test.wav`
- `.private/dot-response-01.wav`
- `.private/character.png`

## Development platform

- Xcode 27.0 (27A266a), Apple Swift 6.4; first-launch setup completed.
- Connected iPhone 17 Pro, iOS 27.0.1; wired pairing, Developer Mode enabled, compatible developer image mounted.
- Existing Apple Development signing identity found; team YOUR_APPLE_TEAM_ID.
- Initial signed build failed because Apple's updated Program License Agreement must be accepted. This is distinct from the Xcode license and from Codex permissions.
- Native iPhone and CarPlay source compiled against iOS 27 SDK, deployment minimum 26.4.
- 21 Swift tests passed, including stop failure, transfer ordering, duplicate starts, cancellation during allocation, unknown-event handling, ambiguous server failure and observed identifier syntax.

## Watch-compatible transport probe

The isolated Swift/Network.framework adapter in `Probes/DirectWatch` cross-compiled for watchOS 26. Its live Mac test verified ICE, DTLS fingerprint binding, SRTP key installation and the `oai-events` channel. With the existing synthetic phrase encoded as Opus, the test sent 384 RTP packets, received 550 authenticated RTP packets and 54 data-channel events, found the synthetic marker in events, and received the stop acknowledgement. Evidence: `.private/watch-link-probe-04.json`. No microphone was opened. The first connection-only success is `.private/watch-link-probe-03.json`.

The probe initially exposed an overly restrictive local identifier check: the actual Dot ID contains `~`. The check now accepts this unreserved character while rejecting path/query syntax; the regression is tested, and fresh native discovery again verified Dot and conversation identity. No account ID is retained in the test fixture.

The Watch-compatible adapter does not yet encode a live microphone or decode/play the received Opus stream. It has not run on a Watch. Its results establish transport interoperation, not physical audio or background behavior.

## What this evidence does not prove

The native phone build has not yet completed a physical microphone exchange. No Watch transport, ten-minute wrist-down test, Watch character synchronization, integration invocation, CarPlay entitlement, signed CarPlay installation, or vehicle test has passed. Audio routing, reconnection, interruptions, battery use, and rendering require physical tests. Portable native OAuth/refresh remains unimplemented.
