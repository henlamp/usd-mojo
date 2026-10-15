"""Interleaved owned-output comparisons with OpenUSD, including raw timings/RSS."""

import argparse
import hashlib
import json
import platform
import re
import shutil
import statistics
import subprocess
import sys
from pathlib import Path

from pxr import Gf, Usd, UsdGeom, Vt

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--library", type=Path, default=ROOT)
    p.add_argument("--build-dir", type=Path, required=True)
    p.add_argument("--label", default="current")
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--small", action="store_true")
    p.add_argument(
        "--library-commit", help="Explicit identity for an archived source checkout"
    )
    args = p.parse_args()
    build = args.build_dir.resolve()
    build.mkdir(parents=True, exist_ok=True)
    lib = args.library.resolve()
    sys.path.insert(0, str(lib / "tools"))
    from build import build as build_bridge
    from check import require_compile

    # The harness is shared even when measuring an older source archive.
    sys.path.insert(0, str(ROOT / "tools"))
    from evidence import SCOPE, source_hash

    bridge = build_bridge()
    mojo = build / "consumer"
    require_compile(ROOT / "benchmarks/consumer.mojo", mojo, lib / "src")
    sdk = build / "sdk"
    prefix = Path(sys.prefix)
    # Use SDK targets' transitive flags via CMake, not guessed link ordering.
    project = build / "sdk-source"
    project.mkdir(exist_ok=True)
    (project / "CMakeLists.txt").write_text(
        f'''cmake_minimum_required(VERSION 3.30)\nproject(benchmark LANGUAGES CXX)\nfind_package(pxr CONFIG REQUIRED)\nadd_executable(sdk "{ROOT / "benchmarks/sdk.cpp"}")\ntarget_compile_features(sdk PRIVATE cxx_std_17)\ntarget_link_directories(sdk PRIVATE "{prefix}/lib")\nif(NOT APPLE)\ntarget_link_options(sdk PRIVATE -Wl,--disable-new-dtags)\nendif()\ntarget_include_directories(sdk PRIVATE ${{PXR_INCLUDE_DIRS}})\ntarget_link_libraries(sdk PRIVATE usd usdGeom sdf tf gf vt)\nif(TARGET Python3::Python)\ntarget_link_libraries(sdk PRIVATE Python3::Python)\nendif()\nset_target_properties(sdk PROPERTIES BUILD_RPATH "{prefix}/lib")\n'''
    )
    subprocess.run(
        [
            "cmake",
            "-S",
            str(project),
            "-B",
            str(build / "sdk-build"),
            "-G",
            "Ninja",
            f"-DCMAKE_PREFIX_PATH={prefix}",
            "-DCMAKE_BUILD_TYPE=Release",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    subprocess.run(
        ["cmake", "--build", str(build / "sdk-build")],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    sdk = build / "sdk-build/sdk"
    cases = []
    for count in [100, 1000] if args.small else [100, 1000, 10000]:
        path = build / f"scene-{count}.usdc"
        path.unlink(missing_ok=True)
        stage = Usd.Stage.CreateNew(str(path))
        stage.DefinePrim("/World", "Xform")
        for i in range(count):
            stage.DefinePrim(f"/World/P{i:06}", "Xform")
        stage.GetRootLayer().Save()
        del stage
        cases += [("open", path, 5), ("traverse", path, 10)]
    for count in [30000] if args.small else [30000, 300000]:
        path = build / f"mesh-{count}.usdc"
        path.unlink(missing_ok=True)
        stage = Usd.Stage.CreateNew(str(path))
        stage.DefinePrim("/World", "Xform")
        m = UsdGeom.Mesh.Define(stage, "/World/Mesh")
        points = Vt.Vec3fArray(
            [Gf.Vec3f(i % 997, (i // 997) % 997, i % 3) for i in range(count)]
        )
        m.CreatePointsAttr(points)
        m.CreateFaceVertexCountsAttr([3] * (count // 3))
        m.CreateFaceVertexIndicesAttr(list(range(count)))
        stage.GetRootLayer().Save()
        del stage
        cases += [("mesh", path, 5), ("value", path, 5)]
    revision = None
    if (lib / ".git").exists() and shutil.which("git"):
        revision = subprocess.run(
            ["git", "rev-parse", "--verify", "HEAD"],
            cwd=lib,
            text=True,
            capture_output=True,
            check=False,
        )
    report = {
        "source_sha256": source_hash(lib),
        "source_hash_scope": SCOPE,
        "harness_sha256": hashlib.sha256(
            b"".join(
                (ROOT / "benchmarks" / x).read_bytes()
                for x in ["run.py", "sdk.cpp", "consumer.mojo"]
            )
        ).hexdigest(),
        "rss_scope": "whole process peak including SDK/runtime/startup",
        "label": args.label,
        "compiler": subprocess.check_output(["mojo", "--version"], text=True).strip(),
        "machine": platform.machine(),
        "platform": platform.platform(),
        "completed": False,
        "cache_state": "warmed filesystem and 3 untimed calls in each measured process; no cold-cache claim",
        "scope": "open timing excludes destruction; other operations include SDK resolution and owned-output allocation, exclude destruction; both mesh paths validate topology and finite points; checksums consume all output after timing",
        "cases": [],
        "binary_sha256": {
            n: hashlib.sha256(x.read_bytes()).hexdigest()
            for n, x in [("mojo", mojo), ("sdk", sdk), ("bridge", bridge)]
        },
        "library_commit": args.library_commit
        or (
            revision.stdout.strip()
            if revision is not None and revision.returncode == 0
            else "unavailable; use source_sha256"
        ),
        "working_tree_dirty": bool(
            subprocess.check_output(
                ["git", "status", "--porcelain"], cwd=lib, text=True
            )
        )
        if (lib / ".git").exists() and shutil.which("git")
        else None,
    }
    for op, path, repeats in cases:
        entry = {
            "operation": op,
            "fixture": path.name,
            "fixture_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "fixture_bytes": path.stat().st_size,
            "repeats": repeats,
            "raw_ns_per_operation": {"mojo": [], "sdk": []},
            "peak_rss_bytes": {"mojo": [], "sdk": []},
        }
        for binary in (mojo, sdk):
            subprocess.check_output([str(binary), op, str(path), "1"], text=True)
        for i in range(args.rounds):
            for name, binary in (
                [("mojo", mojo), ("sdk", sdk)]
                if i % 2 == 0
                else [("sdk", sdk), ("mojo", mojo)]
            ):
                cmd = [str(binary), op, str(path), str(repeats)]
                timer = (
                    ["/usr/bin/time", "-l"]
                    if sys.platform == "darwin"
                    else ["/usr/bin/time", "-f", "peak_rss_kib=%M"]
                )
                result = subprocess.run(
                    timer + cmd, text=True, capture_output=True, check=True
                )
                output = result.stdout.split()
                entry["raw_ns_per_operation"][name].append(int(output[0]) / repeats)
                entry.setdefault("checksums", {})[name] = float(output[1])
                match = (
                    re.search(r"(\d+)\s+maximum resident set size", result.stderr)
                    if sys.platform == "darwin"
                    else re.search(r"peak_rss_kib=(\d+)", result.stderr)
                )
                assert match, result.stderr
                entry["peak_rss_bytes"][name].append(
                    int(match[1]) * (1 if sys.platform == "darwin" else 1024)
                )
        assert entry["checksums"]["mojo"] == entry["checksums"]["sdk"], entry
        entry["median_ns_per_operation"] = {
            k: statistics.median(v) for k, v in entry["raw_ns_per_operation"].items()
        }
        entry["mojo_over_sdk"] = (
            entry["median_ns_per_operation"]["mojo"]
            / entry["median_ns_per_operation"]["sdk"]
        )
        report["cases"].append(entry)
        print(op, path.name, round(entry["mojo_over_sdk"], 3), flush=True)
    report["completed"] = True
    (build / "benchmark.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
