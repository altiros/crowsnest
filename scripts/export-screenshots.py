#!/usr/bin/env python3
"""Copies the screenshots of `make screenshots` from the exported xcresult attachments to build/appstore/<name>.png,
with the pixels upright (XCUIScreen writes landscape shots as portrait pixels plus an EXIF orientation tag,
which App Store Connect doesn't apply) and without EXIF/XMP metadata."""
import json, shutil, struct, subprocess, sys
from pathlib import Path

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
dst.mkdir(parents=True, exist_ok=True)

def chunks(data):
    i = 8
    while i < len(data):
        length, = struct.unpack(">I", data[i:i + 4])
        yield data[i + 4:i + 8], data[i:i + 12 + length]
        i += 12 + length

def orientation(data):
    for kind, chunk in chunks(data):
        if kind == b"eXIf":
            exif = chunk[8:-4]
            endian = ">" if exif[:2] == b"MM" else "<"
            offset, = struct.unpack(endian + "I", exif[4:8])
            count, = struct.unpack(endian + "H", exif[offset:offset + 2])
            for n in range(count):
                entry = exif[offset + 2 + 12 * n:offset + 14 + 12 * n]
                tag, = struct.unpack(endian + "H", entry[:2])
                if tag == 0x0112:
                    return struct.unpack(endian + "H", entry[8:10])[0]
    return 1

for test in json.loads((src / "manifest.json").read_text()):
    for attachment in test.get("attachments", []):
        name = attachment["suggestedHumanReadableName"].split("_0_")[0]
        if not name[:2].isdigit():
            continue
        target = dst / f"{name}.png"
        shutil.copy(src / attachment["exportedFileName"], target)
        rotate = {6: "90", 8: "270", 3: "180"}.get(orientation(target.read_bytes()))
        if rotate:
            subprocess.run(["sips", "-r", rotate, str(target)], check=True, capture_output=True)
        data = target.read_bytes()
        target.write_bytes(data[:8] + b"".join(c for k, c in chunks(data) if k not in (b"eXIf", b"iTXt")))
        print(target)
