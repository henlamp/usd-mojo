"""Consistent SDK search paths for source and precompiled Mojo consumers."""

import sys
import os
from pathlib import Path


def linker_flags(bridge: Path, prefix: Path | None = None) -> list[str]:
    prefix = prefix or Path(os.environ.get("USD_MOJO_SDK_PREFIX", sys.prefix))
    flags = [
        "-Xlinker",
        f"-L{bridge}",
        "-Xlinker",
        f"-L{prefix / 'lib'}",
        "-Xlinker",
        "-lusd_mojo_bridge",
    ]
    if sys.platform != "darwin":
        # SDK dependencies include a newer libstdc++ than older host compilers.
        # DT_RPATH applies transitively, unlike DT_RUNPATH.
        flags += ["-Xlinker", "--disable-new-dtags"]
    paths = [bridge, prefix / "lib", Path(sys.prefix) / "lib"]
    if os.environ.get("USD_MOJO_MATERIALX_PREFIX"):
        paths.append(Path(os.environ["USD_MOJO_MATERIALX_PREFIX"]) / "lib")
    for path in dict.fromkeys(p.resolve() for p in paths):
        flags += ["-Xlinker", "-rpath", "-Xlinker", str(path)]
    return flags
