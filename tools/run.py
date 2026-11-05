"""Run a Mojo consumer with the bridge linked through the C ABI."""

import subprocess
import sys
from pathlib import Path

from build import BUILD, ROOT, require_compile


def run(source: Path, args: list[str], imports: Path | None = None) -> None:
    binary = BUILD / source.stem
    require_compile(source, binary, imports or ROOT / "src")
    subprocess.run([str(binary), *args], check=True)


if __name__ == "__main__":
    run(Path(sys.argv[1]), sys.argv[2:])
