"""Preserve the package's own ELF bridge and locate embedded build paths."""

import hashlib
import json
import re
import shutil
import struct
import sys
from pathlib import Path


def inspect(path):
    data = path.read_bytes()
    if data[:6] != b"\x7fELF\x02\x01":
        raise ValueError("Expected a little-endian ELF64 bridge")
    offset = struct.unpack_from("<Q", data, 40)[0]
    size, count, names_index = struct.unpack_from("<HHH", data, 58)
    sections = [
        struct.unpack_from("<IIQQQQIIQQ", data, offset + i * size)
        for i in range(count)
    ]
    names_section = sections[names_index]
    names = data[names_section[4] : names_section[4] + names_section[5]]
    matches = []
    for match in re.finditer(rb"/(?:Users|home)/[A-Za-z0-9_.-]+/", data):
        start = match.start()
        end = data.find(b"\0", start)
        section = "outside sections"
        for entry in sections:
            if entry[1] != 8 and entry[4] <= start < entry[4] + entry[5]:
                section = names[entry[0] :].split(b"\0", 1)[0].decode()
                break
        matches.append({
            "offset": start,
            "section": section,
            "value": data[start : min(end if end >= 0 else len(data), start + 1024)].decode(
                errors="replace"
            ),
        })
    return {
        "path": str(path),
        "sha256": hashlib.sha256(data).hexdigest(),
        "bytes": len(data),
        "personal_paths": matches,
    }


def main():
    source, output = map(Path, sys.argv[1:])
    output.mkdir(parents=True, exist_ok=True)
    reports = []
    for index, path in enumerate(sorted(source.rglob("libusd_mojo_bridge.so"))):
        report = inspect(path)
        reports.append(report)
        shutil.copy2(path, output / f"bridge-{index}.so")
    for index, path in enumerate(sorted(source.rglob("native-build"))):
        for name in ["CMakeCache.txt", "build.ninja", "cmake_install.cmake"]:
            item = path / name
            if item.is_file():
                shutil.copy2(item, output / f"native-{index}-{name}")
    text = json.dumps({"bridges": reports}, indent=2) + "\n"
    (output / "embedded-paths.json").write_text(text)
    print(text)


if __name__ == "__main__":
    main()
