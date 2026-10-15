"""Run a Mojo consumer with the bridge linked through the C ABI."""

import os
import subprocess
import sys
from pathlib import Path

from link import linker_flags

ROOT = Path(__file__).resolve().parents[1]
BUILD = (
    Path(os.environ.get("USD_MOJO_BUILD_DIR", ROOT / ".build")).expanduser().resolve()
)


def run(source: Path, args: list[str], imports: Path | None = None) -> None:
    bridge = BUILD / "native"
    binary = BUILD / source.stem
    subprocess.run(
        [
            "mojo",
            "build",
            "--Werror",
            "-I",
            str(imports or ROOT / "src"),
            *linker_flags(bridge),
            str(source),
            "-o",
            str(binary),
        ],
        check=True,
    )
    subprocess.run([str(binary), *args], check=True)


if __name__ == "__main__":
    run(Path(sys.argv[1]), sys.argv[2:])
