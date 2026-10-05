# Repeated connection loss: build 4 evidence and build 5 correction

The user reported two conversations ending at approximately 38 seconds from
starting. The first failure occurred with the Watch screen still awake. Both
retrieved reports identify build 4, an active-session `transport` failure,
Watch-owned signaling, no required phone heartbeat and released local audio.
They record RTP in both directions. Neither contains a recording, transcript,
credential, SDP, endpoint address or account/Dot/call identifier.

[Sanitized reports and validation record](fixtures/watch-consent-validation.json).
The old diagnostic schema collapsed several transport failures into one label;
it cannot prove which server/network event caused these closures.

## Verified implementation gaps

The native UDP adapter called `WebRTCConnection.receive` without the connected
peer's encoded address. The pinned ICE controlling implementation declines to
answer reciprocal checks unless given an IPv4/IPv6 source address. The initial
connectivity check could succeed while later peer checks went unanswered.

The adapter also had no periodic outbound consent refresh. Recalling the
initial ICE check after connection would return immediately without sending a
fresh transaction. [RFC 7675 section 5.1](https://www.rfc-editor.org/rfc/rfc7675.html#section-5.1)
specifies authenticated refresh, normally at randomized 4–6 second intervals,
and cessation of application traffic after 30 seconds without verified consent.
These gaps fit the timing; the precise cause of the physical failure remains
an inference until a new trial validates the correction.

## Build 5

- Pass the validated connected candidate's IPv4 address and port to the existing
  ICE stack, including reciprocal nomination/triggered checks.
- Send fresh randomized authenticated STUN consent requests on the same UDP
  connection. Track bounded outstanding transactions, validate response MACs,
  optional fingerprints and transaction identity, and reject replay/forgeries.
- Answer authenticated pure consent requests without requiring ICE nomination
  attributes. Responses describe the connected peer address; incoming requests
  do not grant permission for our own outbound media.
- Stop media on consent expiry or authenticated 403 revocation; a late response
  cannot revive an expired connection. Do not add automatic reconnection or
  reuse expired ICE credentials.
- Preserve fixed-label protocol/network failure, consent counts and monotonic
  durations before teardown. Never log server bodies, event content, passwords,
  addresses, transaction IDs or microphone samples.
- Play an original generated 440/480 Hz ringback, two seconds on and four off,
  through the native audio player while connecting. Capture remains muted;
  ringback is stopped and discarded before streaming, on End and on failure.

All changes are in original adapter/app sources. The 168 hash-pinned upstream
protocol files are unchanged. Existing encrypted Watch setup, device-only
Keychain storage, single-session ownership and acknowledged server stop remain.

## Headless verification and physical retest

Ten transport tests include ten minutes of **virtual time** with authenticated
responses, missing replies at 30 seconds, replay/forgery, delayed responses,
403 revocation, interval bounds, malformed packets and the published RFC 5769
STUN authentication test vector. Twenty native audio regressions pass. These
tests do not contact an account or open a microphone.

1. Open the updated Watch app and tap Talk. Confirm ringback during setup and
   silence from the ringback once Listening appears. No new sign-in is needed
   while the stored token is valid.
2. Keep the Watch screen awake for a 90-second exchange, then End. This isolates
   the repeated foreground failure before testing suspension.
3. Separately run a ten-minute exchange with the iPhone locked and periodic
   wrist-down. Test independent Watch Wi-Fi/cellular with the phone unavailable
   separately; watchOS may still choose system networking through a nearby phone.
4. Confirm Mute/End, interruption and failed-startup ringback cleanup. If it
   fails, retrieve the new safe report's transport fields, not account data.

Physical sustained operation, ringback audibility, wrist-down, absent-phone
networking and battery behavior remain unverified until those trials pass.
