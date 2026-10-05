# Watch-owned Dot voice: private builds 4–5

The phone is used for Safari sign-in, account verification, initial credential
sync and character updates. The Watch now owns Dot discovery, conversation
verification, authenticated voice creation/attach/stop, and direct SRTP/Opus
audio. Active voice does not send phone heartbeats or require a phone reply.
The existing Dot and its server-selected context/capabilities are preserved.

## Setup and renewal

1. Open the private Dot app on the iPhone; verify Ready and your actual character.
2. Open Dot on the paired Watch, refresh the character, then tap **Sync Watch sign-in**.
3. Wait for **Watch sign-in saved**. Tap **Talk to Dot**. Mute and End are local
   Watch actions; End also stops the server connection from the Watch.
4. Keep the phone locked for a ten-minute wrist-down trial. Separately test with
   the phone unavailable and the Watch on usable Wi-Fi or cellular.
5. On expiry, renew with the private Safari helper on iPhone and sync again.
   If an expired token prevented End, local audio remains off and Sync is allowed
   once local cleanup finishes, so the renewed token can retry server release.

No refresh token is copied. Simulator images do not prove enrollment or voice.
The direct adapter still lacks TURN, IPv6, candidate failover and safe resumption.
There is no always-on Mac or hosted relay. Watch networking may use system routing
via a nearby phone; independent network operation must be tested separately.

## Credential boundary

The Watch creates a Curve25519 key agreement key in its own Keychain. Its public
key goes only to the paired app through an immediate, correlated WatchConnectivity
message. The phone encrypts the allowlisted access-token/account payload using an
ephemeral X25519 exchange, HKDF-SHA256 and AES-GCM. Associated data binds the
recipient public key, account/Dot character pairing and ownership generation.
No plaintext bearer is written to a file, application context or background file
transfer. Passwords and refresh tokens never enter this protocol.

Credentials and the private pairing key use `AfterFirstUnlockThisDeviceOnly`,
with Keychain synchronization disabled. A device must be unlocked once after
restart; the items do not migrate to another device. The Watch validates the
account hash and discovered Dot identity before opening microphone streaming.
The public `DotPhone` Beta/Release build excludes this private sync and voice code. The private Watch target rejects Beta/Release at compile time; a public
Watch upgrade clears the private Keychain namespace.

## Ownership and failures

The phone persists a Watch ownership grant **before** delivering a credential.
That durable delegation survives app relaunch and does not expire when a phone
heartbeat is missed. Watch permission remains delegated after End so the next
Watch conversation can start without the phone. Duplicate and old generations
cannot undo an acknowledged revocation.

To start on iPhone/CarPlay, the phone requests revocation. The Watch first closes
local capture/playback/transport, awaits any in-flight allocation and confirms
server stop, then deletes its cached token and persists a revocation tombstone.
Only its positive acknowledgement permits phone voice. A timeout, inaccessible
Keychain or failed stop blocks handover. Open the Watch app and retry; explicit
**Sync Watch sign-in** delegates permission back to the Watch. Automatic character
refresh must not undo a phone handover.

A device-only journal is written before allocation. A known Dot/call identifier
can be stopped after relaunch; SDP, audio and transcripts are never journaled.
Unknown allocation outcome or failed release blocks new sessions. The observed
protocol has no verified reconciliation for an allocation with no call ID; this
requires investigation in the official client, not a blind new allocation.
Connection loss immediately discards unsent speech and stops local audio.

Phone sign-out clears its credentials and publishes character revocation. On
receipt, the Watch stops voice and removes its credential. An offline Watch
cannot receive that revocation immediately; invalidate the underlying account
session to revoke server access immediately. The phone retains a non-secret
ownership record until a release acknowledgement, including across account
changes. Each person uses their own account, Watch key and paired phone.

## Evidence and remaining gates

- Five cryptographic/replay/account-boundary tests and two recovered-stop API
  regressions pass in the root suite (46 tests total).
- Build 3 physically completed dialogue with clearer playback, then a longer
  trial ended with `phone_lease_lost`; the phone is typically locked.
- Signed build 4 is installed on the paired phone and Watch. [Sanitized build/test record](fixtures/watch-standalone-validation.json).
- Two build 4 physical conversations failed at about 38 seconds; one remained
  foreground with the screen awake. Safe reports show `transport`, Watch
  ownership, no phone heartbeat and clean audio release. Build 5 corrects ICE
  response addressing and authenticated consent refresh, with ten protocol
  tests passing. The ten-minute clock test is synthetic, not physical acceptance.
  [Failure evidence, implementation and retest](WATCH-CONNECTION-TIMEOUT.md).
- Build 4 replaces that control dependency. Compilation and unit tests do not
  establish physical credential enrollment, independent routing or sustained voice.
- Physical gates: enrollment, renewal, account/character match, locked phone,
  absent phone, ten-minute wrist-down, interruptions, battery, cleanup after
  disconnection/relaunch and successful/failed phone-CarPlay handovers.

Build 5 starts a quiet local ringback after audio permission/activation and keeps
capture muted until the authenticated channel is ready. End, setup failure and
handover all use the existing audio teardown to stop it. No ringtone is sent as
microphone audio. Physical audibility and correct stop timing remain test gates.

Apple permits HTTPS networking on watchOS, but restricts low-level networking to
specified active audio/call use cases. Its simulator does not enforce the same
restriction. Test without the phone by disabling its Wi-Fi and Bluetooth in
**Settings**, while ensuring the Watch has its own working connection.
[Apple TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos).
The chosen Keychain accessibility is intended for access after the first unlock.
[Apple Keychain documentation](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly).
