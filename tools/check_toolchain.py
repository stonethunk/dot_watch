#!/usr/bin/env python3
"""Read-only platform preflight. Does not install tools, profiles or simulator runtimes."""
import json
import re
import shutil
import subprocess
import sys


def main():
    if not shutil.which("xcodebuild"):
        print("Xcode is not installed.")
        return 1
    result = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True)
    match = re.search(r"Xcode (\d+)\.(\d+)", result.stdout)
    if result.returncode or not match:
        print("Xcode version could not be read.")
        return 1
    version = tuple(map(int, match.groups()))
    carplay = version >= (26, 4)
    print(json.dumps({"xcode": ".".join(map(str, version)), "carplay_sdk_minimum_met": carplay,
                      "connected_phone_recommendation": "Xcode 27.0 or newer stable for iOS 27.0.1"}, indent=2))
    return 0 if carplay else 1


if __name__ == "__main__":
    sys.exit(main())
