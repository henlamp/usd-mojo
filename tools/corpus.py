"""Fetch a small, pinned external corpus explicitly; never bundle it in packages."""

import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path, PurePosixPath
from urllib.request import Request, urlopen
from urllib.error import URLError

SOURCES = {
    "vehicles": {
        "repository": "usd-wg/assets",
        "commit": "091bb5c6f8eb665ad4cf9d6c10025cecc07eda88",
        "prefix": "full_assets/Vehicles/USD_Mini_Car_Kit/",
        "notices": ["LICENSE", "full_assets/Vehicles/readme.md"],
        "license": "CC0-1.0 (assets); Apache-2.0 (repository)",
    },
    "robot": {
        "repository": "ARISE-Initiative/yamlab",
        "commit": "ec0455d2b4ce35f21fc126418ea5e74ac567133d",
        "prefix": "yamlab/robot/yam/arm/",
        "notices": ["LICENSE"],
        "license": "MIT",
    },
}
LIMIT = 64 * 1024 * 1024


def download(url, limit=LIMIT):
    headers = {"User-Agent": "usd-mojo-corpus-check"}
    request = Request(url, headers=headers)
    for attempt in range(3):
        try:
            with urlopen(request, timeout=60) as response:
                data = response.read(limit + 1)
            break
        except (URLError, TimeoutError):
            if attempt == 2:
                raise
    if len(data) > limit:
        raise ValueError("Corpus download exceeds size limit")
    return data


def git_hash(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def local_path(root, relative):
    path = PurePosixPath(relative)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise ValueError("Invalid corpus path")
    target = root.joinpath(*path.parts)
    if not target.resolve().is_relative_to(root.resolve()):
        raise ValueError("Corpus symlink leaves destination")
    return target


def fetch(destination):
    destination.mkdir(parents=True, exist_ok=True)
    receipt = {"sources": SOURCES, "files": {}}
    for name, source in SOURCES.items():
        repository, commit = source["repository"], source["commit"]
        tree = json.loads(
            download(
                f"https://api.github.com/repos/{repository}/git/trees/{commit}?recursive=1"
            )
        )
        if tree.get("truncated") or tree.get("sha") != commit:
            raise ValueError("Incomplete or unexpected corpus tree")
        files = [
            item
            for item in tree["tree"]
            if item["type"] == "blob"
            and (
                item["path"].startswith(source["prefix"])
                or item["path"] in source["notices"]
            )
        ]
        if not files or sum(item["size"] for item in files) > LIMIT:
            raise ValueError("Unexpected corpus size")
        if not set(source["notices"]).issubset({item["path"] for item in files}):
            raise ValueError("Missing corpus notices")

        def save(item):
            relative = name + "/" + item["path"]
            target = local_path(destination, relative)
            data = target.read_bytes() if target.is_file() else b""
            if len(data) != item["size"] or git_hash(data) != item["sha"]:
                data = download(
                    f"https://raw.githubusercontent.com/{repository}/{commit}/{item['path']}",
                    item["size"],
                )
                if len(data) != item["size"] or git_hash(data) != item["sha"]:
                    raise ValueError("Corpus content identity mismatch: " + relative)
                target.parent.mkdir(parents=True, exist_ok=True)
                temporary = target.with_name(target.name + ".download")
                temporary.write_bytes(data)
                temporary.replace(target)
            return relative, {
                "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "git_blob": item["sha"],
            }

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            receipt["files"].update(pool.map(save, files))
        print(name, len(files), "files verified", flush=True)
    (destination / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return verify(destination)


def verify(destination):
    receipt = json.loads((destination / "receipt.json").read_text())
    if receipt["sources"] != SOURCES:
        raise ValueError("Corpus source pins differ")
    for relative, identity in receipt["files"].items():
        raw = local_path(destination, relative).read_bytes()
        if (
            len(raw) != identity["bytes"]
            or git_hash(raw) != identity["git_blob"]
            or hashlib.sha256(raw).hexdigest() != identity["sha256"]
        ):
            raise ValueError("Corpus changed: " + relative)
    for name, source in SOURCES.items():
        for notice in source["notices"]:
            if name + "/" + notice not in receipt["files"]:
                raise ValueError("Missing corpus notice")
        if not any(
            path.startswith(name + "/" + source["prefix"]) for path in receipt["files"]
        ):
            raise ValueError("Empty corpus source")
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=Path)
    parser.add_argument("--fetch", action="store_true")
    args = parser.parse_args()
    receipt = fetch(args.destination) if args.fetch else verify(args.destination)
    print(
        len(receipt["files"]),
        "files;",
        sum(x["bytes"] for x in receipt["files"].values()),
        "bytes",
    )
