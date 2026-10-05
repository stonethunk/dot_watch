# Personal prototype setup

**Current private setup:** use the iPhone [Safari helper](PRIVATE-BROWSER-SETUP.md), then [Sync Watch sign-in](WATCH-STANDALONE.md). Signed build 4 is installed on the original paired devices; it moves signaling onto the Watch. The optional trusted-Mac bootstrap below remains a diagnostic path. The root README and acceptance record contain current status.


This is a development diagnostic. Watch support, self-contained sign-in, and CarPlay approval are unfinished.

## Build and install the iPhone app

Use Xcode 27.0 or newer stable, complete first launch, and review Apple's current Developer Program License Agreement in your developer account. The connected phone must trust the Mac, have Developer Mode enabled, and be unlocked for initial preparation.

```sh
xcodegen generate
swift test
xcodebuild -project DotWatch.xcodeproj -scheme DotPhone -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath DerivedData \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device DEVICE_ID \
  DerivedData/Build/Products/Debug-iphoneos/DotPhone.app
```

Set your own signing team in ignored local configuration; bundle identifier is `dev.dotwatch.app`. `project.yml` is the reproducible project source. The signed Debug build is installed on the test iPhone. Debug/Release/Beta do not request the ungranted CarPlay entitlement. PersonalCarPlay enables private diagnostics plus the entitlement; CarPlay enables public login plus the entitlement. Both must only be provisioned after Apple grants it. Do not confuse a successful unsigned build with an installable app.

## Private diagnostic sign-in

Close Dot before transferring a refreshed sign-in. The helper reads your existing Codex sign-in, copies only the access token/account to this app's container through the trusted device connection, and erases the Mac staging file. On launch, the app imports the file into device-only Keychain with after-first-unlock protection and deletes the phone staging file. No refresh token is copied; credentials are never compiled into the app.

```sh
python3 tools/pair_phone.py --codex-auth-file "$HOME/.codex/auth.json" --device DEVICE_ID
xcrun devicectl device process launch --device DEVICE_ID dev.dotwatch.app
```

Dot should discover your actual character. Tap **Talk to Dot**, grant microphone permission, and speak. **Mute** gates outgoing audio; **End** closes audio immediately and releases the remote call. An unsuccessful remote release keeps a blocked state; retry End rather than starting another call. No conversation transcript or recording is saved by the native app. `Documents/diagnostics.json` contains only booleans, session state, and event counts.

On an expired sign-in, renew it through the official Codex/OpenAI sign-in flow and repeat the private transfer. This is the temporary diagnostic procedure, not the finished iPhone OAuth experience. Sign out in this app to delete the Keychain entry and character cache. Ending an active session must complete before sign-out.

## Character and audio

Refresh connection and appearance while idle to fetch customization changes. Only hash-verified artwork replaces a cached image. The existing valid image survives failed refresh. Accounts use separate hashed cache directories; sign-out clears them. Playback-level pulses run at 10 Hz on the phone, and stop visually with Reduce Motion or when the scene is not active.

The native iPhone library is `stasel/WebRTC`, commit `0c0ad84dac6c1941c16a414dfcfba94691866e4c` (M154), binary SHA-256 `a2bcdda93578c82452ceb6e49d54a2746e1bcb4caf7c2fa601ffac8028b58c16`. Notices are included in the app resources. This binary supports iOS, not watchOS.

## Troubleshooting

- **Updated program agreement / no profile:** review the agreement in Apple's developer account, then rebuild with automatic provisioning. Xcode's local first-launch agreement is separate.
- **Developer image / locked device:** unlock the phone and retry preparation. USB is useful for initial pairing; a trusted wireless development connection can be used later when available.
- **401:** renew the existing official sign-in, then pair again. Never paste tokens into chat.
- **403:** preserve the verified Dot endpoint/header format. Do not replace it with generic Codex voice routes or bypass service access controls.
- **Audio off, retry End:** local audio is closed; remote stop was not confirmed. Keep retrying End only when connectivity is restored. Ambiguous allocation without a call ID currently requires investigation; do not reset the adapter and silently allocate duplicates.
- **CarPlay app absent:** the conversational entitlement and matching profile are required. The source/entitlement file alone is insufficient.

## Protocol maintenance

Keep undocumented requests in DotCore. Compare the installed official client's Dot-specific flow when the protocol changes; use it as a lead, then re-run a bounded real-account diagnostic. Never log credentials, SDP, signed asset URLs, transcripts, or raw service errors. Add only sanitized synthetic fixtures to source control. Repeat physical acceptance after audio/session changes.
