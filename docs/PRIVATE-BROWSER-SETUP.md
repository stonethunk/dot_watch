# Private iPhone browser setup

Implemented on 2026-10-04 for the two-person private iteration. The signed app includes **Dot Private Sign-in**, a Safari web extension. Each person signs in on their own iPhone. Xcode is needed on the builder's Mac to sign/install the private app; it is not needed by the person to sign in or renew afterward. The devices still need private installation/provisioning before this setup is available.

This is an investigation of an undocumented, user-controlled ChatGPT browser session. It is separate from the registered public OpenAI sign-in foundation. Compilation and mocked browser tests do not establish a live Safari-to-Dot login. Complete the physical test below before claiming this path works for a second account.

## On the person's iPhone

1. Open **Dot** — the purple orb with cyan accents — and choose **Sign in using Safari**.
2. In Settings → Apps → Safari → Extensions, enable **Dot Private Sign-in**.
3. Open Safari, go to `https://chatgpt.com/` and sign in normally as that person. Confirm the correct account/workspace. Google/Apple/password authentication stays on the official website.
4. In Safari's page menu, select **Dot Private Sign-in** and choose **Connect this account to Dot**. This explicitly grants the private app access using that signed-in account's bearer token.
5. Choose **Return to Dot**. If the link does not switch apps, open Dot and choose **Refresh connection and appearance**. Returning to an idle app also consumes a pending transfer.
6. Verify the actual Dot character. On the iPhone, use **Talk to Dot**, **Mute** and **End**, and confirm continuity in official ChatGPT. On the Watch, choose **Refresh Dot** and **Sync Watch sign-in**. Build 4 starts voice from the Watch using its own device-only credential; physical locked/absent-phone validation is pending. See [standalone Watch setup](WATCH-STANDALONE.md).

Renewal uses these Safari steps again. A different cached account requires sign-out in Dot first. Never duplicate one person's sign-in onto the other person's phone.

## What moves and where

The helper runs only after its Connect button is selected, in the active tab's top frame and isolated script world. It refuses any origin other than `https://chatgpt.com` and performs a normal same-origin, no-cache, no-redirect fetch of `/api/auth/session`. This path and the token's account-claim keys were observed in the installed client; they are not a documented third-party login contract.

Only `access_token` and `account_id` reach the native extension. Locally decoded JWT claims select an account header; they are not accepted as proof of authorization. The native extension must discover the actual Dot and verify its selected conversation with the service before staging anything. It opens no microphone and starts no voice session.

Safari's native messaging connects this signed extension to its containing app. A protected, backup-excluded file inside `group.dev.dotwatch.app.private-setup` bridges the extension and phone app. The phone validates the account against its existing credential, saves the allowlisted payload in `AfterFirstUnlockThisDeviceOnly` Keychain and deletes the handoff on success or failure. Sign-out clears USB and browser staging, credentials and artwork. The app never reads ChatGPT's protected iPhone Keychain.

No token enters a URL, clipboard, web storage, DOM, console or error message. No refresh token, password or conversation is transferred. There is no hosted relay or Mac process involved in browser enrollment.

## Build boundary and tests

`DotPrivate` now builds the `DotPhonePrivate` target, with the same installed bundle ID and `DotPhone.app` product. Only this target embeds the Safari extension. `DotPhone`/Beta/Release do not embed it or compile its token importer. The phone app retains the app-group entitlement in public builds solely to delete any pending private handoff during an upgrade; public code does not read that payload. CarPlay configurations include the group alongside the still-ungranted CarPlay entitlement.

```sh
xcodegen generate
swift test
node --test Tests/PrivateSafariTests/session-reader.test.cjs
xcodebuild -project DotWatch.xcodeproj -scheme DotPrivate -configuration Private \
  -destination 'id=THIS_PERSONS_PHONE_UDID' -derivedDataPath DerivedData \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

The eight browser-logic tests cover explicit invocation, origin/redirect restrictions, expired/malformed sessions, the two-field allowlist, isolated top-frame injection and safe error text. They use synthetic credentials and mock browser APIs; no browser is launched and no real session is accessed by those tests.

## Physical browser gate

- [ ] Enable the actual extension in Safari on the test iPhone.
- [ ] Verify an existing own-account browser login reaches Dot and is accepted into Keychain; confirm the group staging file is removed.
- [ ] Verify no debug/Mac connection is required for that enrollment or later renewal.
- [ ] Verify an expired/rejected browser session saves nothing and a different account cannot replace the cache without sign-out.
- [ ] Repeat independently on the second tester's provisioned phone, using her explicitly approved own-account sign-in and Dot.

Sources: [Apple's native extension messaging](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension), [Safari extension permissions](https://developer.apple.com/documentation/safariservices/managing-safari-web-extension-permissions), [OpenAI's public scopes](https://developers.openai.com/siwc/quickstart).
