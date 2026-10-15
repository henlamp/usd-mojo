"""Compare general information to independently authored official SDK scenes."""

import subprocess
from pathlib import Path

from pxr import Sdf, Usd, UsdGeom


def fixtures(directory: Path):
    assets = directory / "assets"
    assets.mkdir()
    (assets / "texture.bin").write_bytes(b"asset-resolution-probe")
    asset = assets / "model.usda"
    s = Usd.Stage.CreateNew(str(asset))
    s.DefinePrim("/Asset", "Xform")
    s.SetDefaultPrim(s.GetPrimAtPath("/Asset"))
    m = UsdGeom.Mesh.Define(s, "/Asset/Mesh")
    m.CreatePointsAttr([(0, 0, 0), (1, 0, 0), (0, 1, 0)])
    m.CreateFaceVertexCountsAttr([3])
    m.CreateFaceVertexIndicesAttr([0, 1, 2])
    m.CreateNormalsAttr([(0, 0, 1)] * 3)
    p = m.GetPrim()
    p.CreateAttribute("textures", Sdf.ValueTypeNames.AssetArray).Set(
        [Sdf.AssetPath("texture.bin"), Sdf.AssetPath("absent.bin")]
    )
    a = p.CreateAttribute("texture", Sdf.ValueTypeNames.Asset)
    a.Set(Sdf.AssetPath("texture.bin"), 0)
    a.Set(Sdf.AssetPath("absent.bin"), 5)
    a = p.CreateAttribute("gain", Sdf.ValueTypeNames.Double)
    a.Set(2, 0)
    a.Set(8, 5)
    pv = UsdGeom.PrimvarsAPI(m).CreatePrimvar(
        "st", Sdf.ValueTypeNames.TexCoord2fArray, "faceVarying", 2
    )
    pv.Set([(0, 0), (1, 0), (0, 1), (1, 1)])
    pv.SetIndices([0, 1, 0])
    pv.SetUnauthoredValuesIndex(1)
    pv = UsdGeom.PrimvarsAPI(m).CreatePrimvar("fallback", Sdf.ValueTypeNames.FloatArray)
    pv.Set([1, 2])
    s.GetRootLayer().Save()
    del s
    root = directory / "information.usda"
    s = Usd.Stage.CreateNew(str(root))
    w = s.DefinePrim("/World", "Xform")
    s.SetStartTimeCode(0)
    s.SetEndTimeCode(12)
    s.SetTimeCodesPerSecond(24)
    s.SetFramesPerSecond(30)
    s.SetMetadata("customLayerData", {"revision": 7})
    w.SetCustomData({"nested": {"label": "Gruesse"}, "weight": 3.5})
    input = w.CreateAttribute("input", Sdf.ValueTypeNames.Float)
    input.SetMetadata("documentation", "InputDoc")
    input.AddConnection("/World.gain")
    w.CreateAttribute("gain", Sdf.ValueTypeNames.Float).Set(1)
    vs = w.GetVariantSet("mode")
    for choice in ("a", "b"):
        vs.AddVariant(choice)
    vs.SetVariantSelection("b")
    p = s.DefinePrim("/World/Instance", "Xform")
    p.GetReferences().AddReference(str(asset), "/Asset")
    p.SetInstanceable(True)
    p = s.DefinePrim("/World/Payload", "Xform")
    p.GetPayloads().AddPayload(str(asset), "/Asset")
    s.DefinePrim("/World/Inactive", "Xform").SetActive(False)
    s.CreateClassPrim("/Class")
    s.GetRootLayer().Save()
    del s
    broken = directory / "broken-reference.usda"
    s = Usd.Stage.CreateNew(str(broken))
    s.DefinePrim("/Bad").GetReferences().AddReference("missing.usda")
    s.GetRootLayer().Save()
    del s
    return root, asset, broken


def check_information(directory, compile_consumer, root, imports):
    fixture, asset, broken = fixtures(directory)
    binary = directory / "information"
    compile_consumer(root / "tests/information.mojo", binary, imports)
    output = subprocess.check_output(
        [
            str(binary),
            str(fixture),
            str(directory / "payload-authored.usda"),
            str(asset),
            str(broken),
        ],
        text=True,
    )
    s = Usd.Stage.Open(str(fixture), load=Usd.Stage.LoadNone)
    p = s.GetPrimAtPath("/World/Instance/Mesh")
    w = s.GetPrimAtPath("/World")
    expected = []

    def row(tag, *v):
        expected.append((tag, *v))

    def rows(tag, values):
        for value in values:
            row(tag, str(value))

    row(
        "TIME",
        s.GetStartTimeCode(),
        s.GetEndTimeCode(),
        s.GetTimeCodesPerSecond(),
        s.GetFramesPerSecond(),
        int(s.HasAuthoredTimeCodeRange()),
    )
    rows("PATH", [p.GetPath() for p in s.Traverse()])
    rows(
        "EXPANDED",
        [p.GetPath() for p in Usd.PrimRange.Stage(s, Usd.TraverseInstanceProxies())],
    )
    rows("ALL", [p.GetPath() for p in s.TraverseAll()])
    rows("LOADABLE", sorted(s.FindLoadable()))
    rows("LOADED", sorted(s.GetLoadSet()))
    row("LAYERS", len(s.GetLayerStack()))
    row("PROTOTYPES", len(s.GetPrototypes()))
    i = s.GetPrimAtPath("/World/Instance")
    row(
        "INSTANCE",
        i.GetTypeName(),
        int(i.IsInstance()),
        int(i.IsLoaded()),
        int(i.HasPayload()),
        int(bool(i.GetPrototype())),
    )
    row("PROXY", int(p.IsInstanceProxy()), int(bool(p.GetPrimInPrototype())))
    rows("VSETS", w.GetVariantSets().GetNames())
    rows("VARIANTS", w.GetVariantSet("mode").GetVariantNames())
    row("CHOICE", w.GetVariantSet("mode").GetVariantSelection())
    row("TYPE", str(p.GetAttribute("points").GetTypeName()))
    rows("SAMPLE", p.GetAttribute("gain").GetTimeSamples())
    for j, v in enumerate(p.GetAttribute("textures").Get()):
        row(
            "ASSET",
            j,
            v.authoredPath,
            v.evaluatedPath or "EMPTY",
            v.resolvedPath or "EMPTY",
        )
    row("ANIMATED_ASSET", p.GetAttribute("texture").Get(5).authoredPath)
    rows("CONNECTION", w.GetAttribute("input").GetConnections())
    rows("NO_CONNECTION", w.GetAttribute("gain").GetConnections())
    rows("META_STAGE", sorted(s.GetPseudoRoot().GetAllMetadata()))
    rows("META_PRIM", sorted(w.GetAllMetadata()))
    rows("META_ATTR", sorted(w.GetAttribute("input").GetAllMetadata()))
    rows("KEY", sorted(w.GetMetadata("customData")))
    rows("NESTED_KEY", sorted(w.GetMetadataByDictKey("customData", "nested")))
    row("LEAF", "string", w.GetMetadataByDictKey("customData", "nested:label"))
    row("LAYER_LEAF", s.GetMetadataByDictKey("customLayerData", "revision"))
    row("DOC", w.GetAttribute("input").GetMetadata("documentation"))
    pv = UsdGeom.PrimvarsAPI(p).GetPrimvar("st")
    row(
        "PRIMVAR",
        pv.GetInterpolation(),
        pv.GetElementSize(),
        pv.GetUnauthoredValuesIndex(),
        len(pv.GetIndices()),
    )
    pv = UsdGeom.PrimvarsAPI(p).GetPrimvar("fallback")
    row(
        "FALLBACK",
        pv.GetInterpolation(),
        pv.GetElementSize(),
        pv.GetUnauthoredValuesIndex(),
    )
    row("NORMALS", UsdGeom.Mesh(p).GetNormalsInterpolation())
    s.Load("/World/Payload")
    rows("LOADED_AFTER", sorted(s.GetLoadSet()))
    row("PASS_INFO")
    actual = [tuple(line.split()) for line in output.splitlines()]
    assert len(actual) == len(expected), (actual, expected)
    for observed, wanted in zip(actual, expected, strict=True):
        assert len(observed) == len(wanted), (observed, wanted)
        for value, reference in zip(observed, wanted, strict=True):
            if isinstance(reference, (int, float)):
                assert abs(float(value) - reference) < 1e-8, (observed, wanted)
            else:
                assert value == reference, (observed, wanted)
    authored = Usd.Stage.Open(str(directory / "payload-authored.usda"))
    assert authored.GetRootLayer().GetPrimAtPath(
        "/Imported"
    ).payloadList.prependedItems[0].assetPath == str(asset)
    return {
        "sdk_comparison_rows": len(expected),
        "groups": [
            "resolved-assets-in-referenced-layer",
            "asset-arrays-and-time",
            "instances-prototypes-proxies",
            "payload-load-none-and-control",
            "variant-discovery",
            "stage-prim-attribute-metadata-and-dictionary-leaves",
            "connections",
            "time-range-and-samples",
            "primvar-element-size-unauthored-index-fallbacks",
            "composition-diagnostics",
            "payload-authoring",
        ],
    }
