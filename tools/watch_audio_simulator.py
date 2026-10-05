#!/usr/bin/env python3
"""Run the Private Watch app's synthetic callback/codec check headlessly."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import time


BUNDLE_ID = "dev.dotwatch.app.watch"


def simctl(*args, check=True):
    return subprocess.run(
        ["xcrun", "simctl", *args], check=check, capture_output=True,
        text=True, timeout=60,
    )


def run(device_id, app):
    with (app / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleIdentifier") != BUNDLE_ID or "WatchSimulator" not in info.get("CFBundleSupportedPlatforms", []):
        raise ValueError("Expected the Dot Watch simulator app")
    if info.get("DotWatchAudioProbe") is not True:
        raise ValueError("The synthetic check requires the Private configuration")
    inventory = json.loads(simctl("list", "devices", "available", "--json").stdout)
    candidates = [device for runtime, devices in inventory["devices"].items()
                  if "watchOS" in runtime for device in devices if device["udid"] == device_id]
    if len(candidates) != 1:
        raise ValueError("Select an available watchOS simulator UUID")
    booted_here = candidates[0]["state"] == "Shutdown"
    if not booted_here and candidates[0]["state"] != "Booted":
        raise ValueError("The selected simulator is transitioning; retry when ready")
    try:
        if booted_here:
            simctl("boot", device_id)
        simctl("bootstatus", device_id, "-b")
        simctl("install", device_id, str(app))
        container = Path(simctl("get_app_container", device_id, BUNDLE_ID, "data").stdout.strip())
        report_path = container / "Documents" / "simulator-audio-check.json"
        # A previous run or already-open app cannot satisfy this run.
        simctl("terminate", device_id, BUNDLE_ID, check=False)
        report_path.unlink(missing_ok=True)
        simctl("launch", device_id, BUNDLE_ID, "--simulate-audio-check")
        deadline = time.monotonic() + 30
        while not report_path.is_file():
            if time.monotonic() >= deadline:
                raise TimeoutError("Watch simulator did not finish its audio check")
            time.sleep(0.25)
        report = json.loads(report_path.read_text())
        required = {"schema": 1, "mode": "synthetic_simulator", "passed": True,
                    "background_callback_completed": True, "captured_frames": 48_000,
                    "microphone_opened": False, "playback_opened": False,
                    "network_opened": False, "credentials_used": False, "signal_present": True}
        if any(report.get(key) != value for key, value in required.items()):
            raise ValueError("Watch simulator callback/audio check failed")
        if report.get("encoded_packets", 0) < 49 or report.get("decoded_frames", 0) < 47_000:
            raise ValueError("Watch simulator codec output was incomplete")
        return report
    finally:
        if booted_here:
            simctl("shutdown", device_id)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Available Watch simulator UUID")
    parser.add_argument("--app", required=True, type=Path, help="Built Private-watchsimulator/DotWatch.app")
    args = parser.parse_args()
    try:
        print(json.dumps(run(args.device, args.app.resolve()), indent=2, sort_keys=True))
    except (OSError, ValueError, TimeoutError, subprocess.SubprocessError) as error:
        print(f"Watch simulator check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
