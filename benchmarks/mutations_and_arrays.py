"""Bounded measurements; array ownership contracts are intentionally different."""

import json
import platform
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from build import BUILD, build, lifetime_metrics, require_compile
from evidence import source_hash
from maturity_checks import fixture
from pxr import Usd, UsdGeom


def main():
    build()
    work = BUILD / "mutation-array-benchmarks"
    work.mkdir(parents=True, exist_ok=True)
    # Fresh filenames avoid the SDK layer registry retaining a preceding case.
    import tempfile

    scene = Path(tempfile.mkdtemp(prefix="scene-", dir=work))
    fixture(scene)
    metrics = lifetime_metrics(work)
    binary = work / "benchmark"
    require_compile(
        ROOT / "benchmarks/mutations_and_arrays.mojo", binary, ROOT / "src",
        extra_flags=("-Xlinker", str(metrics)),
    )
    oracle = Usd.Stage.Open(str(scene / "high.usdc"))
    expected = sum(
        float(component)
        for point in UsdGeom.Mesh(oracle.GetPrimAtPath("/Asset/Geometry"))
        .GetPointsAttr()
        .Get()
        for component in point
    )
    cases = {}
    for mode in ("single", "batch", "native", "value"):
        lines = subprocess.check_output(
            [str(binary), str(scene / "assembly.usda"), mode], text=True
        ).splitlines()
        samples = []
        for line in lines:
            fields = line.split()
            if fields[0] == "MUTATION":
                samples.append(int(fields[1]))
                assert int(fields[2]) == (1 if mode == "batch" else 2000)
            elif fields[0] == "ARRAY":
                samples.append(int(fields[1]))
                assert int(fields[2]) == 900000 and float(fields[3]) == expected
        assert len(samples) == 3
        cases[mode] = {"samples_ns": samples, "median_ns": statistics.median(samples)}
        for line in lines:
            fields = line.split()
            if fields[0] in {"OPEN", "LOD", "FIRST_ARRAY", "FIRST_MUTATION"}:
                cases[mode][fields[0].lower() + "_ns"] = int(fields[1])
        rss = [line.split() for line in lines if line.startswith("RSS ")]
        if rss:
            cases[mode]["peak_rss_before_bytes"] = int(rss[0][1])
            cases[mode]["peak_rss_after_bytes"] = int(rss[0][2])
    report = {
        "completed": True,
        "source_sha256": source_hash(ROOT),
        "platform": platform.platform(),
        "mutations_per_round": 2000,
        "points": 300000,
        "cases": cases,
        "scope": "Local CPU, fresh processes with warm filesystem caches; first access and three warm samples per mode. Native holds immutable SDK storage; Value creates mutable Float64 copies. SDK decoding can allocate. Peak RSS is process-wide. No disk/GPU zero-copy or general speedup claim.",
    }
    (work / "benchmark.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
