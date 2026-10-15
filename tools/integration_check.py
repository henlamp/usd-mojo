"""Check installed USD/Axisweave/FileLock consumers against independent SDK geometry."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

from build import BUILD, ROOT
from evidence import source_hash
from package import package
from pxr import Gf, Usd, UsdGeom, Vt


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--axisweave", type=Path, default=ROOT.parent / "axisweave")
    parser.add_argument("--filelock", type=Path, default=ROOT.parent / "filelock-mojo")
    args = parser.parse_args()
    start = source_hash(ROOT)
    work = BUILD / "three library consumer"
    work.mkdir(parents=True, exist_ok=True)
    libraries = {}
    for checkout, name in (
        (args.axisweave, "axisweave"),
        (args.filelock, "filelock_mojo"),
    ):
        files = sorted((checkout / "src" / name).rglob("*.mojo"))
        assert files, f"Missing standalone source: {name}"
        manifest = {
            str(p.relative_to(checkout)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in files
        }
        subprocess.run(
            [
                "mojo",
                "precompile",
                "--Werror",
                str(checkout / "src" / name),
                "-o",
                str(work / (name + ".mojoc")),
            ],
            check=True,
        )
        libraries[name] = manifest
    installed = package()
    binary = work / "tensor-cache"
    subprocess.run(
        [
            sys.executable,
            str(installed / "compile.py"),
            str(ROOT / "examples/tensor_cache.mojo"),
            "-I",
            str(work),
            "-o",
            str(binary),
        ],
        check=True,
    )
    scene = work / "geometry Ω.usda"
    stage = Usd.Stage.CreateNew(str(scene))
    mesh = UsdGeom.Mesh.Define(stage, "/World/Mesh")
    points = [(i * 0.25, -i * 0.5, (i % 7) * 0.125) for i in range(96)]
    mesh.CreatePointsAttr(Vt.Vec3fArray([Gf.Vec3f(*map(float, p)) for p in points]))
    mesh.CreateFaceVertexCountsAttr([3] * 32)
    mesh.CreateFaceVertexIndicesAttr(list(range(96)))
    stage.GetRootLayer().Save()
    cache = work / "coordinates.txt"
    output = subprocess.check_output(
        [str(binary), str(scene), "/World/Mesh", str(cache)], text=True
    )
    header, values = cache.read_text().split("\n", 1)
    assert header == "USD-MESH-TENSOR-1 96"
    actual = [float(value) for value in values.splitlines()]
    sdk_points = UsdGeom.Mesh(stage.GetPrimAtPath("/World/Mesh")).GetPointsAttr().Get()
    expected = [
        float(point[coordinate]) for coordinate in range(3) for point in sdk_points
    ]
    assert actual == expected
    assert output.strip() == "96 32 288"
    rejected = subprocess.run(
        [
            sys.executable,
            str(installed / "compile.py"),
            str(ROOT / "examples/tensor_cache.mojo"),
            "-I",
            str(work / "missing"),
            "-o",
            str(work / "rejected"),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert rejected.returncode == 2 and "does not exist" in rejected.stderr
    assert source_hash(ROOT) == start
    report = {
        "status": "passed",
        "source_sha256": start,
        "compiler": subprocess.check_output(["mojo", "--version"], text=True).strip(),
        "external_sources": libraries,
        "source_include_paths": [],
        "points": 96,
        "faces": 32,
        "coordinates": 288,
        "sdk_coordinate_comparison": "exact",
        "missing_dependency_rejected": True,
        "cache_sha256": hashlib.sha256(cache.read_bytes()).hexdigest(),
        "cache_permissions": oct(cache.stat().st_mode & 0o777),
    }
    (BUILD / "integration.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
