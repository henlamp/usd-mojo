"""Reproducible identity of library code, executable checks and pinned config."""

import hashlib
from pathlib import Path

SCOPE = "src/native/tests/examples/tools/benchmarks source files, pixi.toml, pixi.lock, Conda recipe and CI workflows; sorted relative path then file bytes"


def source_hash(root: Path):
    sources = [
        root / "pixi.toml",
        root / "pixi.lock",
    ]
    sources.extend((root / ".github/workflows").glob("*.yml"))
    sources.extend(p for p in (root / "conda.recipe").rglob("*") if p.is_file())
    for component in ("src", "native", "tests", "examples", "tools", "benchmarks"):
        sources.extend(
            p
            for p in (root / component).rglob("*")
            if p.is_file()
            and p.suffix
            in {".mojo", ".cpp", ".py", ".usda", ".toml", ".txt", ".h", ".json"}
        )
    result = hashlib.sha256()
    for path in sorted(sources):
        result.update(str(path.relative_to(root)).encode())
        result.update(path.read_bytes())
    return result.hexdigest()
