"""Interleave APIs with distinct ownership costs; consume all geometry after timing."""

import argparse
import hashlib
import json
import platform
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from build import BUILD, build
from check import require_compile
from evidence import source_hash
from pxr import Gf, Usd, UsdGeom, Vt


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rounds", type=int, default=5)
    args = parser.parse_args()
    bridge = build()
    directory = BUILD / "native-benchmarks"
    directory.mkdir(parents=True, exist_ok=True)
    binary = directory / "native_views"
    require_compile(ROOT / "benchmarks/native_views.mojo", binary, ROOT / "src")
    report = {
        "completed": False,
        "source_sha256": source_hash(ROOT),
        "compiler": subprocess.check_output(["mojo", "--version"], text=True).strip(),
        "machine": platform.machine(),
        "platform": platform.platform(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256(bridge.read_bytes()).hexdigest(),
        "cases": [],
        "scope": "Host-side validated mesh access; warm SDK/filesystem caches; timer excludes destruction and full-data checksum. Owned allocates/copies outputs, borrowed retains snapshot storage, reuse copies to preallocated caller outputs. Different ownership contracts; not a general application or GPU speedup.",
    }
    target = directory / "benchmark.json"
    for count in [30000, 300000]:
        path = directory / f"mesh-{count}.usdc"
        path.unlink(missing_ok=True)
        stage = Usd.Stage.CreateNew(str(path))
        mesh = UsdGeom.Mesh.Define(stage, "/World/Mesh")
        mesh.CreatePointsAttr(
            Vt.Vec3fArray(
                [Gf.Vec3f(i % 997, (i // 997) % 997, i % 3) for i in range(count)]
            )
        )
        mesh.CreateFaceVertexCountsAttr([3] * (count // 3))
        mesh.CreateFaceVertexIndicesAttr(list(range(count)))
        stage.GetRootLayer().Save()
        del stage
        row = {
            "points": count,
            "fixture_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "repeats": 20,
            "raw_ns_per_operation": {"owned": [], "borrowed": [], "reuse": []},
            "checksums": {},
        }
        modes = ["owned", "borrowed", "reuse"]
        for iteration in range(args.rounds):
            for mode in modes[iteration % 3 :] + modes[: iteration % 3]:
                output = subprocess.check_output(
                    [str(binary), mode, str(path), "20"], text=True
                ).split()
                row["raw_ns_per_operation"][mode].append(int(output[0]) / 20)
                row["checksums"][mode] = float(output[1])
        assert len(set(row["checksums"].values())) == 1, row
        row["median_ns_per_operation"] = {
            mode: statistics.median(values)
            for mode, values in row["raw_ns_per_operation"].items()
        }
        report["cases"].append(row)
        target.write_text(json.dumps(report, indent=2) + "\n")
    report["completed"] = True
    target.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
