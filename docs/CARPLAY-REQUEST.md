# Prepared CarPlay entitlement request

**Status: prepared; not submitted or granted.**

Developer: the app maintainer. Select your own Apple Developer team; `YOUR_APPLE_TEAM_ID` below is a placeholder. Their embedded metadata was read locally; they were not reissued or modified. Neither inspected profile includes the conversational CarPlay entitlement. A valid Apple Development signing identity is available in the login Keychain.

App name: **Dot**. Personal app identifier: **dev.dotwatch.app**. The signed development profile identifies `YOUR_APPLE_TEAM_ID.dev.dotwatch.app`.

Category: **Voice-based conversational app**.

Requested entitlement: `com.apple.developer.carplay-voice-based-conversation`.

## Send the request

1. Open [Apple's CarPlay entitlement request](https://developer.apple.com/contact/carplay/) and sign in using the Apple Developer membership for team `YOUR_APPLE_TEAM_ID`. Apple's [CarPlay page](https://developer.apple.com/carplay/) links to this form as **Request CarPlay app entitlement**.
2. Use app name **Dot**, bundle identifier **dev.dotwatch.app**, and category **Voice-based conversational app**. Describe release status as a private prototype in development.
3. Paste the request text below into the description. The authenticated form's exact fields have not been inspected; these are the app's verified details, not a reproduction of its field labels.
4. Submit and retain Apple's confirmation/reference number. Record submission status here after confirmation. Approval is not established by submitting.
5. After Apple grants the capability, enable it on the existing app identifier and obtain a matching development profile. Rebuild `DotPrivate` with configuration `PrivateCarPlay`, inspect the signed entitlements/profile and install that build before the vehicle test.

## Request text

I am building a personal iPhone app that provides voice access to my existing ChatGPT Dot through a dedicated CarPlay dashboard interface. The phone owns networking, microphone capture and playback. After setup on the iPhone, opening Dot from its CarPlay app icon presents the voice-control template with the user's cached Dot character, brief connection/activity status, and a Talk action. An active conversation provides Mute/Unmute and End controls. Connecting CarPlay alone does not begin recording. Responses are spoken; the driving interface displays no response transcripts or generated images. Ending the experience or disconnecting CarPlay stops recording and playback and releases the audio session. Authentication, permissions, account selection and interactions that cannot be completed safely in CarPlay remain on the iPhone.

## Submission and provisioning checklist

- [x] Confirm the existing personal app identifier in its signed development profile.
- [ ] Submit through [Apple's CarPlay access page](https://developer.apple.com/carplay/).
- [ ] Receive Apple's entitlement grant.
- [ ] Create a matching development provisioning profile for the app and test phone.
- [ ] Inspect the signed app and embedded profile; both must contain the granted entitlement.
- [ ] Complete wired and wireless physical vehicle tests.

`Configuration/CarPlay.entitlements` expresses the requested capability only. Do not mark this checklist complete because that file exists.

Implementation follows the [CarPlay Developer Guide](https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf) and [Apple's CarPlay voice session](https://developer.apple.com/videos/play/wwdc2026/212/): iOS 26.4 minimum, a dedicated `CPTemplateApplicationSceneDelegate` and `CPVoiceControlTemplate` dashboard interface, play-and-record/default audio mode without mixing, and service lifetime independent of the visible phone scene. Xcode 27.0 is installed and the normal private app signs successfully. On 2026-10-04 its profile still lacks the conversational capability. Eight headless native-framework/session tests pass; visual head-unit, real voice and vehicle tests remain open. The separate CarPlay build configuration requests the capability; normal phone builds do not. [Testing and mobile feedback](CARPLAY-TESTING.md).
