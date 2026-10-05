# Beta and publication

Scope expanded on 2026-10-03: users must sign in with their own OpenAI accounts for TestFlight and eventual App Store distribution. The original personal prototype remains useful for authorized development. Public access is not operational yet.

The next decision prioritizes [a private two-person iteration](PRIVATE-ITERATION.md), with separate cached sign-ins and Dots. Public registration and submission remain later work; they do not block private development. Private/PrivateCarPlay explicitly enable the diagnostic bootstrap and must never be uploaded for public testing.

## Implemented foundation

- Native system authentication through ASWebAuthenticationSession, authorization code, PKCE S256, fresh state/nonce, a ten-minute one-use callback, and exact callback matching.
- OpenAI metadata restricted to its HTTPS identity origin. JWT verification uses the issuer's fresh JWKS, RS256, issuer, audience/authorized party, nonce, signature, expiry, and not-before checks. Token-supplied key URLs and alternate algorithms are rejected.
- Minimal verified identity metadata is stored in a separate device-only Keychain item; raw ID tokens are not persisted or used for Dot access. Expired identity requires a fresh sign-in. This is local identity metadata, not a production Dot grant or a backend app session.
- Beta/Release/CarPlay configurations exclude personal diagnostic credential import/read. They remove any staged transfer and old diagnostic Keychain item during setup. Debug/Private/PersonalCarPlay/PrivateCarPlay enable the private diagnostic bootstrap.
- No embedded client secret, shared developer bearer token, password form, hosted audio relay, or generic assistant fallback.
- Eight security tests pass and the native Beta configuration builds with signing disabled. Live OpenAI login cannot be tested until the client is registered.

The distribution regression check rejects private importer symbols and legacy setup/payload markers; a freshly built private binary serves as a positive control. It also checks that ten dependency notices match their source bytes. This is a bounded packaging check, not a complete security audit. [Initial validation record](fixtures/public-login-validation.json).

## Access dependency

[OpenAI's current registration route](https://developers.openai.com/siwc/request-client-id) is available to selected commercial partners with an interest form. [Identity and eligible plan-usage scopes](https://developers.openai.com/siwc/quickstart) do not grant existing conversation access. The [prepared request](OPENAI-ACCESS-REQUEST.md) asks for native public-client registration and separate Dot voice/context/artwork authorization. No such grant is currently present.

Keep the client ID blank until registration succeeds. Copy `Configuration/OpenAI.example.xcconfig` to the ignored `Configuration/OpenAI.local.xcconfig` and supply the public client ID only. Use this override when building:

```sh
swift test --package-path Packages/DotAuth
xcodegen generate
xcodebuild -project DotWatch.xcodeproj -scheme DotPhone -configuration Beta \
  -xcconfig Configuration/OpenAI.local.xcconfig \
  -destination 'generic/platform=iOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Verify the resulting distribution app before export:

```sh
python3 tools/verify_public_build.py \
  --app DerivedData/Build/Products/Beta-iphoneos/DotPhone.app \
  --personal-app DerivedData/Build/Products/Private-iphoneos/DotPhone.app
```

The proposed callback is `dev.dotwatch.app.auth://signin/oauth/callback`; it is configured locally but not registered with OpenAI. If OpenAI requires a different callback or a confidential client, update the native flow and registration together. Never bundle a client secret. A registered identity-only sign-in will still show that Dot access is pending, with Talk disabled. Implement the confirmed Dot grant and serialized renewal separately before admitting testers.

## TestFlight and App Store gates

1. Obtain supported OpenAI authorization for third-party Dot voice, context, connected capabilities, and authentic character display. Exercise account choice, clean sign-in, expiry/renewal, revocation, sign-out, and account switching on a second user's account.
2. Finish Watch setup, pairing and direct audio; pass physical Watch and vehicle tests in [ACCEPTANCE.md](ACCEPTANCE.md). Obtain Apple's CarPlay entitlement and matching distribution provisioning.
3. Finalize app identity, icon, support/privacy URLs, publisher, age rating, privacy disclosures, licensed character/branding usage, and exact dependency notices. Verify the privacy manifest and required-reason API declarations against the final binary rather than guessing them from the prototype.
4. Describe the app as a client for a specific third-party service requiring that account to access its existing content. This appears to fit Apple's login exception in guideline 4.8; that is an interpretation for App Review to assess, not approval. Reassess if the app adds an independent primary account or unrelated features. An Apple sign-in alone would not grant a user's Dot.
5. Prepare clean reviewer access and truthful instructions covering iPhone setup, Watch use, and CarPlay. Include evidence of permission to access/display OpenAI services when requested under guideline 5.2.2. Explain data sent to OpenAI and obtain the applicable user consent. If a separate app account is later created, implement its deletion as required.
6. Archive with Beta/Release (never Debug), inspect embedded entitlements/profile and credential-import exclusion, validate/export for App Store Connect, then distribute through TestFlight. External beta review precedes an external tester rollout. Submit the completed production build for App Review only after the physical gates pass.

No TestFlight upload, tester invitation, registration form, or public App Store submission has been sent. Pricing and source licensing remain undecided; no paid tier or new plugin has been added.

Apple requirements: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), including beta testing, service access, login exceptions, privacy, and account handling. These requirements and OpenAI availability were checked on 2026-10-03 and should be rechecked before submission.
