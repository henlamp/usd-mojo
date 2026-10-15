"""Independent SDK fixtures and verification of the Mojo authoring API."""

import ctypes
import subprocess
from pathlib import Path

from pxr import Gf, Sdf, Usd, UsdGeom, UsdShade


def samples():
    result = {
        "bool": True,
        "uchar": 255,
        "int": -(2**31),
        "uint": 2**32 - 1,
        "int64": -(2**63),
        "uint64": 2**64 - 1,
        "half": 0.5,
        "float": 1.25,
        "double": 1.23456789012345,
        "timecode": Sdf.TimeCode(17.25),
        "string": "Grüße\n🔥",
        "token": "physics:body",
        "asset": Sdf.AssetPath("relative.asset"),
    }
    for n in (2, 3, 4):
        result[f"matrix{n}d"] = getattr(Gf, f"Matrix{n}d")(2.0)
    for suffix in "dfh":
        result[f"quat{suffix}"] = getattr(Gf, f"Quat{suffix}")(
            0.5, getattr(Gf, f"Vec3{suffix}")(0.25, -0.5, 0.75)
        )
    for n in (2, 3, 4):
        for prefix, suffix in (
            ("double", "d"),
            ("float", "f"),
            ("half", "h"),
            ("int", "i"),
        ):
            result[f"{prefix}{n}"] = getattr(Gf, f"Vec{n}{suffix}")(*range(1, n + 1))
    assert len(result) == 31
    return result


def check_values(
    directory: Path, compile_consumer, root: Path, imports: Path, bridge: Path
):
    fixture = directory / "values.usda"
    stage = Usd.Stage.CreateNew(str(fixture))
    prim = stage.DefinePrim("/Values", "Xform")
    for name, value in samples().items():
        typ = Sdf.ValueTypeNames.Find(name)
        prim.CreateAttribute("scalar_" + name, typ).Set(value)
        prim.CreateAttribute("array_" + name, typ.arrayType).Set([value, value])
        prim.CreateAttribute("empty_" + name, typ.arrayType).Set([])
    stage.GetRootLayer().Save()
    asset = directory / "reference-asset.usda"
    a = Usd.Stage.CreateNew(str(asset))
    p = a.DefinePrim("/Asset", "Xform")
    p.CreateAttribute("gain", Sdf.ValueTypeNames.Double).Set(1.0, 0)
    p.GetAttribute("gain").Set(3.0, 2)
    a.GetRootLayer().Save()
    layer = directory / "layer.usda"
    b = Usd.Stage.CreateNew(str(layer))
    b.DefinePrim("/Layer").CreateAttribute("number", Sdf.ValueTypeNames.Int64).Set(42)
    b.GetRootLayer().Save()
    binary = directory / "values"
    compile_consumer(root / "tests/value_roundtrip.mojo", binary, imports)
    out = directory / "authored.usda"
    flat = directory / "authored.usdc"
    output = subprocess.check_output(
        [str(binary), str(fixture), str(out), str(asset), str(layer), str(flat)],
        text=True,
    )
    for path in (out, flat):
        result = Usd.Stage.Open(str(path))
        target = result.GetPrimAtPath("/World")
        for attr in prim.GetAuthoredAttributes():
            actual = target.GetAttribute(attr.GetName())
            assert actual.GetTypeName() == attr.GetTypeName()
            assert actual.Get() == attr.Get(), (
                path,
                attr.GetName(),
                actual.Get(),
                attr.Get(),
            )
        assert target.GetAttribute("empty_text").Get() == ""
        assert target.GetAttribute("empty_scalar_string").Get() == ""
        assert target.GetAttribute("empty_scalar_token").Get() == ""
        assert target.GetAttribute("empty_scalar_asset").Get().authoredPath == ""
        assert result.GetDefaultPrim().GetPath() == Sdf.Path("/World")
        assert result.GetPrimAtPath("/Layer").GetAttribute("number").Get() == 42
        assert target.GetAttribute("gain").Get() == 20
    authored = Usd.Stage.Open(str(out))
    root_layer = authored.GetRootLayer()
    assert root_layer.subLayerPaths == [str(layer)]
    refs = root_layer.GetPrimAtPath("/World/Ref").referenceList.prependedItems
    assert len(refs) == 1 and refs[0].layerOffset == Sdf.LayerOffset(1, 2)
    world = authored.GetPrimAtPath("/World")
    assert world.GetVariantSet("mode").GetVariantNames() == ["a", "b"]
    world.GetVariantSet("mode").SetVariantSelection("a")
    assert world.GetAttribute("gain").Get() == 10
    # Raw ABI rejects a null nonempty buffer without touching memory.
    api = ctypes.CDLL(str(bridge))
    api.usdm_value_new.argtypes = [ctypes.c_char_p]
    api.usdm_value_new.restype = ctypes.c_uint64
    api.usdm_value_fill.argtypes = [
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int64,
        ctypes.c_void_p,
        ctypes.c_int64,
        ctypes.c_void_p,
        ctypes.c_int64,
    ]
    api.usdm_value_close.argtypes = [ctypes.c_uint64]
    handle = api.usdm_value_new(b"double")
    try:
        assert api.usdm_value_fill(handle, None, 1, None, 0, None, 0) == -1
        assert api.usdm_value_fill(handle, None, -1, None, 0, None, 0) == -1
    finally:
        api.usdm_value_close(handle)
    return {
        "scalar_types": 31,
        "array_types": 31,
        "empty_arrays": 31,
        "independent_sdk_roundtrips": 186,
        "output": output.strip(),
    }


def check_graphics(directory: Path, compile_consumer, root: Path, imports: Path):
    path = directory / "graphics.usda"
    stage = Usd.Stage.CreateNew(str(path))
    stage.DefinePrim("/World", "Xform")
    mesh = UsdGeom.Mesh.Define(stage, "/World/Mesh")
    mesh.CreatePointsAttr([(0, 0, 0), (1, 0, 0), (0, 1, 0)])
    mesh.CreateFaceVertexCountsAttr([3])
    mesh.CreateFaceVertexIndicesAttr([0, 1, 2])
    mesh.CreateNormalsAttr([(0, 0, 1)] * 3)
    mesh.SetNormalsInterpolation("vertex")
    uv = UsdGeom.PrimvarsAPI(mesh).CreatePrimvar(
        "st", Sdf.ValueTypeNames.TexCoord2fArray, "faceVarying"
    )
    uv.Set([(0, 0), (1, 0), (0, 1)])
    uv.SetIndices([0, 1, 2])
    material = UsdShade.Material.Define(stage, "/World/Material")
    UsdShade.MaterialBindingAPI.Apply(stage.GetPrimAtPath("/World")).Bind(material)
    camera = UsdGeom.Camera.Define(stage, "/World/Camera")
    camera.CreateFocalLengthAttr(35)
    camera.CreateClippingRangeAttr(Gf.Vec2f(0.1, 1000))
    UsdGeom.Xformable(camera).AddTranslateOp().Set(Gf.Vec3d(0, 0, 5))
    stage.GetRootLayer().Save()
    binary = directory / "graphics"
    compile_consumer(root / "tests/graphics.mojo", binary, imports)
    return subprocess.check_output([str(binary), str(path)], text=True).strip()
