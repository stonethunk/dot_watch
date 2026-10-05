# Authentication and renewal

## Diagnostic bootstrap that worked

The probes read `tokens.access_token` and `tokens.account_id` from an explicitly selected local Codex auth file. They do not copy credentials into the repository, save cookies, print token claims containing identity, or persist the refresh token. Existing credentials successfully accessed Dot discovery, artwork metadata, and the Dot-specific voice endpoints.

If discovery returns 401, renew authentication through the existing Codex/OpenAI sign-in flow, then rerun the probe. For a machine without an interactive browser, Codex supports `codex login --device-auth`; complete the displayed approval only on OpenAI's sign-in page. The probe does not rotate refresh tokens or race the official client's credential store. Do not paste tokens into chat or command-line arguments.

This is an investigation procedure, not the finished phone sign-in experience. Do not distribute a copy of desktop credentials in an app bundle.

## Public sign-in foundation and remaining authorization

`Packages/DotAuth` implements identity-only OpenID Connect with authorization code/PKCE and issuer-key signature verification. The phone presents OpenAI through ASWebAuthenticationSession and keeps verified identity metadata in a separate device-only Keychain item. The proposed callback and public client are not registered yet. The UI uses **Continue with ChatGPT**, stays disabled without a registered client ID, and never converts an ID token into a Dot credential. See [beta/publication](BETA-PUBLICATION.md) and the [prepared access request](OPENAI-ACCESS-REQUEST.md).

Beta/Release/CarPlay exclude private transfer and credential read; Debug/Private/PersonalCarPlay/PrivateCarPlay enable it. The private importer is outside the shared package product and compiled only into private phone builds. A public upgrade removes a staged transfer and the old diagnostic Keychain item. Users must authorize their own supported Dot grant once OpenAI supplies that contract. For the current two-person iteration, see [private setup](PRIVATE-ITERATION.md).

Private build 4 adds encrypted Watch provisioning and a separate device-only Keychain credential on the Watch. Its public/private dependency graphs are distinct. The phone durably delegates voice permission before delivery; phone/CarPlay must obtain acknowledged Watch release and token revocation before starting. Active Watch voice has no phone heartbeat. The private setup key, token and minimal stop journal are never source assets or plaintext transfer files. Enrollment, renewal, locked/absent-phone operation and offline sign-out still need physical acceptance. [Watch security and lifecycle](WATCH-STANDALONE.md).

Remaining authorization and physical lifecycle acceptance:

- Validate an authorized OpenAI sign-in flow that can be completed on iPhone and actually grants Dot access. Do not assume ordinary Sign in with ChatGPT application scopes include private conversations.
- Persist credentials in Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (or an explicitly justified equivalent) for locked-phone voice after first unlock.
- Serialize refresh, handle token rotation, and invalidate account-bound state on account changes. Never silently choose a different account.
- Transfer only the minimum credentials required by the selected Watch transport through an authenticated pairing flow. WatchConnectivity is not assumed to carry continuous audio.
- Sign-out must close media/network sessions, revoke local ownership, delete Keychain items, clear pairing and remove all account-specific character caches.
- Logs may contain safe error categories/statuses and performance counters only. Diagnostic recordings must remain explicit opt-in private artifacts.

The personal prototype implements after-first-unlock device-only Keychain storage, deletion on sign-out, and one-time trusted-device import through `tools/pair_phone.py`. A signed build is installed and the explicitly approved transfer to the test iPhone succeeded. The staging file is erased by the app after import; physical import/cleanup and microphone operation still require verification. This bootstrap copies no refresh token. Real Dot OAuth/refresh remains unavailable pending an approved grant. See [setup](SETUP.md).

Sources: [Codex authentication](https://developers.openai.com/codex/auth/), [Sign in with ChatGPT quickstart](https://developers.openai.com/siwc/quickstart).
