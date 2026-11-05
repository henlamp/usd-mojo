"""Bounded instanced-scene benchmark with verified output and separate timings."""
import hashlib
import json
import platform
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from build import BUILD, build, require_compile
from evidence import source_hash
from pxr import Usd, UsdGeom


def main():
    build()
    work = BUILD / "scene-benchmarks"
    work.mkdir(parents=True, exist_ok=True)
    binary = work / "handoff"
    require_compile(ROOT / "benchmarks/scene_handoff.mojo", binary, ROOT / "src")
    report = {"completed": False, "source_sha256": source_hash(ROOT), "platform": platform.platform(),
        "scope": "Warm local CPU scene capture and matrix consumption; no GPU transfer, simulation or rendering speedup claim", "cases": []}
    for count in (1000, 5000):
        path = work / f"instances-{count}.usdc"
        path.unlink(missing_ok=True)
        stage = Usd.Stage.CreateNew(str(path))
        UsdGeom.Xform.Define(stage, "/World").AddTranslateOp().Set((1, 0, 0))
        UsdGeom.Xform.Define(stage, "/Asset")
        UsdGeom.Mesh.Define(stage, "/Asset/Mesh").CreatePointsAttr([(0, 0, 0)])
        for i in range(count):
            prim = UsdGeom.Xform.Define(stage, f"/World/I{i}")
            prim.GetPrim().GetReferences().AddInternalReference("/Asset")
            prim.GetPrim().SetInstanceable(True)
            prim.AddTranslateOp().Set((i, 2*i, 3*i))
        stage.GetRootLayer().Save()
        output = subprocess.check_output([str(binary), str(path), "3"], text=True)
        samples = []
        for line in output.splitlines():
            marker, capture, consume, prims, instances, checksum = line.split()
            assert marker == "SAMPLE" and int(prims) == count + 3 and int(instances) == count, line
            assert float(checksum) == 3 * count * count - 2 * count + 1, line
            samples.append({"capture_ns": int(capture), "consume_ns": int(consume)})
        assert len(samples) == 3
        report["cases"].append({"instances": count, "fixture_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "samples": samples, "capture_median_ns": statistics.median(s["capture_ns"] for s in samples),
            "consume_median_ns": statistics.median(s["consume_ns"] for s in samples)})
    report["completed"] = True
    (work / "benchmark.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
