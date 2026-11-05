"""SDK-authored multi-file assembly and independent persistence/array checks."""

from config import pins
import ctypes
import gc
import hashlib
import json
import math
import subprocess
from pathlib import Path

from pxr import Gf, Sdf, Usd, UsdGeom, UsdPhysics, UsdValidation, Vt


def fixture(work):
    (work / "unregistered-source.usda").write_text(
        '#usda 1.0\ndef Xform "Asset" {\n def Scope "Child" (vendorFlag = "preserved") {}\n}\n'
    )
    (work / "instance-unregistered.usda").write_text(
        '#usda 1.0\ndef Xform "World" (prepend references = @unregistered-source.usda@</Asset>\ninstanceable = true) {}\n'
    )
    (work / "unregistered.usda").write_text(
        '#usda 1.0\ndef Xform "World" (vendorFlag = "preserved") {}\n'
    )
    (work / "inactive-unregistered.usda").write_text(
        '#usda 1.0\ndef Xform "World" (active = false\nvendorFlag = "preserved") {}\n'
    )
    (work / "property-unregistered.usda").write_text(
        '#usda 1.0\ndef Xform "World" {\n custom double gain = 1 (vendorFlag = "preserved")\n}\n'
    )
    for name, gain in (("base", 1), ("weaker", 2)):
        stage = Usd.Stage.CreateNew(str(work / (name + ".usda")))
        UsdGeom.Xform.Define(stage, "/Robot").GetPrim().CreateAttribute(
            "order", Sdf.ValueTypeNames.Double
        ).Set(gain)
        UsdGeom.Xform.Define(stage, "/Model")
        stage.GetRootLayer().Save()
    for name, values in (
        ("reference", {"v_r": 6.0, "r_p": 6.0}),
        ("payload", {"r_p": 5.0, "p_s": 5.0}),
    ):
        stage = Usd.Stage.CreateNew(str(work / (name + ".usda")))
        prim = stage.DefinePrim("/Source", "Xform")
        for key, value in values.items():
            prim.CreateAttribute(key, Sdf.ValueTypeNames.Double).Set(value)
        prim.CreateRelationship("batch:conflict").SetTargets(["/Source"])
        prim.CreateRelationship("batch:hidden").SetTargets(["/Source"])
        stage.GetRootLayer().Save()
    for name, count in (("low", 3), ("high", 300000)):
        stage = Usd.Stage.CreateNew(str(work / (name + ".usdc")))
        UsdGeom.Xform.Define(stage, "/Asset")
        mesh = UsdGeom.Mesh.Define(stage, "/Asset/Geometry")
        mesh.CreatePointsAttr(
            Vt.Vec3fArray(
                [
                    Gf.Vec3f((i // 3) % 997 + (i % 3 == 1), i // 2991 + (i % 3 == 2), 0)
                    for i in range(count)
                ]
            )
        )
        mesh.CreateFaceVertexCountsAttr([3] * (count // 3))
        mesh.CreateFaceVertexIndicesAttr(list(range(count)))
        stage.GetRootLayer().Save()
    stage = Usd.Stage.CreateNew(str(work / "assembly.usda"))
    stage.GetRootLayer().subLayerPaths = ["base.usda", "weaker.usda"]
    model = stage.OverridePrim("/Model")
    model.GetReferences().AddReference("reference.usda", "/Source")
    stage.OverridePrim("/Timed").GetReferences().AddReference(
        Sdf.Reference("reference.usda", "/Source", Sdf.LayerOffset(10, 2))
    )
    Sdf.AttributeSpec(stage.GetRootLayer().GetPrimAtPath("/Timed"), "batch:hidden", Sdf.ValueTypeNames.Double).default = 1
    model.GetPayloads().AddPayload("payload.usda", "/Source")
    inherited = stage.CreateClassPrim("/Class")
    for name in ("l_i", "i_v"):
        inherited.CreateAttribute(name, Sdf.ValueTypeNames.Double).Set(8)
    model.GetInherits().AddInherit("/Class")
    special = stage.CreateClassPrim("/Special")
    special.CreateAttribute("p_s", Sdf.ValueTypeNames.Double).Set(4)
    model.GetSpecializes().AddSpecialize("/Special")
    variants = model.GetVariantSets().AddVariantSet("design")
    variants.AddVariant("default")
    variants.SetVariantSelection("default")
    with variants.GetVariantEditContext():
        for name in ("i_v", "v_r"):
            model.CreateAttribute(name, Sdf.ValueTypeNames.Double).Set(7)
    model.CreateAttribute("l_i", Sdf.ValueTypeNames.Double).Set(9)
    visual = stage.DefinePrim("/Robot/Visual", "Xform")
    lod = visual.GetVariantSets().AddVariantSet("lod")
    for name in ("low", "high"):
        lod.AddVariant(name)
        lod.SetVariantSelection(name)
        with lod.GetVariantEditContext():
            visual.GetPayloads().AddPayload(name + ".usdc", "/Asset")
    lod.SetVariantSelection("low")
    stage.SetDefaultPrim(stage.GetPrimAtPath("/Robot"))
    UsdGeom.SetStageMetersPerUnit(stage, 1)
    UsdGeom.SetStageUpAxis(stage, "Z")
    stage.GetRootLayer().Save()
    bad = Usd.Stage.CreateNew(str(work / "invalid.usda"))
    mesh = UsdGeom.Mesh.Define(bad, "/Broken")
    mesh.CreatePointsAttr([(0, 0, 0), (1, 0, 0), (0, 1, 0)])
    mesh.CreateFaceVertexCountsAttr([3])
    mesh.CreateFaceVertexIndicesAttr([0, 1, 2])
    mesh.GetFaceVertexIndicesAttr().Set([0, 1, 2], 0)
    mesh.GetFaceVertexIndicesAttr().Set([0, 1, 99], 1)
    bad.GetRootLayer().Save()
    mass_stage = Usd.Stage.CreateNew(str(work / "mass.usda"))
    body = UsdGeom.Cube.Define(mass_stage, "/Body").GetPrim()
    UsdPhysics.MassAPI.Apply(body).CreateMassAttr(float("nan"))
    mass_stage.GetRootLayer().Save()


def check(directory, compile_consumer, root, imports, library):
    work = directory / "maturity"
    work.mkdir()
    fixture(work)
    sources = {
        p.name: hashlib.sha256(p.read_bytes()).hexdigest()
        for p in work.glob("*")
        if p.name != "assembly.usda"
    }
    expected = Usd.Stage.Open(str(work / "assembly.usda"))
    gains = [
        expected.GetPrimAtPath("/Model").GetAttribute(key).Get()
        for key in ("l_i", "i_v", "v_r", "r_p", "p_s")
    ]
    assert gains == [9, 8, 7, 6, 5]
    del expected
    binary = work / "maturity"
    compile_consumer(root / "tests/maturity.mojo", binary, imports)
    output = subprocess.check_output([str(binary), str(work)], text=True)
    arrays = work / "arrays"
    compile_consumer(root / "tests/arrays.mojo", arrays, imports)
    subprocess.run([str(arrays), str(work)], check=True)
    original = Usd.Stage.Open(str(work / "unregistered.usda"))
    preserved = Usd.Stage.Open(str(work / "unregistered.usdc"))
    assert (
        original.GetPrimAtPath("/World").GetAllAuthoredMetadata()["vendorFlag"]
        == preserved.GetPrimAtPath("/World").GetAllAuthoredMetadata()["vendorFlag"]
    )
    assert not (work / "rejected-flat.usdc").exists()
    for name, checksum in sources.items():
        assert hashlib.sha256((work / name).read_bytes()).hexdigest() == checksum, name
    persisted = Usd.Stage.Open(str(work / "assembly.usda"))
    assert (
        persisted.GetRootLayer().GetPrimAtPath("/Robot").specifier == Sdf.SpecifierOver
    )
    assert persisted.GetPrimAtPath("/Robot").GetAttribute("order").Get() == 1
    assert persisted.GetPrimAtPath("/Robot").GetAttribute("runtime:gain").Get() == 3
    mapped = Sdf.Layer.FindOrOpen(str(work / "mapped-ref.usda"))
    assert mapped.ListTimeSamplesForPath("/Source.sampled") == [2.0]
    assert mapped.GetAttributeAtPath("/Source.clock").default == Sdf.TimeCode(5)
    for name in ("flat.usdc", "bundle.usdz"):
        reopened = Usd.Stage.Open(str(work / name))
        assert (
            reopened.GetPrimAtPath("/Robot").GetAttribute("runtime:a1999").Get() == 1999
        )
        assert (
            len(
                UsdGeom.Mesh(reopened.GetPrimAtPath("/Robot/Visual/Geometry"))
                .GetPointsAttr()
                .Get()
            )
            == 3
        )
        if name == "bundle.usdz":
            with Usd.EditContext(reopened, reopened.GetSessionLayer()):
                lod = reopened.GetPrimAtPath("/Robot/Visual").GetVariantSet("lod")
                assert lod.SetVariantSelection("high")
                assert (
                    len(
                        UsdGeom.Mesh(reopened.GetPrimAtPath("/Robot/Visual/Geometry"))
                        .GetPointsAttr()
                        .Get()
                    )
                    == 300000
                )
                assert lod.ClearVariantSelection()
    nonflat = Usd.Stage.Open(str(work / "assembly.usdc"))
    assert nonflat.GetRootLayer().subLayerPaths == ["base.usda", "weaker.usda"]
    assert (
        nonflat.GetPrimAtPath("/Robot/Visual")
        .GetVariantSets()
        .GetVariantSet("lod")
        .GetVariantSelection()
        == "low"
    )
    assert nonflat.GetPrimAtPath("/Model").HasAuthoredReferences()
    edited = Usd.Stage.Open(str(work / "edited.usdz"))
    assert edited.GetPrimAtPath("/Edited").GetAttribute("runtime:gain").Get() == 4
    # The SDK oracle decides the finding identifiers/severities independently.
    registry = UsdValidation.ValidationRegistry()
    context = UsdValidation.ValidationContext(
        [registry.GetOrLoadValidatorByName("usdGeomValidators:StageMetadataChecker")]
    )
    wanted = sorted(
        (
            str(issue.GetIdentifier()),
            {1: "error", 2: "warning", 3: "info"}[issue.GetType().value],
        )
        for issue in context.Validate(persisted)
    )
    actual = sorted(
        tuple(line.split()[1:])
        for line in output.splitlines()
        if line.startswith("ISSUE ")
    )
    assert actual == wanted, (actual, wanted)
    invalid_stage = Usd.Stage.Open(str(work / "mass.usda"))
    wanted_bad = sorted(
        (
            str(issue.GetIdentifier()),
            {1: "error", 2: "warning", 3: "info"}[issue.GetType().value],
        )
        for issue in context.Validate(invalid_stage)
    )
    actual_bad = sorted(
        tuple(line.split()[1:])
        for line in output.splitlines()
        if line.startswith("ISSUE_BAD ")
    )
    assert wanted_bad and actual_bad == wanted_bad, (actual_bad, wanted_bad)
    lib = ctypes.CDLL(str(library))
    u64, i32, i64, text = (
        ctypes.c_uint64,
        ctypes.c_int32,
        ctypes.c_int64,
        ctypes.c_char_p,
    )
    lib.usdm_stage_open.argtypes = [text, i32]
    lib.usdm_stage_open.restype = u64
    lib.usdm_stage_close.argtypes = [u64]
    lib.usdm_stage_close.restype = None
    lib.usdm_native_array.argtypes = [u64, text, text, ctypes.c_double, i32]
    lib.usdm_native_array.restype = u64
    lib.usdm_native_array_close.argtypes = [u64]
    lib.usdm_native_array_close.restype = None
    lib.usdm_native_array_info.argtypes = [u64, ctypes.POINTER(u64), i64]
    lib.usdm_native_array_info.restype = i32
    stage = lib.usdm_stage_open(str(work / "assembly.usda").encode(), 0)
    assert stage
    a = b = 0
    try:
        a = lib.usdm_native_array(stage, b"/Robot/Visual/Geometry", b"points", 0, 1)
        b = lib.usdm_native_array(stage, b"/Robot/Visual/Geometry", b"points", 0, 1)
        assert a and b
        left, right = (u64 * 7)(), (u64 * 7)()
        assert lib.usdm_native_array_info(a, left, 7) == 0
        assert lib.usdm_native_array_info(b, right, 7) == 0
        assert left[3] == right[3] == 9
        repeated = (u64 * 7)()
        assert lib.usdm_native_array_info(a, repeated, 7) == 0
        assert repeated[5] == left[5]
        shared_between_reads = left[5] == right[5]
    finally:
        lib.usdm_native_array_close(a)
        lib.usdm_native_array_close(b)
        lib.usdm_stage_close(stage)
    sharing = {"low_composed": shared_between_reads}
    array_lifetime = {}
    lib.usdm_native_array_write.argtypes = [
        u64, text, text, text, ctypes.c_void_p, i64, u64, ctypes.c_double, i32
    ]
    lib.usdm_native_array_write.restype = i32
    for name, points in (("low", 3), ("high", 300000)):
        original_bytes = (work / (name + ".usdc")).read_bytes()
        filename = work / (name + "-array-owner.usdc")
        filename.write_bytes(original_bytes)
        reference = Usd.Stage.Open(str(filename))
        sdk_points = UsdGeom.Mesh(reference.GetPrimAtPath("/Asset/Geometry")).GetPointsAttr().Get()
        expected_hash = hashlib.sha256(memoryview(sdk_points).tobytes()).hexdigest()
        # Neither the oracle nor the assembly stages may keep this copy's data alive.
        del sdk_points, reference
        gc.collect()
        h = lib.usdm_stage_open(str(filename).encode(), 0)
        a = b = newer = 0
        try:
            a = lib.usdm_native_array(h, b"/Asset/Geometry", b"points", 0, 1)
            b = lib.usdm_native_array(h, b"/Asset/Geometry", b"points", 0, 1)
            left, right = (u64 * 7)(), (u64 * 7)()
            assert (
                a and b and lib.usdm_native_array_info(a, left, 7) == 0
                and lib.usdm_native_array_info(b, right, 7) == 0
            )
            assert left[3] == right[3] == points * 3
            sharing[name + "_usdc"] = left[5] == right[5]
            replacement = (ctypes.c_float * 6)(9, 8, 7, 6, 5, 4)
            assert lib.usdm_native_array_write(
                h, b"/Asset/Geometry", b"points", b"point3f[]", replacement, 6, 7, 0, 1
            ) == 0
            newer = lib.usdm_native_array(h, b"/Asset/Geometry", b"points", 0, 1)
            current = (u64 * 7)()
            assert newer and lib.usdm_native_array_info(newer, current, 7) == 0
            assert current[3] == 6
            assert ctypes.string_at(current[5], current[4]) == bytes(replacement)
            lib.usdm_stage_close(h)
            h = 0
            after = (u64 * 7)()
            assert lib.usdm_native_array_info(a, after, 7) == 0
            assert list(after) == list(left), "Snapshot storage changed after source edit/close"
            actual_hash = hashlib.sha256(ctypes.string_at(after[5], after[4])).hexdigest()
            assert actual_hash == expected_hash, "Retained components differ from the independent SDK read"
            assert filename.read_bytes() == original_bytes
            array_lifetime[name] = {
                "points": points, "source_edit_and_close": "passed", "oracle_released_before_native_open": True,
                "retained_components_sha256": actual_hash, "source_file_unchanged": True,
            }
        finally:
            lib.usdm_native_array_close(a)
            lib.usdm_native_array_close(b)
            lib.usdm_native_array_close(newer)
            if h:
                lib.usdm_stage_close(h)
    return {
        "status": "passed",
        "composition_strengths": gains,
        "high_poly_points": 300000,
        "source_files_unchanged": len(sources),
        "stable_view_pointer": True,
        "sdk_buffers_shared_between_reads": shared_between_reads,
        "batch_changes_notice_count": 1,
        "sdk_storage_sharing_by_case": sharing,
        "native_array_lifetime": array_lifetime,
        "sdk_validation_comparison": True,
        "sdk_invalid_metadata_issues": len(wanted_bad),
        "output": output.splitlines()[-1],
    }


if __name__ == "__main__":
    from build import BUILD, ROOT, build, require_compile
    from evidence import source_hash
    import platform
    import tempfile, argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--asset", type=Path, action="append", default=[])
    args = parser.parse_args()
    initial = source_hash(ROOT)
    library = build()
    directory = Path(tempfile.mkdtemp(prefix="maturity-", dir=BUILD))
    print("Evidence directory:", directory, flush=True)
    report = check(directory, require_compile, ROOT, ROOT / "src", library)
    if args.asset:
        doctor = directory / "doctor"
        require_compile(ROOT / "examples/validate_scene.mojo", doctor, ROOT / "src")
        registry = UsdValidation.ValidationRegistry()
        context = UsdValidation.ValidationContext(registry.GetOrLoadAllValidators())
        external = []
        for index, asset in enumerate(args.asset):
            raw = asset.read_bytes()
            stage = Usd.Stage.Open(str(asset))
            assert stage and not any(p.IsA(UsdGeom.Mesh) for p in stage.Traverse()), (
                "External SDK comparison currently expects primitive-only scenes"
            )
            counts = [0, 0, 0]
            for issue in context.Validate(stage):
                if issue.GetType().value in (1, 2, 3):
                    counts[issue.GetType().value - 1] += 1
            sdk_errors = counts[0]
            for prim in stage.Traverse(Usd.TraverseInstanceProxies()):
                if not prim.HasAPI(UsdPhysics.MassAPI):
                    continue
                mass = UsdPhysics.MassAPI(prim)
                for attr in (mass.GetMassAttr(), mass.GetDensityAttr()):
                    value = attr.Get()
                    counts[0] += not (math.isfinite(value) and value >= 0)
                inertia = mass.GetDiagonalInertiaAttr().Get()
                counts[0] += not all(math.isfinite(v) and v >= 0 for v in inertia)
                center = mass.GetCenterOfMassAttr().Get()
                counts[0] += not (
                    all(v == -math.inf for v in center)
                    or all(math.isfinite(v) for v in center)
                )
                axes = mass.GetPrincipalAxesAttr().Get()
                counts[0] += not all(
                    math.isfinite(v) for v in (axes.GetReal(), *axes.GetImaginary())
                )
            result = subprocess.run(
                [str(doctor), str(asset)], text=True, capture_output=True, timeout=60
            )
            lines = [
                line.split()
                for line in result.stdout.splitlines()
                if line.startswith("SUMMARY ")
            ]
            assert len(lines) == 1
            assert [int(x) for x in lines[0][1:4]] == counts
            assert (result.returncode == 0) == (counts[0] == 0)
            assert asset.read_bytes() == raw
            (directory / f"external-{index}.log").write_text(
                result.stdout + result.stderr
            )
            external.append(
                {
                    "case": index,
                    "sha256": hashlib.sha256(raw).hexdigest(),
                    "sdk_errors": sdk_errors,
                    "errors": counts[0],
                    "warnings": counts[1],
                    "infos": counts[2],
                    "source_unchanged": True,
                }
            )
        report["external_robotics_import_cases"] = external
    assert source_hash(ROOT) == initial, "Source changed during maturity checks"
    report.update(
        {"source_sha256": initial, "machine": platform.machine(), "openusd": pins()["openusd"]}
    )
    (BUILD / "maturity-verification.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))
