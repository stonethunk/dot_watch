#!/usr/bin/env python3
"""Bounded, headless investigation of the installed client's Dot voice protocol.

Never opens a microphone. Optional speech must be an explicit local PCM16 WAV.
Does not implement the shipping iPhone/Watch transport or bypass approvals.
"""
import argparse
import asyncio
import contextlib
import fractions
import json
import logging
import os
from pathlib import Path
import re
import sys
import time
import wave
from urllib.parse import quote

import aiohttp
import av
from aiortc import AudioStreamTrack, RTCConfiguration, RTCPeerConnection, RTCSessionDescription

API = "https://chatgpt.com/backend-api"
CLOUD = "https://codex-cloud-backend.chatgpt.com"
PRIVATE = Path(__file__).resolve().parent.parent / ".private"


class ProbeError(Exception):
    """Only constant, redacted messages may be used here."""


def error_facts(error):
    if not isinstance(error, dict):
        error = {"message": str(error)}
    message = str(error.get("message", "")).lower()
    words = ["cloud", "realtime", "client", "created", "call", "websocket", "webrtc", "transport", "version", "unsupported", "requires", "required", "invalid", "disabled", "experimental", "active", "already", "thread", "voice", "audio", "session", "not found", "missing", "field", "prompt", "type", "variant", "method", "params", "unknown", "auth", "permission", "denied", "subscription", "model", "init", "request", "json", "response", "available", "enabled", "supported", "not", "allow", "feature", "instructions", "empty", "api", "key", "handoff", "bidi", "timeout", "error", "failed", "connect", "timed", "closed", "maximum"]
    code = error.get("code")
    return {"message_length": len(message), "keywords": [word for word in words if word in message],
            "code": code if isinstance(code, int) or isinstance(code, str) and re.fullmatch(r"[a-z_]{1,80}", code) else "unknown"}


def private_output(path):
    result = Path(path).resolve()
    if not result.is_relative_to(PRIVATE.resolve()):
        raise ProbeError("output_must_be_in_project_private_directory")
    if result.exists():
        raise ProbeError("output_already_exists")
    return result


def load_audio(path):
    if path is None:
        return b""
    with wave.open(path, "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate(), source.getcomptype()) != (1, 2, 24000, "NONE"):
            raise ProbeError("input_requires_mono_pcm16_24khz_wav")
        if source.getnframes() > 24000 * 30:
            raise ProbeError("input_is_longer_than_30_seconds")
        return source.readframes(source.getnframes())


class FileOrSilenceTrack(AudioStreamTrack):
    def __init__(self, samples, ready):
        super().__init__()
        self.samples = samples
        self.ready = ready
        self.offset = 0
        self.timestamp = 0
        self.started_at = None

    async def recv(self):
        if self.started_at is None:
            self.started_at = time.monotonic()
        await asyncio.sleep(max(0, self.started_at + self.timestamp / 24000 - time.monotonic()))
        data = bytes(960)
        if self.ready.is_set() and self.offset < len(self.samples):
            data = self.samples[self.offset:self.offset + 960].ljust(960, b"\0")
            self.offset += 960
        frame = av.AudioFrame(format="s16", layout="mono", samples=480)
        frame.planes[0].update(data)
        frame.sample_rate = 24000
        frame.pts = self.timestamp
        frame.time_base = fractions.Fraction(1, 24000)
        self.timestamp += 480
        return frame


async def run(args):
    os.umask(0o077)
    output = private_output(args.output_wav) if args.output_wav else None
    report_path = private_output(args.report) if args.report else None
    samples = load_audio(args.input_wav)
    auth = json.loads(Path(args.codex_auth_file).expanduser().read_text())["tokens"]
    headers = {"Authorization": "Bearer " + auth["access_token"],
               "ChatGPT-Account-Id": auth["account_id"],
               "X-OpenAI-Product-Sku": "codex", "User-Agent": "DotWatchDiagnostic/0.1"}
    timeout = aiohttp.ClientTimeout(total=30)
    report = {"schema_version": 1, "date_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "microphone_opened": False, "input_audio_supplied": bool(samples), "gate_passed": False}
    ready = asyncio.Event()
    connected = asyncio.Event()
    channel_open = asyncio.Event()
    failed = asyncio.Event()
    ended = asyncio.Event()
    event_counts = {}
    received_audio = bytearray()
    receiver_tasks = []
    pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
    track = FileOrSilenceTrack(samples, ready)
    pc.addTrack(track)
    channel = pc.createDataChannel("oai-events")
    voice_owned = False
    thread_id = None
    call_id = None
    call_base = None

    def count(name):
        if len(event_counts) < 60 and isinstance(name, str) and re.fullmatch(r"[a-zA-Z/_.]{1,80}", name):
            event_counts[name] = event_counts.get(name, 0) + 1

    @pc.on("connectionstatechange")
    async def connection_changed():
        if pc.connectionState == "connected":
            connected.set()
        elif pc.connectionState == "failed":
            failed.set()

    @channel.on("open")
    def opened():
        channel_open.set()

    @channel.on("message")
    def channel_message(message):
        try:
            event = json.loads(message)
            count(event.get("type"))
            if args.input_wav and "marigold" in str(event).lower():
                report["synthetic_test_marker_in_voice_events"] = True
            if event.get("type") == "error":
                report["data_channel_error"] = error_facts(event.get("error", {}))
                failed.set()
        except (ValueError, TypeError):
            report["invalid_data_channel_message"] = True

    @pc.on("track")
    def remote_track(remote):
        if remote.kind != "audio":
            failed.set()
            return

        async def consume():
            resampler = av.AudioResampler(format="s16", layout="mono", rate=24000)
            try:
                while True:
                    frame = await remote.recv()
                    for converted in resampler.resample(frame):
                        chunk = bytes(converted.planes[0])[:converted.samples * 2]
                        if len(received_audio) + len(chunk) > 8 * 1024 * 1024:
                            failed.set()
                            return
                        received_audio.extend(chunk)
            except Exception:
                if not ended.is_set():
                    report["remote_audio_ended"] = True
        receiver_tasks.append(asyncio.create_task(consume(), name="dot-probe-audio-receiver"))

    session = aiohttp.ClientSession(timeout=timeout, cookie_jar=aiohttp.DummyCookieJar())
    try:
        async with session.get(API + "/tbo/primary", headers=headers, allow_redirects=False) as response:
            if response.status != 200:
                print("discovery_http_status:", response.status, flush=True)
                raise ProbeError("discovery_failed")
            primary = await response.json()
        selection, profile = primary["selection"], primary["profile"]
        thread_id = selection["thread_id"]
        if selection.get("available") is not True or selection["aeon_id"] != profile["id"] or thread_id != profile["active_root_thread_id"]:
            raise ProbeError("identity_mismatch")
        report["dot_identity_verified"] = True
        dot_id = selection["aeon_id"]
        call_base = API + "/tbo/" + quote(dot_id, safe="") + "/voice/calls"
        async with session.get(CLOUD + "/v1/threads/" + quote(thread_id, safe=""), headers=headers, allow_redirects=False) as response:
            if response.status != 200 or (await response.json()).get("thread", {}).get("id") != thread_id:
                raise ProbeError("conversation_mismatch")
        report["existing_conversation_verified"] = True
        report["voice_route"] = "dot_voice_calls"
        print("dot_and_conversation: verified", flush=True)
        await pc.setLocalDescription(await pc.createOffer())
        async with session.post(call_base, headers=headers,
                                json={"sdp": pc.localDescription.sdp}, allow_redirects=False) as response:
            report["call_create_http_status"] = response.status
            print("call_create_http_status:", response.status, flush=True)
            if response.status not in (200, 201):
                raise ProbeError("dot_call_create_failed")
            answer = await response.text()
            call_id = response.headers.get("Location", "").split("?")[0].split("/")[-1]
            if not re.fullmatch(r"rtc_[A-Za-z0-9_-]+", call_id):
                raise ProbeError("invalid_call_identity")
            voice_owned = True
        await pc.setRemoteDescription(RTCSessionDescription(sdp=answer, type="answer"))
        async with session.post(call_base + "/" + call_id + "/attach", headers=headers, allow_redirects=False) as response:
            report["attach_http_status"] = response.status
            if response.status not in (200, 204):
                raise ProbeError("dot_call_attach_failed")
        await asyncio.wait_for(asyncio.gather(connected.wait(), channel_open.wait()), 20)
        if failed.is_set():
            raise ProbeError("voice_start_failed")
        report["realtime_started"] = True
        report["webrtc_connected"] = True
        print("existing_dot_voice: connected", flush=True)
        ready.set()
        seconds = min(60, max(args.seconds, len(samples) / 48000 + 15 if samples else 2))
        for _ in range(int(seconds * 10)):
            if failed.is_set() or ended.is_set():
                break
            await asyncio.sleep(0.1)
        ready.clear()
        async with session.post(call_base + "/" + call_id + "/stop", headers=headers, allow_redirects=False) as response:
            report["stop_http_status"] = response.status
            if response.status not in (200, 204):
                raise ProbeError("dot_call_stop_failed")
        voice_owned = False
        report["stop_acknowledged"] = True
        ended.set()
        if samples:
            # Inspect only a bounded recent page and retain a boolean, never conversation content.
            for _ in range(5):
                async with session.get(CLOUD + "/v2/threads/" + quote(thread_id, safe="") + "/turns",
                                       params={"limit": "5", "sortDirection": "desc", "itemsView": "full"},
                                       headers=headers, allow_redirects=False) as response:
                    if response.status != 200:
                        report["continuity_read_http_status"] = response.status
                        break
                    recent = await response.json()
                    found = "marigold" in json.dumps(recent).lower()
                    report["synthetic_test_marker_in_existing_conversation"] = found
                    if found:
                        break
                await asyncio.sleep(1)
        if failed.is_set():
            raise ProbeError("voice_reported_error_or_unsupported_interaction")
    finally:
        ready.clear()
        # The session is bounded even on cancellation. We never use this to stop an unrelated call.
        if voice_owned and call_id is not None:
            try:
                async with session.post(call_base + "/" + call_id + "/stop", headers=headers, allow_redirects=False) as response:
                    report["cleanup_stop_acknowledged"] = response.status in (200, 204)
            except Exception:
                report["cleanup_stop_acknowledged"] = False
        track.stop()
        await pc.close()
        for receiver in receiver_tasks:
            receiver.cancel()
        await asyncio.gather(*receiver_tasks, return_exceptions=True)
        await session.close()
        report["event_counts"] = event_counts
        report["received_audio_bytes"] = len(received_audio)
        report["sent_audio_bytes"] = min(track.offset, len(samples))
        report["gate_note"] = "Transport diagnostics only; human speech, iPhone continuity, Watch and vehicle tests remain required."
        if output is not None and received_audio:
            output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            with output.open("xb") as file:
                with wave.open(file, "wb") as wav:
                    wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(24000)
                    wav.writeframes(received_audio)
        if report_path is not None:
            report_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            with report_path.open("x") as file:
                json.dump(report, file, indent=2)
                file.write("\n")
        print(json.dumps(report, indent=2), flush=True)


def main():
    logging.disable(logging.CRITICAL)  # Dependencies must never log SDP, audio, or bearer handshakes.
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex-auth-file", required=True)
    parser.add_argument("--input-wav")
    parser.add_argument("--output-wav")
    parser.add_argument("--report")
    parser.add_argument("--seconds", type=int, default=5, choices=range(1, 61), metavar="1..60")
    args = parser.parse_args()
    try:
        asyncio.run(run(args))
    except ProbeError as error:
        print("probe_error:", str(error), file=sys.stderr)
        return 1
    except (Exception, KeyboardInterrupt):
        # Never print raw HTTP/WebRTC exceptions, which can include secrets or private SDP.
        print("probe_error: diagnostic_failed_private_details_suppressed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
