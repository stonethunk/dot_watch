#!/usr/bin/env python3
"""Fetch immutable external Watch sources and verify every byte before use.

The public repository includes our native manifest and upstream SHA-256 index,
not a redistribution of the upstream implementation or README files.
Existing mismatched files are never overwritten.
"""
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "Probes/DirectWatch/Vendor/WatchWebRTC"
REPOSITORIES = {
    "swift-log": "apple/swift-log",
    "swift-networking": "1amageek/swift-networking",
    "swift-ssl": "1amageek/swift-ssl",
    "swift-tls": "1amageek/swift-tls",
    "swift-webrtc": "1amageek/swift-webrtc",
}


def download(url: str, limit: int) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "dot-watch-source-preparation"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Upstream response exceeds the bounded download size")
    return data


def verified_write(path: Path, data: bytes, expected: str) -> None:
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f"Upstream hash mismatch: {path.name}")
    if not path.resolve().is_relative_to(ROOT):
        raise ValueError("Source destination escapes this checkout")
    if path.exists():
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f"Existing local file differs; review it before replacing: {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".download")
    temporary.write_bytes(data)
    temporary.replace(path)


def main() -> None:
    manifest = json.loads((VENDOR / "upstream-source.json").read_text())
    expected = manifest["files"]
    missing = []
    for name, digest in expected.items():
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Invalid source manifest path")
        path = VENDOR / name
        if path.exists():
            verified_write(path, path.read_bytes(), digest)
        else:
            missing.append(name)
    if missing:
        revision = manifest["revision"]
        archive = download(f"https://codeload.github.com/1amageek/swift-webrtc/tar.gz/{revision}", 16 * 1024 * 1024)
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as source:
            members = {str(PurePosixPath(m.name).relative_to(PurePosixPath(m.name).parts[0])): m
                       for m in source.getmembers() if m.isfile()}
            sources = {name for name in members if name.startswith("Sources/WebRTC/")}
            if sources != {name for name in expected if name.startswith("Sources/")}:
                raise ValueError("Pinned upstream source file set differs from our index")
            for name in missing:
                upstream = {"UPSTREAM-Package.swift.txt": "Package.swift", "UPSTREAM-README.md": "README.md"}.get(name, name)
                member = members[upstream]
                if member.size > 2 * 1024 * 1024:
                    raise ValueError("Upstream source member exceeds size bound")
                data = source.extractfile(member).read()
                verified_write(VENDOR / name, data, expected[name])
    notices = ROOT / "Apps/Watch/Notices"
    provenance = json.loads((notices / "dependency-provenance.json").read_text())
    for item in provenance["files"]:
        target = notices / item["packaged_file"]
        if target.exists():
            verified_write(target, target.read_bytes(), item["sha256"])
            continue
        repository = REPOSITORIES[item["package"]]
        data = download(f"https://raw.githubusercontent.com/{repository}/{item['revision']}/{item['source_file']}", 2 * 1024 * 1024)
        verified_write(target, data, item["sha256"])
    print(json.dumps({"upstream_revision": manifest["revision"], "verified_source_files": len(expected),
                      "verified_notice_files": len(provenance["files"]), "credentials_used": False}, indent=2))


if __name__ == "__main__":
    main()
