# OpenAI registration and Dot access request

Prepared 2026-10-03. Draft only: no form or message has been submitted. Client ID, Dot authorization scopes, refresh contract, and callback registration have not been granted.

Route: [Sign in with ChatGPT interest form](https://openai.com/form/sign-in-with-chatgpt-interest/), linked from [OpenAI's client registration documentation](https://developers.openai.com/siwc/request-client-id).

## Request text

I am developing an independent native iPhone app with companion Apple Watch and CarPlay interfaces to a user's existing ChatGPT Dot. Each user should authenticate through OpenAI and explicitly authorize access to their own Dot, its current conversation, connected capabilities, voice sessions, and personalized character. I want to support a TestFlight beta followed by an App Store release.

The experience preserves the existing Dot and conversation rather than creating a separate API assistant. Watch voice is intended to connect directly, with setup on iPhone. CarPlay uses the iPhone for networking and audio, with Apple's conversational-app templates. The car interface provides spoken replies, cached authentic character artwork, mute, and end. Authentication and account selection occur on the iPhone.

Please confirm whether you can register a native public OpenID Connect client using authorization code with PKCE S256 and no embedded client secret. Proposed application identifier: `dev.dotwatch.app`. Proposed callback: `dev.dotwatch.app.auth://signin/oauth/callback`, presented through Apple's ASWebAuthenticationSession. These are proposals pending your registration requirements. Identity scopes are `openid profile email`.

Separately, please identify the supported authorization grant and integration contract for:

- Resolving the authenticated user's primary Dot and its current conversation, with explicit account/workspace selection when needed.
- Starting, attaching to, and stopping that Dot's voice session, transporting audio and session events, and keeping continuity with the official ChatGPT iPhone app.
- Reading authentic character artwork and its appearance version, with permission to cache and display it on Watch and CarPlay.
- Preserving existing connected capabilities and approval requirements without broadening their authority.
- Secure renewal, revocation, sign-out, device pairing, and operation after the phone's first unlock.
- Eligibility, quotas, beta distribution, production use, permitted branding, and any required partnership or service authorization.

A private own-account investigation has demonstrated Dot discovery, authentic artwork, and a bounded synthetic voice exchange that the official iPhone Dot recalled. The distribution builds do not import those private diagnostic credentials. I understand that ordinary Sign in with ChatGPT identity and Responses API scopes do not grant access to existing conversations or other account context. I am requesting explicit Dot access rather than relying on those identity tokens for undocumented endpoints.

## Information to supply before submission

- Publisher/legal entity, contact email, website, privacy-policy URL, support URL, and expected beta size.
- Final app name and ownership; the current source remains private pending a decision.
- Source model and distribution plans. Open-sourcing does not by itself confer Dot conversation access.
- Screenshots or a short demo using only authorized test-account content.
- Any OpenAI relationship/contact or pilot reference the owner wishes to include.

Do not attach bearer tokens, signed asset URLs, private conversations, recordings, account IDs, or an unredacted network trace. A sanitized connection specification is available in [CONNECTION.md](CONNECTION.md) if requested through an appropriate channel.

## Success criteria for the response

An identity-only client ID is insufficient. Obtain a documented, explicitly permitted grant for real Dot voice, context, and artwork; verify it with a clean beta account through iPhone sign-in. If OpenAI supports only a confidential client/backend flow, revise the identity architecture before entering any secret into configuration. Do not substitute the open-source CLI loopback client or a desktop client's identity.
