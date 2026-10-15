"""Consistent SDK search paths for source and precompiled Mojo consumers."""

import sys
from pathlib import Path


def linker_flags(bridge: Path, prefix: Path = Path(sys.prefix)) -> list[str]:
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
    for path in (bridge, prefix / "lib"):
        flags += ["-Xlinker", "-rpath", "-Xlinker", str(path)]
    return flags
