# Acceptance record

Check only observed outcomes. Compilation is not a physical runtime result.

## Private first iteration (priority set 2026-10-03)

- [x] Scope fixed to two people, each with their own account and actual Dot.
- [x] Dedicated Private/PrivateCarPlay configurations and private archive/export instructions prepared.
- [x] Signed private phone build and 39 shared automated tests pass; Beta binary contains no private importer or private Watch voice controller.
- [x] the test iPhone consumes the renewed USB staging file, reads its device-only Keychain and loads its authentic character (2026-10-04 safe diagnostics).
- [x] Updated signed private build 0.1.0 (2) installs on both the test iPhone and Watch; fresh schema 3 phone diagnostics show ready, cached credentials and authentic character, confirmed by the user. No new transfer was performed. [Build/runtime boundary record](fixtures/watch-live-voice-validation.json).
- [ ] Independently cold-launch the test iPhone again with no staging file and confirm cached sign-in.
- [ ] Physically verify iPhone-only Safari enrollment and renewal; helper implemented, live browser test pending.
- [ ] Provision second tester's phone with her explicitly approved own-account sign-in; verify her Dot/character/continuity.
- [ ] Verify accounts cannot be silently replaced, refresh tokens are discarded, and sign-out clears staging/credentials/assets on both phones.
- [ ] Complete Watch audio/interface and physical acceptance for each pairing.
- [ ] CarPlay approval and vehicle testing for the private build.

## Connection milestone

- [x] Resolve actual primary Dot and validate existing conversation identity.
- [x] Retrieve and hash-verify authentic character snapshot.
- [x] Create, attach, exchange synthetic speech, receive audio/events, and stop actual Dot voice.
- [x] User confirms the test phrase is recalled by the existing iPhone Dot.
- [x] Reproducible probe, safe connection specification, synthetic fixtures, and diagnostic auth procedure.
- [ ] Verify one harmless request through an existing read-only integration.
- [ ] Verify portable iPhone sign-in and serialized refresh.
- [ ] Select Watch transport after real-device tests.
- [x] Isolated Watch-compatible transport exchanges synthetic Opus/SRTP packets and Dot events on Mac; adapter cross-compiles for watchOS 26.
- [x] Isolated native Opus codec passes three Mac synthetic tests and cross-compiles for watchOS 26; physical codec/audio test remains pending.

## Shared/native implementation

- [x] Undocumented endpoints isolated in shared package.
- [x] iPhone WebRTC dependency pinned to an immutable revision and artifact checksum.
- [x] Phone/Watch/CarPlay coordinator closes media before transfer; missing Watch stop acknowledgement blocks replacement even after server stop succeeds.
- [x] Automated failed-stop, duplicate-start, and end-during-allocation coverage.
- [x] Native Keychain storage and account-scoped, hash-verified character cache implemented.
- [ ] Verify credential import, deletion, cold start, cache refresh, and sign-out on the phone.
- [ ] Physical phone microphone/audio session test, mute/end, permission denial, interruptions, locked-phone operation.

  On 2026-10-04 the user reported talking to Dot on the phone and ending it. A subsequent sanitized report was `signed_out`; after the user signed in again, the app reports ready, configured and authentic character loaded. Transcript counters are still zero. Preserve the user report, but keep independently observed native microphone/audio, mute/end and continuity checks open. Do not renew credentials over an explicit sign-out.
- [ ] Verify expired authorization, quota/service errors, appearance refresh after customization, and no content in logs.
- [ ] Implement durable reconciliation across process termination after an ambiguous allocation.
- [ ] Verify transcript payload fields, duplicates, safe interruption/resumption, and pending approvals.
- [x] Synchronize authentic character and revocation metadata with Watch; nine ordering/account/cache tests pass.
- [x] Implement private Watch ownership/control and remote stop acknowledgement; transfer, blocked-stop retry, end-during-activation and queued-start cancellation tests pass. Physical switching remains open below.

## Watch

- [x] Native app and WidgetKit complication compile/sign; Watch app installed and actual character confirmed by user.
- [x] Private five-second local audio test compiles/signs and is installed on the test iPhone and Watch; public binary excludes its diagnostic and microphone permission. [Validation](fixtures/watch-local-audio-validation.json).
- [x] Symbolicate the immediate audio-test crash against matching symbols, correct the tap callback isolation, and pass eight package tests plus the headless Watch simulator preflight. Corrected signed builds installed; this does not establish physical audio. [Evidence](WATCH-AUDIO-CRASH-FIX.md).
- [x] Implement the private live Watch voice prototype, bounded Opus/audio buffers and stop-acknowledgement control path. Initial eleven audio package tests and the headless synthetic Watch simulator check passed. Quality and background operation remain open. [Transport and test procedure](WATCH-VOICE.md).
- [x] First physical direct Watch dialogue reported by user on build 2; safe diagnostics show RTP capture/playback and clean audio release. Initial response quality failed due to jitter. Build 3 timing/reorder fixes pass twenty audio regression tests; user reports clearer replies with little or no jitter. The short physical comparison records zero receive gaps/overflow and clean audio release.
- [x] Signed build 3 installed on the test iPhone and Watch; exact symbols preserved. Following the user trial, fresh build 3 phone diagnostics report ready with cached sign-in and authentic character. [Evidence](fixtures/watch-jitter-fix-validation.json).
- [ ] Review bounded uplink frame drops and measure input quality during the ten-minute physical test; short build 3 trial discarded 57,024 resampled frames.
- [ ] Verify complication placement and one-tap launch on the physical Watch.
- [ ] Run **Test Watch audio** physically: confirm heard recording/Opus/playback, Stop cleanup, denial and interruption. The first retry report shows capture started, recording cancelled before codec/playback, and audio released. The reason was absent in schema 1; a signed update adds countdown, explicit cancellation messages and timestamps. Heard playback, denial and interruption remain pending. Eight synthetic audio/buffer/callback tests pass. [Retry evidence](fixtures/watch-audio-feedback-validation.json).
- [ ] Authentic cached character; <=20 fps active animation; still when dimmed or Reduce Motion.
- [ ] Direct transport proven, or an explicitly selected relay proven with locked phone.
- [ ] Ten-minute conversation, phone locked, periodic wrist-down. Build 3 lost its phone lease. Build 4 removed that dependency but two trials lost transport at about 38 seconds, including a foreground trial. Build 5 corrects ICE addressing and consent refresh; physical retest remains open. [Evidence](WATCH-CONNECTION-TIMEOUT.md).
- [x] Implement authenticated periodic consent checks, pure reciprocal consent responses, correct peer addressing and safe failure snapshots. Ten headless transport tests pass, including a ten-minute synthetic clock and rejection/expiry cases.
- [ ] Physically verify build 5 passes 90 seconds, then ten minutes with a locked phone and periodic wrist-down, with Mute/End and audio release.
- [ ] Physically confirm local connecting ringback is audible and stops at ready, End, failed startup and interruption, without being sent to Dot.
- [x] Implement encrypted Watch credential setup, device-only storage, Watch-owned HTTPS signaling, cleanup journal and acknowledged phone handover. Five encryption/replay tests and two recovered-stop regressions pass.
- [ ] Physically verify Watch credential sync, account identity, expired-token renewal, sign-out revocation and fail-closed device handover.
- [ ] Start and sustain voice on Watch Wi-Fi/cellular with the phone unavailable, then End and verify cleanup.
- [ ] Speaker/headphones, interruptions, denial, mute/end, repeated starts, suspension and reconnection.
- [ ] Startup delay, audio quality, battery, and animation impact measured.

## CarPlay

- [x] Scene delegate/voice-control template source compiles with iOS 26.4 minimum.
- [x] Source supplies authentic cached image, two or fewer action buttons, and no answer transcripts.
- [x] Source starts only from Talk, closes its session on disconnect, and uses play-and-record/default with no mixing.
- [x] Eight headless iOS 27 tests exercise native template/image objects, the actual action path and shared coordinator with synthetic signaling/media. Setup/denial, controls, transfers, disconnect/reconnect races and failed-stop retry pass. [Evidence and mobile brief](CARPLAY-TESTING.md).
- [ ] Render the dedicated CarPlay head-unit screen and validate root-template acceptance, screen sizes and input methods.
- [ ] Apple entitlement granted and embedded provisioning independently verified.
- [ ] Cold launch without phone scene, locked phone, wired/wireless connections.
- [ ] Vehicle microphone/speaker routing, navigation, Siri and telephone interruptions; previous audio restoration.
- [ ] Layout/input methods and phone/Watch/CarPlay transfer tested without duplicate capture.

## Delivery

- [x] Signed personal iPhone build installed on the test iPhone; authorized private transfer succeeded.
- [x] Signed personal Watch build installed (2026-10-04).
- [ ] Approved CarPlay provisioning and physical vehicle validation.
- [ ] Independent rebuilding, credential renewal, troubleshooting, and maintenance instructions exercised.

## Beta and public distribution (scope added 2026-10-03)

- [x] Native system-authentication and PKCE callback foundation implemented; eight adversarial sign-in tests pass.
- [x] Separate verified-identity Keychain storage; ID tokens never become Dot credentials.
- [x] Beta build compiles; private diagnostic credential import/read excluded from public configurations.
- [x] OpenAI client/Dot authorization request prepared with beta/publication gates.
- [ ] Registered native OpenAI public client, exact callback, and live sign-in.
- [ ] Explicit Dot voice/context/artwork grant and permission for beta/production service access.
- [ ] Clean second-user login, account selection, grant renewal/revocation, and sign-out/cache/pairing cleanup.
- [ ] Publisher, source model, app identity, branding/artwork permission, support/privacy URLs, and disclosures finalized.
- [ ] Signed archive validated, TestFlight review/distribution, and completed App Store release.
