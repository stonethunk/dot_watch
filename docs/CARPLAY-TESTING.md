# CarPlay verification and vehicle feedback

The headless iOS 27 tests exercise real `CPVoiceControlTemplate`, `CPVoiceControlState`, buttons and image objects, plus the production session coordinator and the same action/lifecycle path used by the scene delegate. Eight tests pass: setup/permission denial, explicit Talk, Mute/Unmute, End, disconnect, disconnect during delayed startup, reconnect during startup, Watch-to-CarPlay transfer, failed-stop retry, and character refresh. Connecting a display cannot allocate a call, and stale actions cannot restore audio after disconnection.

Signaling and media are synthetic fixtures. Tests open no microphone, make no service request and use no credentials. They do **not** connect a `CPInterfaceController`, render a head-unit screen, validate a real Dot exchange or simulate vehicle audio. Those gates remain open. [Recorded result](fixtures/carplay-runtime-validation.json).

```sh
xcodegen generate --spec Tests/CarPlayRuntimeTests/project.yml --project Tests/CarPlayRuntimeTests
xcodebuild -project Tests/CarPlayRuntimeTests/DotCarPlayRuntime.xcodeproj \
  -scheme DotCarPlayRuntime \
  -destination 'platform=iOS Simulator,id=IOS_27_SIMULATOR_UUID' \
  -derivedDataPath /private/tmp/dot-carplay-runtime \
  -resultBundlePath /private/tmp/dot-carplay-runtime-new.xcresult \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

Use a new result-bundle path for each run. The isolated test project avoids bringing phone/Watch SDKs or private sign-in into the test runner. No visible simulator window or browser is required.

For a visual head-unit test, Apple documents the iOS Simulator's CarPlay external display and the CarPlay Simulator in Xcode 27 Device Hub. Use a simulator app with the conversational entitlement; the standard Private app lacks this capability. Test minimum, portrait, standard and wide displays, touch and rotary input. This visual step has not been performed; current global instructions require headless verification. [Apple simulator guidance](https://developer.apple.com/documentation/carplay/using-the-carplay-simulator), [Xcode 27 CarPlay session](https://developer.apple.com/videos/play/wwdc2026/212/).

## Prerequisite for the car

The installed private app's development profile identifies `YOUR_APPLE_TEAM_ID.dev.dotwatch.app`. On 2026-10-04 its conversational entitlement was absent. Apple must approve `com.apple.developer.carplay-voice-based-conversation`, and a matching `PrivateCarPlay` build/profile must be signed, verified and installed before Dot can appear in the car. The ordinary Private build is for phone/Watch testing. [Prepared request](CARPLAY-REQUEST.md).

## Feedback from your iPhone

You can cite this development chat's deep link in the chat you use for testing. Include this brief's facts in a cloud handoff if it cannot access the local chat/files. A separate cloud chat can collect observations while the Mac is asleep. Codex Remote in the ChatGPT iPhone app can continue this local chat while the Mac is online. Neither path makes a CarPlay entitlement available or installs a local signed build by itself. [Official remote guide](https://learn.chatgpt.com/docs/remote-connections), [cloud guide](https://learn.chatgpt.com/docs/environments/cloud-environments).

The personal iPhone app's **Share diagnostics** exports only fixed state/error labels, timestamps, build identity, character/credential-presence booleans and event counts. It includes whether a CarPlay display connected and whether the system accepted the template. It contains no token, account/Dot identifiers, SDP, recording or transcript. A report is evidence of software state; hearing the car's response still needs your confirmation.

While parked, start with these checks:

1. Confirm the approved build/version and wired or wireless connection. Open Dot from the CarPlay app icon; confirm your authentic character and the Talk action. Connecting the car alone must not start recording.
2. Tap Talk, make a short spoken request, and confirm capture through the car microphone and response through its speakers. Record startup delay and the exact status/error, without private conversation content.
3. Tap Mute and confirm speech is not sent; Unmute and speak again. Tap End and confirm capture/playback stop and other audio returns.
4. Start again and unplug/disconnect CarPlay. Confirm voice ends and does not move to the phone speaker. Reconnect; no automatic recording should begin.
5. With no phone scene open, lock the previously unlocked phone, then launch Dot from the car. Verify navigation prompts, Siri and telephone interruptions separately.
6. Start on Watch, then Talk here in CarPlay. Confirm Watch stops before car capture begins. End, share diagnostics, and report what you heard.

For each trial, report `build; wired/wireless; phone locked/unlocked; action; expected result; observed result; exact short error; approximate time`. Record pass/fail per trial instead of declaring the whole feature complete from one successful exchange.

The cloud feedback chat should keep the same existing Dot, private two-account separation and acceptance gates. It must not request tokens, reset a failed-stop gate, configure mail, or claim access to this Mac while it is unavailable. Build and profile changes return to this development chat. Mail setup remains delegated to its existing chat.
