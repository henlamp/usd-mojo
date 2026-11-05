"""Installed Mojo workflows with an independent SDK oracle and optional public assets."""

import argparse
import hashlib
import json
import math
import platform
import subprocess
import sys
import tempfile
from pathlib import Path

from pxr import Ar, Gf, Sdf, Usd, UsdGeom, UsdPhysics, UsdShade, UsdUtils

from build import BUILD, ROOT, lifetime_metrics, require_compile
from corpus import SOURCES, verify
from evidence import source_hash
from maturity_checks import fixture
from package import package
from package_compile import validate


def checksum(values):
    result = 14695981039346656037
    for word in memoryview(values).cast("B").cast("I"):
        result = ((result ^ int(word)) * 1099511628211) & ((1 << 64) - 1)
    return result


def equal(actual, expected):
    if actual == expected:
        return True
    if isinstance(expected, Sdf.AssetPath):
        if not actual.resolvedPath or not expected.resolvedPath:
            return actual.path == expected.path
        resolver = Ar.GetResolver()
        a = resolver.OpenAsset(Ar.ResolvedPath(actual.resolvedPath))
        b = resolver.OpenAsset(Ar.ResolvedPath(expected.resolvedPath))
        return a and b and bytes(a.GetBuffer()) == bytes(b.GetBuffer())
    if isinstance(expected, float) and math.isnan(expected):
        return math.isnan(actual)
    if isinstance(expected, dict):
        return actual.keys() == expected.keys() and all(
            equal(actual[k], v) for k, v in expected.items()
        )
    if hasattr(expected, "__len__") and not isinstance(expected, str):
        if len(actual) != len(expected):
            return False
        return all(equal(a, b) for a, b in zip(actual, expected, strict=True))
    return actual == expected


def compare_stages(expected, actual):
    assert UsdGeom.GetStageUpAxis(actual) == UsdGeom.GetStageUpAxis(expected)
    assert UsdGeom.GetStageMetersPerUnit(actual) == UsdGeom.GetStageMetersPerUnit(
        expected
    )
    assert UsdPhysics.GetStageKilogramsPerUnit(
        actual
    ) == UsdPhysics.GetStageKilogramsPerUnit(expected)
    assert actual.GetTimeCodesPerSecond() == expected.GetTimeCodesPerSecond()
    assert actual.GetFramesPerSecond() == expected.GetFramesPerSecond()
    assert actual.HasAuthoredTimeCodeRange() == expected.HasAuthoredTimeCodeRange()
    assert actual.GetStartTimeCode() == expected.GetStartTimeCode()
    assert actual.GetEndTimeCode() == expected.GetEndTimeCode()
    assert actual.GetDefaultPrim().GetPath() == expected.GetDefaultPrim().GetPath()
    left = list(expected.Traverse(Usd.TraverseInstanceProxies()))
    right = list(actual.Traverse(Usd.TraverseInstanceProxies()))
    assert [p.GetPath() for p in left] == [p.GetPath() for p in right]
    attributes = samples = relationships = 0
    for a, b in zip(left, right, strict=True):
        assert a.GetTypeName() == b.GetTypeName(), a.GetPath()
        assert a.GetAppliedSchemas() == b.GetAppliedSchemas(), a.GetPath()
        # Composition bookkeeping is checked separately; ordinary metadata must survive.
        for key, value in a.GetAllAuthoredMetadata().items():
            if key not in {
                "specifier",
                "references",
                "payload",
                "variantSelection",
                "variantSetNames",
                "inheritPaths",
                "specializes",
                "instanceable",
            }:
                assert equal(b.GetAllAuthoredMetadata().get(key), value), (
                    a.GetPath(),
                    key,
                )
        assert [x.GetName() for x in a.GetAttributes()] == [
            x.GetName() for x in b.GetAttributes()
        ]
        for attr in a.GetAttributes():
            other = b.GetAttribute(attr.GetName())
            assert attr.GetTypeName() == other.GetTypeName()
            assert attr.GetConnections() == other.GetConnections()
            assert attr.GetTimeSamples() == other.GetTimeSamples()
            for time in [Usd.TimeCode.Default(), *attr.GetTimeSamples()]:
                assert equal(other.Get(time), attr.Get(time)), (attr.GetPath(), time)
                samples += 1
            attributes += 1
        assert [x.GetName() for x in a.GetRelationships()] == [
            x.GetName() for x in b.GetRelationships()
        ]
        for relationship in a.GetRelationships():
            assert (
                relationship.GetTargets()
                == b.GetRelationship(relationship.GetName()).GetTargets()
            ), relationship.GetPath()
            relationships += 1
    return {
        "prims": len(left),
        "attributes": attributes,
        "value_samples": samples,
        "relationships": relationships,
    }


def inventory(output, stage, root, freezeable):
    rows = [line.split("\t") for line in output.splitlines() if "\t" in line]
    prims = list(stage.Traverse(Usd.TraverseInstanceProxies()))
    assert [(x[1], x[2]) for x in rows if x[0] == "PRIM"] == [
        (str(p.GetPath()), p.GetTypeName()) for p in prims
    ]
    matrices = {x[1]: list(map(float, x[2:])) for x in rows if x[0] == "XFORM"}
    cache = UsdGeom.XformCache()
    mesh_rows = {x[1]: x[2:] for x in rows if x[0] == "MESH"}
    bodies = {x[1]: x[2:] for x in rows if x[0] == "BODY"}
    joints = {x[1]: x[2:] for x in rows if x[0] == "JOINT"}
    worst = 0.0
    points = 0
    for prim in prims:
        path = str(prim.GetPath())
        expected = [
            value for row in cache.GetLocalToWorldTransform(prim) for value in row
        ]
        observed = matrices[path]
        assert len(observed) == len(expected) and all(
            math.isclose(a, b, rel_tol=2e-12, abs_tol=2e-10)
            for a, b in zip(observed, expected, strict=True)
        ), path
        worst = max(
            worst, max(abs(a - b) for a, b in zip(observed, expected, strict=True))
        )
        if prim.IsA(UsdGeom.Mesh):
            mesh = UsdGeom.Mesh(prim)
            positions = mesh.GetPointsAttr().Get()
            counts = mesh.GetFaceVertexCountsAttr().Get()
            indices = mesh.GetFaceVertexIndicesAttr().Get()
            material, _ = UsdShade.MaterialBindingAPI(prim).ComputeBoundMaterial()
            wanted = [
                str(len(positions)),
                str(len(counts)),
                str(checksum(positions)),
                str(checksum(counts)),
                str(checksum(indices)),
                str(material.GetPath()) if material else "",
            ]
            assert mesh_rows[path] == wanted, (path, mesh_rows[path], wanted)
            points += len(positions)
        if prim.HasAPI(UsdPhysics.RigidBodyAPI):
            body, mass = UsdPhysics.RigidBodyAPI(prim), UsdPhysics.MassAPI(prim)
            values = [
                mass.GetMassAttr().Get() if mass else 0,
                int(body.GetRigidBodyEnabledAttr().Get()),
                int(body.GetKinematicEnabledAttr().Get()),
            ]
            assert all(
                math.isclose(a, b, rel_tol=2e-12, abs_tol=2e-10)
                for a, b in zip(map(float, bodies[path]), values, strict=True)
            ), path
        if prim.GetTypeName() in {
            "PhysicsFixedJoint",
            "PhysicsRevoluteJoint",
            "PhysicsPrismaticJoint",
        }:
            joint = UsdPhysics.Joint(prim)
            wanted = [
                str((joint.GetBody0Rel().GetTargets() or [""])[0]),
                str((joint.GetBody1Rel().GetTargets() or [""])[0]),
            ]
            assert joints[path][:2] == wanted
            if prim.GetTypeName() != "PhysicsFixedJoint":
                assert joints[path][2] == prim.GetAttribute("physics:axis").Get()
                for i, name in enumerate(
                    ["physics:lowerLimit", "physics:upperLimit"], 3
                ):
                    assert math.isclose(
                        float(joints[path][i]),
                        prim.GetAttribute(name).Get(),
                        rel_tol=2e-12,
                        abs_tol=2e-10,
                    )
    expected_variants = [
        (str(p.GetPath()), n, v)
        for p in prims
        for n in p.GetVariantSets().GetNames()
        for v in p.GetVariantSet(n).GetVariantNames()
    ]
    assert [tuple(x[1:]) for x in rows if x[0] == "VARIANT"] == expected_variants
    if not freezeable:
        mask = Usd.StagePopulationMask()
        mask.Add(root)
        stage = Usd.Stage.OpenMasked(stage.GetRootLayer().identifier, mask)
    frozen = Usd.Stage.Open(stage.Flatten())
    frozen_rows = [x[1:] for x in rows if x[0] == "FROZEN"]
    frozen_prims = list(frozen.Traverse())
    assert [x[0] for x in frozen_rows] == [str(p.GetPath()) for p in frozen_prims]
    cache = UsdGeom.XformCache()
    frozen_sum = 0.0
    for row, prim in zip(frozen_rows, frozen_prims, strict=True):
        assert row[1:3] == [prim.GetTypeName(), str(int(prim.IsInstance()))]
        matrix = [v for r in cache.GetLocalToWorldTransform(prim) for v in r]
        assert all(
            math.isclose(float(a), b, rel_tol=2e-12, abs_tol=2e-10)
            for a, b in zip(row[3:], matrix, strict=True)
        ), prim.GetPath()
        for value in matrix:
            frozen_sum += value
    for line in output.splitlines():
        if line.startswith("CAPTURE "):
            _, _, count, total = line.split()
            assert int(count) == len(frozen_prims) * 16
            assert math.isclose(float(total), frozen_sum, rel_tol=2e-12, abs_tol=2e-10)
    return {
        "prims": len(prims),
        "meshes": len(mesh_rows),
        "points": points,
        "bodies": len(bodies),
        "joints": len(joints),
        "maximum_transform_error": worst,
        "geometry_hashes_match": True,
        "material_bindings_match": True,
        "frozen_prims": len(frozen_prims),
        "frozen_matrices_match": True,
        "snapshot_population_mask": ["/"] if freezeable else [root],
    }


def fleet(path, vehicle, count):
    stage = Usd.Stage.CreateNew(str(path))
    UsdGeom.Xform.Define(stage, "/Fleet")
    for i in range(count):
        prim = UsdGeom.Xform.Define(stage, f"/Fleet/Vehicle_{i:04}")
        prim.GetPrim().GetReferences().AddReference(str(vehicle))
        prim.GetPrim().GetVariantSet("wheels").SetVariantSelection(
            ["4wd", "ambulance", "formula", "sedan", "tractor", "truckFlat", "van"][
                i % 7
            ]
        )
        prim.GetPrim().SetInstanceable(True)
        prim.AddTranslateOp().Set((i % 16 * 5, 0, i // 16 * 5))
    stage.SetDefaultPrim(stage.GetPrimAtPath("/Fleet"))
    UsdGeom.SetStageMetersPerUnit(stage, 1)
    UsdGeom.SetStageUpAxis(stage, "Y")
    stage.GetRootLayer().Save()
    assert len(stage.GetPrototypes()) == min(count, 7)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path)
    parser.add_argument("--package", type=Path)
    parser.add_argument("--rounds", type=int, default=40)
    parser.add_argument("--instances", type=int, default=256)
    args = parser.parse_args()
    if not 40 <= args.rounds <= 1000 or not 16 <= args.instances <= 1024:
        parser.error("Use 40..1000 rounds and 16..1024 instances")
    initial = source_hash(ROOT)
    installed = args.package or package()
    manifest = validate(
        installed,
        Path(sys.prefix),
        json.loads((installed / "manifest.json").read_text()),
    )
    if manifest["source_sha256"] != initial:
        raise ValueError("Installed package does not match the candidate source")
    directory = BUILD / "workloads"
    directory.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="run-", dir=directory))
    report = {
        "completed": False,
        "source_sha256": initial,
        "installed_source_sha256": manifest["source_sha256"],
        "system": sys.platform,
        "machine": platform.machine(),
        "external_corpus_checked": False,
        "cases": {},
        "scope": "Installed library, CPU workflows with independent SDK references; bounded soak, not production deployment or GPU qualification.",
    }
    target = directory / "acceptance.json"

    def save():
        target.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")

    def run(binary, name, *command):
        result = subprocess.run(
            [str(binary), *map(str, command)],
            capture_output=True,
            text=True,
            timeout=300,
        )
        (work / (name + ".stdout")).write_text(result.stdout)
        (work / (name + ".stderr")).write_text(result.stderr)
        if result.returncode:
            raise RuntimeError(f"{name} failed; logs: {work / name}")
        return result.stdout

    save()
    try:
        metrics = lifetime_metrics(work)
        binary = work / "workloads"
        require_compile(
            ROOT / "tests/workloads.mojo", binary, installed / "include",
            bridge=installed / "lib",
            extra_flags=("-O3", "-Xlinker", str(metrics)),
        )
        report["binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        generated = work / "generated"
        generated.mkdir()
        fixture(generated)
        cases = [("generated", generated / "assembly.usda", True)]
        receipt = None
        if args.corpus:
            corpus = args.corpus.resolve()
            receipt = verify(corpus)
            vehicle = (
                corpus
                / "vehicles/full_assets/Vehicles/USD_Mini_Car_Kit/assets/vehicles/vehicleVariants.usda"
            )
            robot = corpus / "robot/yamlab/robot/yam/arm/yam.usd"
            fleet_path = work / "fleet.usda"
            fleet(fleet_path, vehicle, args.instances)
            cases += [
                ("robot", robot, False),
                ("vehicles", vehicle, True),
                ("fleet", fleet_path, True),
            ]
            report["corpus_sources"] = SOURCES
            report["corpus_receipt_sha256"] = hashlib.sha256(
                (corpus / "receipt.json").read_bytes()
            ).hexdigest()
        for name, asset, freezeable in cases:
            stage = Usd.Stage.Open(str(asset))
            assert stage and not stage.GetCompositionErrors()
            root = str(stage.GetDefaultPrim().GetPath())
            unresolved = list(UsdUtils.ComputeAllDependencies(str(asset))[2])
            # Pin the known negative case instead of tolerating arbitrary missing assets.
            assert sorted(unresolved) == (["OmniPBR.mdl"] if name == "robot" else [])
            entry = {
                "input_sha256": hashlib.sha256(asset.read_bytes()).hexdigest(),
                "unresolved_assets": unresolved,
                "fresh_process_samples": [],
            }
            report["cases"][name] = entry
            if not freezeable:
                preserved = work / (name + "-preserved")
                preserved.mkdir()
                guard = preserved / "guarded.usdc"
                guard.write_bytes(b"existing output must survive rejected flattening")
                run(binary, name + "-preserve", "preserve", asset, preserved)
                assert (
                    guard.read_bytes()
                    == b"existing output must survive rejected flattening"
                )
                restored = Usd.Stage.Open(str(preserved / "source.usdc"))
                entry["full_layer_preservation"] = compare_stages(stage, restored)
            for sample in range(3):
                output = run(
                    binary,
                    f"{name}-inspect-{sample}",
                    "inspect",
                    asset,
                    root,
                    "complete" if freezeable else "metadata",
                )
                if sample == 0:
                    entry["inventory"] = inventory(output, stage, root, freezeable)
                metrics_rows = [
                    line.split()
                    for line in output.splitlines()
                    if line.startswith(("OPEN ", "SCAN ", "CAPTURE ", "PEAK_RSS "))
                ]
                assert sum(x[0] == "CAPTURE" for x in metrics_rows) == 3
                entry["fresh_process_samples"].append(metrics_rows)
            if name != "fleet":
                authored = work / (name + "-author")
                authored.mkdir()
                output = run(
                    binary,
                    name + "-author",
                    "author",
                    asset,
                    root,
                    authored,
                    "complete" if not unresolved else "incomplete",
                )
                overlay = Usd.Stage.Open(str(authored / "overlay.usda"))
                assert UsdGeom.GetStageUpAxis(overlay) == UsdGeom.GetStageUpAxis(stage)
                assert UsdGeom.GetStageMetersPerUnit(
                    overlay
                ) == UsdGeom.GetStageMetersPerUnit(stage)
                assert UsdPhysics.GetStageKilogramsPerUnit(
                    overlay
                ) == UsdPhysics.GetStageKilogramsPerUnit(stage)
                prim = overlay.GetPrimAtPath("/World/Asset")
                assert prim.GetAttribute("runtime:gain").Get() == 2
                assert prim.GetAttribute("runtime:label").Get() == "reviewed"
                assert prim.GetAttribute("runtime:step").GetTimeSamples() == [0, 24, 48]
                assert [
                    prim.GetAttribute("runtime:step").Get(t)
                    for t in [0, 12, 24, 36, 48]
                ] == [0, 0.5, 1, 1.5, 2]
                base = Usd.Stage.Open(str(authored / "base.usda"))
                assert (
                    base.GetPrimAtPath("/World/Asset")
                    .GetAttribute("runtime:gain")
                    .Get()
                    == 1
                )
                assert (
                    overlay.GetRootLayer().GetPrimAtPath("/World/Asset").specifier
                    == Sdf.SpecifierOver
                )
                entry["application_edits"] = []
                for line in output.splitlines():
                    fields = line.split("\t")
                    if fields[0] == "EDIT_DRIVE":
                        attr = (
                            prim.GetStage()
                            .GetPrimAtPath(fields[1])
                            .GetAttribute("drive:angular:physics:targetPosition")
                        )
                        assert attr.Get() == 15
                        entry["application_edits"].append(
                            {"kind": "joint_drive", "path": fields[1], "value": 15}
                        )
                    elif fields[0] == "EDIT_COLOR":
                        attr = (
                            prim.GetStage()
                            .GetPrimAtPath(fields[1])
                            .GetAttribute("inputs:diffuseColor")
                        )
                        assert attr.Get() == Gf.Vec3f(0.2, 0.4, 0.6)
                        assert not attr.GetConnections()
                        entry["application_edits"].append(
                            {"kind": "material_color", "path": fields[1]}
                        )
                if name == "robot":
                    assert any(
                        edit["kind"] == "joint_drive"
                        for edit in entry["application_edits"]
                    )
                if name == "vehicles":
                    assert any(
                        edit["kind"] == "material_color"
                        for edit in entry["application_edits"]
                    )
                entry["formats"] = {}
                variant_formats = []
                for filename in [
                    "layer.usdc",
                    "flat.usda",
                    "flat.usdc",
                    *([] if unresolved else ["bundle.usdz"]),
                ]:
                    restored = Usd.Stage.Open(str(authored / filename))
                    assert restored and not restored.GetCompositionErrors()
                    entry["formats"][filename] = compare_stages(overlay, restored)
                    if filename in {"layer.usdc", "bundle.usdz"}:
                        variant_formats.append((filename, restored))
                    if filename == "layer.usdc":
                        assert restored.GetRootLayer().subLayerPaths == ["base.usda"]
                    elif filename.startswith("flat"):
                        assert not restored.GetRootLayer().subLayerPaths
                if unresolved:
                    assert (
                        "PACKAGE_REJECTED" in output
                        and not (authored / "bundle.usdz").exists()
                    )
                selections = [
                    line.split("\t")[1:]
                    for line in output.splitlines()
                    if line.startswith("SELECT\t")
                ]
                with Usd.EditContext(overlay, overlay.GetSessionLayer()):
                    for variant_name, selection, count in selections:
                        prim.GetVariantSet(variant_name).SetVariantSelection(selection)
                        expected = sum(
                            len(UsdGeom.Mesh(p).GetPointsAttr().Get())
                            for p in overlay.Traverse(Usd.TraverseInstanceProxies())
                            if p.IsA(UsdGeom.Mesh)
                        )
                        assert int(count) == expected
                        for filename, restored in variant_formats:
                            with Usd.EditContext(restored, restored.GetSessionLayer()):
                                variant = restored.GetPrimAtPath(
                                    "/World/Asset"
                                ).GetVariantSet(variant_name)
                                assert selection in variant.GetVariantNames(), (
                                    filename,
                                    selection,
                                )
                                assert variant.SetVariantSelection(selection)
                                compare_stages(overlay, restored)
                entry["root_variant_selections_checked"] = len(selections)
                entry["variant_preserving_formats"] = [
                    name for name, _ in variant_formats
                ]
                soak_asset, soak_root = authored / "overlay.usda", "/World/Asset"
            else:
                soak_asset, soak_root = asset, root
                entry["instances"] = args.instances
                entry["shared_prototypes"] = len(stage.GetPrototypes())
            soak_dir = work / (name + "-soak")
            soak_dir.mkdir()
            output = run(
                binary,
                name + "-soak",
                "soak",
                soak_asset,
                soak_root,
                soak_dir,
                args.rounds,
            )
            memory = [
                list(map(int, line.split()[1:]))
                for line in output.splitlines()
                if line.startswith("MEMORY ")
            ]
            assert memory and memory[-1][0] == args.rounds - 1
            assert all(x[1] > 0 and x[3] >= x[1] for x in memory)
            rss_growth = max(x[1] for x in memory) - memory[0][1]
            allocator_growth = (
                max(x[2] for x in memory) - memory[0][2] if memory[0][2] >= 0 else None
            )
            assert rss_growth < 96 * 1024 * 1024, (name, "RSS growth", memory)
            assert allocator_growth is None or allocator_growth < 32 * 1024 * 1024, (
                name,
                "allocator growth",
                memory,
            )
            entry["soak"] = {
                "warmup_cycles": 10,
                "measured_cycles": args.rounds,
                "memory_samples": memory,
                "rss_growth_bytes": rss_growth,
                "allocator_live_growth_bytes": allocator_growth,
                "allocator_scope": "Default malloc zone on macOS; glibc arena plus mmap allocations on Linux >=2.33; -1 means unavailable, never zero allocations.",
            }
            assert (
                hashlib.sha256(asset.read_bytes()).hexdigest() == entry["input_sha256"]
            )
            save()
            print(name + ": passed", flush=True)
        if receipt is not None:
            assert verify(corpus) == receipt
            report["external_corpus_checked"] = True
            report["source_assets_unchanged"] = True
        assert source_hash(ROOT) == initial
        report["completed"] = True
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        save()
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
