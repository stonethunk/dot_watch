#!/usr/bin/env python3
"""Distribution regression checks; no credentials, network, or device access.

This supplements the compile-time gates, not a full secret/security audit.
Run against the exact app being archived/exported. A Debug app is an optional
positive control so a mistaken binary path cannot make the checks vacuous.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess


def decoded_symbols(path: Path) -> bytes:
    result = subprocess.run(["nm", "-j", str(path)], capture_output=True, check=True)
    # Swift can substitute module-name fragments into type names. Compare actual
    # demangled types, not incidental substrings in their mangled spellings.
    return subprocess.run(["xcrun", "swift-demangle", "--compact"], input=result.stdout,
                          capture_output=True, check=True).stdout


def binary_checks(app: Path) -> dict:
    binary_paths = [p for p in app.iterdir() if p.is_file()
                    and (p.name.startswith("DotPhone") or p.name.endswith(".dylib"))]
    assert binary_paths, "No application binary found"
    binaries = [p.read_bytes() for p in binary_paths]
    symbols = []
    for path in binary_paths:
        symbols.append(decoded_symbols(path))
    with (app / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    return {
        "personal_setup_present": any(b"Connect to your Mac to finish this diagnostic" in b for b in binaries),
        "personal_token_payload_keys_present": any(b"access_token" in b and b"account_id" in b for b in binaries),
        "private_import_parser_present": any(b"PrivateCredentialTransfer" in s for s in symbols),
        "openai_client_configured": bool(info.get("DotOpenAIClientID")),
        "callback_scheme_present": any("dev.dotwatch.app.auth" in v.get("CFBundleURLSchemes", [])
                                       for v in info.get("CFBundleURLTypes", [])),
        "private_browser_setup_enabled": info.get("DotPrivateBrowserSetup") is True,
        "private_safari_extension_present": (app / "PlugIns/DotPrivateSignIn.appex").is_dir(),
        "app_icon_present": bool(info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName")),
        "remote_watch_media_present": any(b"RemoteWatchMedia" in s for s in symbols),
        "private_watch_credential_sync_present": any(b"PrivateWatchEnvelope" in s for s in symbols),
    }


def companion_checks(app: Path, *, audio_probe: bool = False) -> dict:
    watch = app / "Watch/DotWatch.app"
    complication = watch / "PlugIns/DotComplication.appex"
    assert watch.is_dir() and complication.is_dir(), "Embedded Watch app or complication missing"
    for bundle in (watch, complication):
        with (bundle / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
        binary = bundle / info["CFBundleExecutable"]
        symbols = decoded_symbols(binary)
        assert b"PrivateCredentialTransfer" not in symbols, "Private importer linked into Watch app"
        expected_probe = audio_probe and bundle == watch
        assert (b"ChatGPTCredentials" in symbols) == expected_probe, "Watch credential code does not match private configuration"
        assert (b"PrivateWatchEnvelope" in symbols) == expected_probe, "Watch credential sync does not match private configuration"
        has_probe = b"WatchAudioDiagnostic" in symbols
        assert has_probe == expected_probe, "Private Watch audio test boundary does not match configuration"
        assert ("NSMicrophoneUsageDescription" in info) == expected_probe, "Unexpected Watch microphone permission declaration"
        assert (info.get("DotWatchAudioProbe") is True) == expected_probe, "Unexpected Watch audio test configuration"
        assert (b"WatchVoiceController" in symbols) == expected_probe, "Unexpected Watch voice implementation"
        assert (info.get("DotPrivateWatchVoice") is True) == expected_probe, "Unexpected Watch voice configuration"
        if expected_probe:
            assert "audio" in info.get("UIBackgroundModes", []), "Audio test background mode missing"
            notices = Path(__file__).resolve().parents[1] / "Apps/Watch/Notices"
            for original in notices.iterdir():
                packaged = watch / original.name
                assert packaged.is_file(), f"Missing Watch dependency source notice: {original.name}"
                assert hashlib.sha256(original.read_bytes()).digest() == hashlib.sha256(packaged.read_bytes()).digest(), f"Altered Watch notice: {original.name}"
    with (watch / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    assert info.get("WKCompanionAppBundleIdentifier") == "dev.dotwatch.app"
    assert info.get("WKApplication") is True
    assert info.get("WKRunsIndependentlyOfCompanionApp") == audio_probe
    return {"embedded_watch_app": True, "embedded_complication": True,
            "watch_credential_code_present": audio_probe, "watch_microphone_requested": audio_probe,
            "watch_private_audio_probe_present": audio_probe, "watch_private_voice_present": audio_probe}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--personal-app", type=Path)
    arguments = parser.parse_args()
    public = binary_checks(arguments.app)
    assert not public["personal_setup_present"], "Personal setup code found in distribution build"
    assert not public["personal_token_payload_keys_present"], "Personal token importer found in distribution build"
    assert not public["private_import_parser_present"], "Private importer symbols found in distribution build"
    assert not public["remote_watch_media_present"], "Private Watch session adapter found in public build"
    assert not public["private_watch_credential_sync_present"], "Private Watch bearer sync found in public build"
    assert public["callback_scheme_present"], "Native sign-in callback scheme is missing"
    assert not public["private_browser_setup_enabled"], "Private browser setup enabled in public build"
    assert not public["private_safari_extension_present"], "Private Safari extension embedded in public build"
    assert public["app_icon_present"], "App icon missing"
    notices = Path(__file__).resolve().parents[1] / "Apps/Phone/Notices/OpenAI-SignIn"
    for original in notices.iterdir():
        packaged = arguments.app / original.name
        assert packaged.is_file(), f"Missing notice: {original.name}"
        assert hashlib.sha256(original.read_bytes()).digest() == hashlib.sha256(packaged.read_bytes()).digest(), f"Altered notice: {original.name}"
    public["dependency_notices_verified"] = len(list(notices.iterdir()))
    report = {"public": public}
    report["public_companion"] = companion_checks(arguments.app)
    if arguments.personal_app:
        personal = binary_checks(arguments.personal_app)
        assert personal["personal_setup_present"] and personal["private_import_parser_present"], "Personal positive control did not contain bootstrap code"
        assert personal["private_browser_setup_enabled"] and personal["private_safari_extension_present"], "Private browser setup missing from personal app"
        assert personal["app_icon_present"], "Private app icon missing"
        assert personal["remote_watch_media_present"], "Private Watch session adapter missing"
        assert personal["private_watch_credential_sync_present"], "Private Watch bearer sync missing"
        safari = arguments.personal_app / "PlugIns/DotPrivateSignIn.appex"
        resources = Path(__file__).resolve().parents[1] / "Apps/PrivateSafari/Resources"
        for original in resources.iterdir():
            packaged = safari / original.name
            assert packaged.is_file() and packaged.stat().st_size > 0, f"Missing Safari resource: {original.name}"
            # Xcode's CopyPNGFile can rewrite PNG encoding even with compression
            # disabled. Enforce exact bytes for executable scripts/markup/config;
            # the generated source icon is retained and the SDK packages the PNG.
            if original.suffix != ".png":
                assert hashlib.sha256(original.read_bytes()).digest() == hashlib.sha256(packaged.read_bytes()).digest(), f"Altered Safari resource: {original.name}"
        personal["private_browser_resources_verified"] = len(list(resources.iterdir()))
        report["personal_positive_control"] = personal
        report["personal_companion"] = companion_checks(arguments.personal_app, audio_probe=True)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
