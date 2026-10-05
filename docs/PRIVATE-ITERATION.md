# First private iteration: two people, two accounts

**Update October 4, 2026:** build 3 completed short physical Watch conversations but could lose its iPhone lease while the phone was typically locked. Build 4 moves credentials/signaling onto the Watch after encrypted setup. Its physical validation remains open. See [current standalone architecture](WATCH-STANDALONE.md) and the root README; the dated evidence below is historical.

Decision on 2026-10-03: continue private development for two private testers before public OpenAI registration. Each uses their own OpenAI account and existing Dot. Public login and distribution remain a later phase; no partner application has been submitted. On 2026-10-04 the user selected iPhone-only browser setup for the second tester; the private Safari helper is implemented and signed, with its live enrollment test pending. [Safari setup](PRIVATE-BROWSER-SETUP.md).

## Credential and account behavior

- The private iPhone app reads its own device-only Keychain item after first unlock. It does not extract the official ChatGPT app's protected Keychain or manufacture authorization.
- Initial setup is a one-time, explicitly authorized transfer from that person's existing official sign-in to their own trusted phone. No developer credential is bundled or shared between users. The second account has not yet been provisioned or tested.
- The helper transfers only an access token and account identifier. The app canonicalizes that allowlist before Keychain storage; even an unexpected refresh token in an input file is discarded. Both staging copies are removed after successful setup; failed imports also remove the phone staging file.
- Replacing a cached account requires sign-out first. Renewing the same account is allowed while idle. Each account resolves its own actual Dot and uses a separate hashed character-cache location. Sign-out removes its Keychain item, staging file, identity metadata and character caches.
- Tokens still expire or can be revoked. The cache is not an indefinite login and does not automatically refresh. Renew through the person's official sign-in, then repeat the private transfer. Never paste credentials into chat, a shared file, or command-line arguments.
- Same phone application identifier as the existing installation: `dev.dotwatch.app`. Installing a public Beta/Release build over it clears private setup intentionally. Use the private scheme throughout this iteration.

The testers' phones each have their own local session coordinator. Watch/phone/CarPlay ownership will coordinate within each person's pairing; accounts must not coordinate voice ownership with one another or share character/credentials across households.

## Private build and install

`DotPrivate` uses the optimized `Private` configuration with private Keychain setup enabled. Debug remains available for investigation. Beta and Release continue to exclude private setup. `PrivateCarPlay` adds the CarPlay entitlement only after Apple grants it and a matching profile exists.

```sh
xcodegen generate
swift test
xcodebuild -project DotWatch.xcodeproj -scheme DotPrivate -configuration Private \
  -destination 'generic/platform=iOS' -derivedDataPath DerivedData \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device PERSONS_PHONE_DEVICE_ID \
  DerivedData/Build/Products/Private-iphoneos/DotPhone.app
```

Register and provision only the intended testers' devices with the existing Apple Developer team. Direct development installation is appropriate while debugging. For a later private IPA, the scheme archives with Private and `Configuration/ExportOptions-Private.plist` requests Apple's `release-testing` export rather than App Store Connect. That export still requires registered device IDs and matching distribution provisioning; neither an archive nor an export is a physical test result. Do not upload this private configuration to TestFlight or the App Store.

## Each person's initial setup or renewal

The person first signs in through an official OpenAI client on a trusted computer and approves transferring their own access token to their own phone. Choose that person's existing auth file explicitly. Do not sign out the primary tester's existing desktop session to obtain another person's credentials, automatically search for their credentials, or duplicate the primary tester's token onto their phone.

Close Dot and finish any active voice session before a renewal transfer:

```sh
python3 tools/pair_phone.py \
  --codex-auth-file PATH_TO_THIS_PERSONS_AUTH_FILE \
  --device THIS_PERSONS_PHONE_DEVICE_ID
```

Unlock the phone and open **Dot**. Confirm their authentic character, complete a short voice exchange, mute, then End. Check continuity in their own official ChatGPT Dot. Verify the transfer file has disappeared and that cold launch uses the cached Keychain without another transfer. For an account change, sign out and verify cleanup before importing the new account.

## Current evidence and remaining gates

The primary tester's signed app is installed on the test iPhone. On 2026-10-04, the expired cached sign-in returned 401; renewal from his current official Mac sign-in succeeded. Safe device diagnostics now show Keychain credentials present, configured true and authentic character loaded; `Documents/paired-session.json` has been removed. An independent cold launch without a staging file and native microphone/audio tests remain. No recording starts on launch; a person must choose Talk on the iPhone.

The Mac probe has already demonstrated the real Dot voice protocol and authentic character; the user confirmed continuity in the official iPhone Dot. The Watch-compatible transport has exchanged synthetic audio on Mac and cross-compiled for watchOS 26. The Watch is now visible and its signed character app is installed; the user and safe Watch diagnostics confirm the authentic character appears. Watch voice, wrist-down/locked-phone acceptance and complication interaction remain unfinished. CarPlay source compiles, but the entitlement and vehicle test remain required even for this private iteration.

Pass those physical gates for both accounts before calling the first iteration complete. See [ACCEPTANCE.md](ACCEPTANCE.md). Public registration should not block private interface work, but successful private access does not establish permission or readiness for general distribution.

The signed Private build and public Beta build pass compilation. The current 33 Swift tests (21 core/session, three private credential, nine character pairing) and eight browser-logic tests pass. Binary checks verify that the private importer and Safari extension are present only in Private, with all dependency notices preserved. The final purple/cyan icon update is installed on both devices. Its attempted phone cold launch was blocked by a locked phone, so that gate remains pending. [Current validation](fixtures/private-browser-watch-validation.json), [earlier validation](fixtures/private-iteration-validation.json). These records do not substitute for the pending browser, microphone, Watch voice and vehicle tests.
