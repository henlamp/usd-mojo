"""Exercise nested composition, animated geometry and saved stronger opinions."""

import hashlib
import subprocess

from pxr import Gf, Sdf, Usd, UsdGeom


def check(directory, compiler, root, imports):
    work = directory / "pipeline"
    work.mkdir()
    for lod, count in (("low", 3), ("high", 6)):
        stage = Usd.Stage.CreateNew(str(work / (lod + ".usdc")))
        mesh = UsdGeom.Mesh.Define(stage, "/Geom")
        points = [(i % 3, i // 3, 0) for i in range(count)]
        mesh.CreatePointsAttr(points)
        mesh.GetPointsAttr().Set(points, 1)
        mesh.GetPointsAttr().Set([(x, y, 2) for x, y, z in points], 3)
        mesh.CreateFaceVertexCountsAttr([3] * (count // 3))
        mesh.CreateFaceVertexIndicesAttr(list(range(count)))
        mesh.CreateSubdivisionSchemeAttr("none")
        mesh.CreateNormalsAttr([(0, 0, 1)] * count)
        mesh.SetNormalsInterpolation("faceVarying")
        uv = UsdGeom.PrimvarsAPI(mesh).CreatePrimvar(
            "st", Sdf.ValueTypeNames.TexCoord2fArray, "faceVarying"
        )
        uv.Set([(0, 0), (1, 0), (0, 1)])
        uv.SetIndices([i % 3 for i in range(count)])
        stage.GetRootLayer().Save()
    asset = Usd.Stage.CreateNew(str(work / "asset.usda"))
    prim = asset.DefinePrim("/Asset", "Xform")
    prim.CreateAttribute("gain", Sdf.ValueTypeNames.Double).Set(5)
    variants = prim.GetVariantSets().AddVariantSet("lod")
    for lod in ("low", "high"):
        variants.AddVariant(lod)
        variants.SetVariantSelection(lod)
        with variants.GetVariantEditContext():
            asset.DefinePrim("/Asset/Mesh").GetPayloads().AddPayload(
                lod + ".usdc", "/Geom"
            )
    variants.SetVariantSelection("low")
    asset.GetRootLayer().Save()
    wrapper = Usd.Stage.CreateNew(str(work / "wrapper.usda"))
    wrapper.DefinePrim("/Instance").GetReferences().AddReference(
        "asset.usda", "/Asset", Sdf.LayerOffset(5, 2)
    )
    wrapper.GetRootLayer().Save()
    assembly = Usd.Stage.CreateNew(str(work / "assembly.usda"))
    assembly.DefinePrim("/Robot").GetReferences().AddReference(
        "wrapper.usda", "/Instance", Sdf.LayerOffset(-1, 0.5)
    )
    assembly.GetRootLayer().Save()
    scene = Usd.Stage.CreateNew(str(work / "root.usda"))
    scene.GetRootLayer().subLayerPaths = ["assembly.usda"]
    scene.CreateClassPrim("/_Defaults").CreateAttribute(
        "gain", Sdf.ValueTypeNames.Double
    ).Set(13)
    scene.GetPrimAtPath("/Robot").GetInherits().AddInherit("/_Defaults")
    scene.GetPrimAtPath("/Robot").SetCustomDataByKey(
        "nested:asset_slots",
        Sdf.AssetPathArray(
            [Sdf.AssetPath("low.usdc"), Sdf.AssetPath(), Sdf.AssetPath("high.usdc")]
        ),
    )
    scene.GetRootLayer().Save()
    assert scene.GetPrimAtPath("/Robot").GetAttribute("gain").Get() == 13
    scene.GetPrimAtPath("/Robot").GetVariantSet("lod").SetVariantSelection("high")
    scene.GetRootLayer().Save()
    # Independent SDK state is released before the Mojo process opens these files.
    scene = asset = wrapper = assembly = stage = None
    sources = {
        p.name: hashlib.sha256(p.read_bytes()).hexdigest()
        for p in work.glob("*.usd*")
        if p.name != "root.usda"
    }
    binary = work / "pipeline"
    compiler(root / "tests/pipeline.mojo", binary, imports)
    raw = subprocess.check_output(
        [
            str(binary),
            str(work / "root.usda"),
            str(work / "flat.usdc"),
            str(work / "scene.usdz"),
        ],
        text=True,
    )
    reference = Usd.Stage.Open(str(work / "root.usda"))
    points_checked = 0
    for line in raw.splitlines():
        if not line.startswith("POINT "):
            continue
        _, time, index, component, value = line.split()
        points = (
            UsdGeom.Mesh(reference.GetPrimAtPath("/Robot/Mesh"))
            .GetPointsAttr()
            .Get(float(time))
        )
        assert float(value) == float(points[int(index)][int(component)]), line
        points_checked += 1
    assert points_checked == 3 * 6 * 3
    for path in (work / "root.usda", work / "flat.usdc", work / "scene.usdz"):
        reopened = Usd.Stage.Open(str(path))
        assert reopened.GetPrimAtPath("/Robot").GetAttribute("gain").Get() == 21
        slots = reopened.GetPrimAtPath("/Robot").GetCustomDataByKey(
            "nested:asset_slots"
        )
        assert (
            len(slots) == 3 and slots[1].path == "" and slots[0].path and slots[2].path
        )
        mesh = UsdGeom.Mesh(reopened.GetPrimAtPath("/Robot/Mesh"))
        assert mesh.GetPointsAttr().GetTimeSamples() == [2.5, 4.5]
        assert mesh.GetNormalsInterpolation() == "faceVarying"
        uv = UsdGeom.PrimvarsAPI(mesh).GetPrimvar("st")
        assert uv.GetInterpolation() == "faceVarying" and list(uv.GetIndices()) == [
            0,
            1,
            2,
            0,
            1,
            2,
        ]
        assert uv.Get()[0] == Gf.Vec2f(0.25, 0)
    assert all(
        hashlib.sha256((work / name).read_bytes()).hexdigest() == digest
        for name, digest in sources.items()
    )
    return {
        "status": "passed",
        "nested_reference_offsets": True,
        "variants_payloads_inherits_overrides": True,
        "face_varying_uv_normals": True,
        "animated_point_components": points_checked,
        "weaker_files_unchanged": True,
        "formats": ["usda", "usdc", "usdz"],
    }
