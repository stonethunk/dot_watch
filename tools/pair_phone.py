#!/usr/bin/env python3
"""One-time diagnostic sign-in transfer to our own app on a trusted Apple device.

No token in command arguments or output; no refresh token is copied. The staging
file is mode 0600 and deleted on exit. The app consumes and deletes its copy on
launch, retaining only a device-local Keychain item.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex-auth-file", required=True, type=Path)
    parser.add_argument("--device", required=True)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.codex_auth_file.stat().st_size > 128 * 1024:
            raise ValueError("credentials")
        tokens = json.loads(args.codex_auth_file.read_bytes())["tokens"]
        token, account = tokens["access_token"], tokens["account_id"]
        if not isinstance(token, str) or not isinstance(account, str) or not token or not account:
            raise ValueError("credentials")
        private = Path(__file__).resolve().parents[1] / ".private"
        private.mkdir(mode=0o700, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="phone-pairing-", dir=private) as directory:
            staging = Path(directory) / "paired-session.json"
            with staging.open("x") as file:
                json.dump({"access_token": token, "account_id": account}, file)
            result = subprocess.run([
                "xcrun", "devicectl", "device", "copy", "to", "--device", args.device,
                "--source", str(staging), "--destination", "Documents/paired-session.json",
                "--domain-type", "appDataContainer", "--domain-identifier", "dev.dotwatch.app",
                "--timeout", "30", "--quiet",
            ], capture_output=True, check=False)
            if result.returncode:
                print("Pairing transfer failed. Unlock the phone and confirm Dot is installed.")
                return 1
        print("Private sign-in transferred. Launch Dot to import it into Keychain and erase the staging file.")
        return 0
    except (OSError, ValueError, KeyError, TypeError):
        print("Pairing could not read a valid existing sign-in. No credentials were printed.")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
