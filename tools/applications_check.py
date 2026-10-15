"""Run installed scene inventory and OBJ consumers against SDK references and local assets.

Local application assets are read in place and never vendored or published.
Generated synthetic coverage covers instances, holes, winding, animation and units.
"""

import argparse
import hashlib
import json
import math
import subprocess
import sys
from pathlib import Path

from build import BUILD, ROOT
from evidence import source_hash
from package import package
from pxr import Gf, Usd, UsdGeom


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def reference(path, frame):
    stage = Usd.Stage.Open(str(path))
    tc = Usd.TimeCode.Default() if frame is None else Usd.TimeCode(frame)
    cache = UsdGeom.XformCache(tc)
    units = UsdGeom.GetStageMetersPerUnit(stage)
    up = UsdGeom.GetStageUpAxis(stage)
    expected = {"prims": [], "meshes": [], "points": [], "faces": []}
    for prim in stage.Traverse(Usd.TraverseInstanceProxies()):
        name = str(prim.GetPath())
        expected["prims"].append((name, str(prim.GetTypeName())))
        if not prim.IsA(UsdGeom.Mesh):
            continue
        mesh = UsdGeom.Mesh(prim)
        points = mesh.GetPointsAttr().Get(tc)
        counts = mesh.GetFaceVertexCountsAttr().Get(tc)
        indices = mesh.GetFaceVertexIndicesAttr().Get(tc)
        matrix = cache.GetLocalToWorldTransform(prim)
        offset = len(expected["points"]) + 1
        expected["meshes"].append((name, len(points), len(counts)))
        for point in points:
            xyz = matrix.Transform(Gf.Vec3d(point)) * units
            expected["points"].append(
                (xyz[0], -xyz[2], xyz[1]) if up == "Y" else tuple(xyz)
            )
        flip = (mesh.GetOrientationAttr().Get(tc) == "leftHanded") != (
            matrix.GetDeterminant() < 0
        )
        holes = set(mesh.GetHoleIndicesAttr().Get(tc) or [])
        cursor = 0
        for i, count in enumerate(counts):
            if i not in holes:
                face = [offset + int(x) for x in indices[cursor : cursor + count]]
                expected["faces"].append(list(reversed(face)) if flip else face)
            cursor += count
    return expected


def application_fixture(path):
    stage = Usd.Stage.CreateNew(str(path))
    UsdGeom.SetStageUpAxis(stage, "Y")
    UsdGeom.SetStageMetersPerUnit(stage, 0.01)
    root = UsdGeom.Xform.Define(stage, "/World")
    root.AddTranslateOp().Set((20, 30, 40))
    source = UsdGeom.Xform.Define(stage, "/World/Source")
    source.AddScaleOp().Set((-1, 2, 1))
    mesh = UsdGeom.Mesh.Define(stage, "/World/Source/Mesh")
    mesh.CreatePointsAttr([(0, 0, 0), (100, 0, 0), (100, 100, 0), (0, 100, 0)])
    mesh.GetPointsAttr().Set(
        [(0, 0, 10), (100, 0, 10), (100, 100, 10), (0, 100, 10)], 1
    )
    mesh.CreateFaceVertexCountsAttr([3, 3])
    mesh.CreateFaceVertexIndicesAttr([0, 1, 2, 0, 2, 3])
    mesh.CreateHoleIndicesAttr([1])
    mesh.CreateOrientationAttr("leftHanded")
    UsdGeom.Camera.Define(stage, "/World/Camera")
    instance = stage.DefinePrim("/World/Instance", "Xform")
    instance.GetReferences().AddInternalReference("/World/Source")
    instance.SetInstanceable(True)
    stage.GetRootLayer().Save()


def run_case(inventory, exporter, path, directory, frame=None):
    identity = digest(path)
    suffix = f"frame-{frame}" if frame is not None else "default"
    target = directory / f"{path.stem}-{suffix}"
    args = [str(path)] + ([str(frame)] if frame is not None else [])
    observed = subprocess.run(
        [str(inventory), *args], capture_output=True, text=True, timeout=180, check=True
    )
    (target.with_suffix(".tsv")).write_text(observed.stdout)
    rows = [line.split("\t") for line in observed.stdout.splitlines()]
    expected = reference(path, frame)
    assert [(x[1], x[2]) for x in rows if x[0] == "PRIM"] == expected["prims"]
    assert [(x[1], int(x[2]), int(x[3])) for x in rows if x[0] == "MESH"] == expected[
        "meshes"
    ]
    result = subprocess.run(
        [str(exporter), *args], capture_output=True, text=True, timeout=180, check=True
    )
    output = target.with_suffix(".obj")
    output.write_text(result.stdout)
    points, faces = [], []
    for line in result.stdout.splitlines():
        if line.startswith("v "):
            points.append(tuple(map(float, line.split()[1:])))
        elif line.startswith("f "):
            faces.append(list(map(int, line.split()[1:])))
    assert len(points) == len(expected["points"])
    assert faces == expected["faces"]
    worst = 0.0
    for actual, wanted in zip(points, expected["points"], strict=True):
        for value, ref in zip(actual, wanted, strict=True):
            assert math.isfinite(value) and math.isclose(
                value, ref, rel_tol=2e-12, abs_tol=2e-10
            ), (value, ref)
            worst = max(worst, abs(value - ref))
    assert digest(path) == identity, "Application changed its input asset"
    return {
        "asset": path.name,
        "asset_sha256": identity,
        "frame": frame,
        "prims": len(expected["prims"]),
        "meshes": len(expected["meshes"]),
        "points": len(points),
        "faces": len(faces),
        "maximum_coordinate_error_m": worst,
        "obj_sha256": digest(output),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--asset", type=Path, action="append", default=[])
    parser.add_argument("--package", type=Path)
    args = parser.parse_args()
    installed = args.package or package()
    directory = BUILD / "applications"
    directory.mkdir(parents=True, exist_ok=True)
    report = {
        "completed": False,
        "source_sha256": source_hash(ROOT),
        "cases": [],
        "local_assets_bundled": False,
    }
    target = directory / "acceptance.json"

    def save():
        target.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")

    save()
    try:
        inventory, exporter = directory / "scene_report", directory / "export_obj"
        for name, binary in [("scene_report", inventory), ("export_obj", exporter)]:
            subprocess.run(
                [
                    sys.executable,
                    str(installed / "compile.py"),
                    str(ROOT / "examples" / (name + ".mojo")),
                    "-o",
                    str(binary),
                ],
                check=True,
            )
        report["binaries_sha256"] = {
            "inventory": digest(inventory),
            "exporter": digest(exporter),
        }
        fixture = directory / "application.usda"
        fixture.unlink(missing_ok=True)
        application_fixture(fixture)
        for frame in [None, 1.0]:
            report["cases"].append(
                run_case(inventory, exporter, fixture, directory, frame)
            )
            save()
        for path in args.asset:
            report["cases"].append(
                run_case(inventory, exporter, path.resolve(), directory)
            )
            save()
        report["completed"] = True
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        save()
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
