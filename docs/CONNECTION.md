# Experimental Dot connection specification

Observed from ChatGPT desktop 26.928.21956 and verified against the user's own authorized account on 2026-10-03. These are undocumented interfaces and may change. Do not present them as a supported public OpenAI API.

## Identity and artwork

`GET https://chatgpt.com/backend-api/tbo/primary` returns `selection` and `profile`.

The adapter requires `selection.available`, matching `selection.aeon_id == profile.id`, and matching `selection.thread_id == profile.active_root_thread_id`. IDs are restricted to safe path characters. Account authorization comes from the signed-in token and `ChatGPT-Account-Id`.

The observed profile uses `avatar_type = rendered-interactive`. `avatar_url` is a signed OpenAI asset URL. `avatar_manifest.snapshot` supplies dimensions, `content_sha256`, `manifest_sha256`, and a source hash. Fetch the asset without the ChatGPT Authorization header, reject redirects, and verify the downloaded bytes. The native prototype persists the hash-verified image with account/Dot scope and `manifest_sha256` appearance metadata. Watch synchronization remains unimplemented, and physical customization-refresh validation is pending.

`GET https://codex-cloud-backend.chatgpt.com/v1/threads/{threadId}` verifies conversation identity. The native read-only RPC diagnostic can also initialize `wss://codex-cloud-backend.chatgpt.com/` and call `thread/read`. It uses the installed client's observed WebSocket subprotocol names. This RPC channel is not Dot's media transport.

## Verified voice flow

1. Create a WebRTC peer with one audio track and a data channel named `oai-events`. Keep input gated. Generate an SDP offer.
2. `POST /backend-api/tbo/{dotId}/voice/calls`, JSON body `{"sdp":"…"}`. No model, personality, initial messages, debug prompts or tool overrides are supplied. The server configures the actual Dot.
3. Require HTTP 200/201, a valid answer SDP, and a `Location` header containing a validated `rtc_…` identifier. Do not follow the Location URL; rebuild subsequent paths against the fixed API origin.
4. Apply the answer SDP locally.
5. `POST /backend-api/tbo/{dotId}/voice/calls/{callId}/attach`. The observed response was HTTP 200.
6. Require successful WebRTC connection and data channel open before releasing input.
7. Receive spoken audio over the WebRTC media track. Observed data-channel types: `session.started`, `session.context.appended`, `input_transcript.added`, `output_transcript.added`, `turn.created`, `turn.delta`, `turn.done`, `session.usage.updated`.
8. Gate input immediately on end/failure, stop local media, and `POST /backend-api/tbo/{dotId}/voice/calls/{callId}/stop`. The observed response was HTTP 200. Dispose the peer, tracks, buffers and network session in cleanup. A failed remote stop must retain ownership and block a replacement session until reconciled.

The HTTP adapter is in `Sources/DotCore/DotVoiceAPI.swift`. It retains ownership after attach/stop errors, rejects a second allocation, and marks an ambiguous allocation as needing reconciliation. The headless end-to-end probe is `tools/probe_webrtc.py`. Its audio source is a bounded file or silence; this does not verify microphone quality, latency, background execution or battery use.

The exact fields inside transcript/turn payloads, replay/deduplication semantics, resumption, interruption commands and unsupported approvals still need verification. `DotVoiceEvent` retains recognized envelopes without interpreting unknown events as commands. Nothing auto-approves tool requests. The probe does not send data-channel control messages.

## Request hygiene

The verified diagnostic format uses `Authorization: Bearer …`, `ChatGPT-Account-Id`, `X-OpenAI-Product-Sku: codex`, and `User-Agent: DotWatchDiagnostic/0.1`. These are isolated investigation details, not a promise of third-party support. Tokens never go to the artwork CDN. Disable persistent cookies/cache and redirects. Never log raw HTTP errors, RPC responses, SDP, transcripts, voice recordings, account IDs or token-bearing WebSocket headers.

## Findings that must not be confused with the successful route

The generic `thread/realtime/start` WebSocket audio attempt was rejected with `cloud realtime requires a client-created call`. A separate `/wham/realtime/calls` connection returned a media `forbidden` error. Those are Codex voice paths, **not the working Dot route**. Their failures do not show that this account lacks Dot voice: the user confirmed official iPhone voice, and the Dot-specific endpoint subsequently succeeded with the same login.

The installed app's bundled CLI is 0.159.2; the standalone CLI is 0.147.0. Their schemas differ. Generated schemas and static client code are leads; only live results establish compatibility.
