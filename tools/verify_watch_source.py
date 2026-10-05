#!/usr/bin/env python3
"""Verify the pinned upstream Watch transport source snapshot without networking."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1] / "Probes/DirectWatch/Vendor/WatchWebRTC"
manifest = json.loads((root / "upstream-source.json").read_text())
expected = manifest["files"]
actual = {str(path.relative_to(root)) for path in (root / "Sources").rglob("*") if path.is_file()}
assert actual == {name for name in expected if name.startswith("Sources/")}, "Upstream source file set changed"
for name, digest in expected.items():
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest, f"Altered upstream source: {name}"
print(json.dumps({"upstream_revision": manifest["revision"], "verified_files": len(expected),
                  "protocol_sources_modified": False, "module": "WatchWebRTC"}, indent=2))
