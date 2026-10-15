"""Build the small C ABI bridge against the SDK in the active Pixi prefix."""

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = (
    Path(os.environ.get("USD_MOJO_BUILD_DIR", ROOT / ".build")).expanduser().resolve()
)


def build() -> Path:
    BUILD.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "cmake",
            "-S",
            str(ROOT / "native"),
            "-B",
            str(BUILD / "native"),
            "-G",
            "Ninja",
            f"-DCMAKE_PREFIX_PATH={sys.prefix}",
            "-DCMAKE_BUILD_TYPE=Release",
        ],
        check=True,
    )
    subprocess.run(
        ["cmake", "--build", str(BUILD / "native"), "--parallel", "2"], check=True
    )
    return (
        BUILD
        / "native"
        / (
            "libusd_mojo_bridge.dylib"
            if sys.platform == "darwin"
            else "libusd_mojo_bridge.so"
        )
    )


if __name__ == "__main__":
    print(build())
