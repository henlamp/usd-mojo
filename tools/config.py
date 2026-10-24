"""Version pins and SDK identity used by builders and release checks."""

import hashlib
import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def pins(root=ROOT):
    data = tomllib.loads((root / "pixi.toml").read_text())
    return {
        "openusd": data["dependencies"]["openusd"].removeprefix("=="),
        "mojo": data["pypi-dependencies"]["mojo"].removeprefix("=="),
        "nightly": data["feature"]["nightly"]["pypi-dependencies"]["mojo"].removeprefix(
            "=="
        ),
    }


def sdk_version(prefix=Path(sys.prefix)):
    found = re.search(
        r"#define\s+PXR_VERSION\s+(\d+)", (prefix / "include/pxr/pxr.h").read_text()
    )
    if not found:
        raise ValueError("Cannot identify the OpenUSD SDK")
    return int(found[1])


def sdk_identity(prefix):
    identity = prefix / "usd-mojo-sdk.json"
    return {
        "sdk_version": sdk_version(prefix),
        "optional_sdk_sha256": hashlib.sha256(identity.read_bytes()).hexdigest()
        if identity.is_file()
        else None,
        "sdk_materialx": any(
            (prefix / "lib" / ("libusd_usdMtlx" + suffix)).is_file()
            for suffix in (".dylib", ".so")
        ),
    }
