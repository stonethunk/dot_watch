#!/usr/bin/env python3
"""Encode an explicit synthetic PCM WAV to 20 ms Opus packets for a transport probe.

Uses the already-pinned diagnostic av dependency. Opens no microphone.
"""
import argparse
import base64
from fractions import Fraction
import json
import os
from pathlib import Path
import av


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-wav", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    private = Path(__file__).resolve().parents[1] / ".private"
    if not args.output.resolve().is_relative_to(private) or args.output.exists():
        raise SystemExit("Choose a fresh output file inside .private/.")
    os.umask(0o077)
    codec = av.CodecContext.create("libopus", "w")
    codec.sample_rate = 48000
    codec.layout = "mono"
    codec.format = "flt"
    codec.bit_rate = 32000
    codec.time_base = Fraction(1, 48000)
    codec.options = {"application": "voip", "frame_duration": "20"}
    codec.open()
    resampler = av.AudioResampler(format="flt", layout="mono", rate=48000)
    packets = []
    samples = 0
    with av.open(str(args.input_wav)) as source:
        for frame in source.decode(audio=0):
            for converted in resampler.resample(frame):
                samples += converted.samples
                if samples > 30 * 48000:
                    raise SystemExit("Synthetic input must be at most 30 seconds.")
                packets.extend(codec.encode(converted))
        for converted in resampler.resample(None):
            packets.extend(codec.encode(converted))
        packets.extend(codec.encode(None))
    encoded = [base64.b64encode(bytes(packet)).decode("ascii") for packet in packets]
    with args.output.open("x") as output:
        json.dump(encoded, output)
    print(json.dumps({"opus_packets": len(packets), "microphone_opened": False}))


if __name__ == "__main__":
    main()
