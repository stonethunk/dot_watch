#!/usr/bin/env python3
"""Read selected static client code from the installed app, without extracting it.

Research helper only. Does not read account state or distribute app source.
"""
import argparse
import json
import struct
from pathlib import Path


class Asar:
    def __init__(self, path):
        self.path = Path(path)
        with self.path.open("rb") as stream:
            _, header_size, _, json_size = struct.unpack("<4I", stream.read(16))
            self.header = json.loads(stream.read(json_size))
        self.base = 8 + header_size

    def entries(self, node=None, prefix=""):
        for name, entry in (node or self.header).get("files", {}).items():
            path = prefix + name
            if "files" in entry:
                yield from self.entries(entry, path + "/")
            else:
                yield path, entry

    def read(self, entry):
        if "offset" not in entry:
            return ""
        with self.path.open("rb") as stream:
            stream.seek(self.base + int(entry["offset"]))
            return stream.read(entry["size"]).decode("utf-8", errors="replace")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("needle")
    parser.add_argument("--file", default=".vite/build/")
    parser.add_argument("--context", type=int, default=500)
    parser.add_argument("--limit", type=int, default=5)
    parser.add_argument("--bundle", default="/Applications/ChatGPT.app/Contents/Resources/app.asar")
    args = parser.parse_args()
    bundle = Asar(args.bundle)
    for path, entry in bundle.entries():
        if args.file not in path or not path.endswith((".js", ".mjs", ".json", ".mts")):
            continue
        source = bundle.read(entry)
        start = 0
        for _ in range(args.limit):
            index = source.find(args.needle, start)
            if index < 0:
                break
            print(path, "offset", index)
            print(source[max(0, index - 150):index + args.context])
            start = index + len(args.needle)


if __name__ == "__main__":
    main()
