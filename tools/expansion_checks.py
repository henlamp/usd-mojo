"""Independent SDK fixtures/oracles for the development scene APIs."""
import json
import math
import subprocess
from pathlib import Path

from pxr import Gf, Sdf, Usd, UsdGeom, UsdShade, UsdSkel, UsdPhysics, UsdLux, UsdRender
from pipeline_check import check as check_pipeline
from skinning_check import check as check_skinning


def flatten(item):
    """Flatten SDK numeric/compound values without depending on bridge code."""
    if isinstance(item, Gf.Quatf | Gf.Quatd | Gf.Quath):
        return [item.GetReal(), *item.GetImaginary()]
    if isinstance(item, Sdf.AssetPath):
        return [item.path]
    if isinstance(item, Sdf.TimeCode):
        return [float(item)]
    if isinstance(item, str | int | float | bool):
        return [item]
    return [part for child in item for part in flatten(child)]


def fixture(directory: Path) -> Path:
    path = directory / "domains.usda"
    stage = Usd.Stage.CreateNew(str(path))
    world = UsdGeom.Xform.Define(stage, "/World")
    world.AddTranslateOp().Set((10, 0, 0))
    UsdGeom.PrimvarsAPI(world).CreatePrimvar("quality", Sdf.ValueTypeNames.Int, "constant").Set(7)
    cube = UsdGeom.Cube.Define(stage, "/World/Cube")
    cube.CreateSizeAttr(2)
    cube.AddTranslateOp().Set((1, 0, 0))
    UsdPhysics.RigidBodyAPI.Apply(cube.GetPrim())
    UsdPhysics.MassAPI.Apply(cube.GetPrim()).CreateMassAttr(3)
    UsdPhysics.CollisionAPI.Apply(cube.GetPrim())
    UsdPhysics.ArticulationRootAPI.Apply(world.GetPrim())
    joint = UsdPhysics.RevoluteJoint.Define(stage, "/World/Joint")
    joint.CreateBody1Rel().SetTargets([cube.GetPath()])
    UsdPhysics.DriveAPI.Apply(joint.GetPrim(), "angular").CreateStiffnessAttr(25)
    UsdPhysics.LimitAPI.Apply(joint.GetPrim(), "rotX").CreateLowAttr(-45)
    UsdPhysics.FilteredPairsAPI.Apply(cube.GetPrim()).CreateFilteredPairsRel().SetTargets([joint.GetPath()])
    for cls in (UsdPhysics.FixedJoint, UsdPhysics.PrismaticJoint, UsdPhysics.SphericalJoint,
                UsdPhysics.DistanceJoint, UsdPhysics.Joint, UsdPhysics.Scene):
        cls.Define(stage, "/World/Extra" + cls.__name__)
    for cls in (UsdGeom.Capsule, UsdGeom.Cone, UsdGeom.Cylinder, UsdGeom.Sphere, UsdGeom.Plane):
        cls.Define(stage, "/World/" + cls.__name__)
    group = UsdPhysics.CollisionGroup.Define(stage, "/World/CollisionGroup")
    collection = Usd.CollectionAPI.Apply(group.GetPrim(), "colliders")
    collection.CreateIncludesRel().SetTargets([cube.GetPath()])
    hidden = UsdGeom.Xform.Define(stage, "/World/Hidden")
    hidden.CreateVisibilityAttr("invisible")
    UsdGeom.Points.Define(stage, "/World/Hidden/Points").CreatePointsAttr([(0, 0, 0)])
    inst = UsdGeom.PointInstancer.Define(stage, "/World/Instances")
    proto = UsdGeom.Cube.Define(stage, "/World/Instances/Prototype")
    proto.AddTranslateOp().Set((5, 0, 0))
    inst.CreatePrototypesRel().SetTargets([proto.GetPath()])
    inst.CreateProtoIndicesAttr([0, 0])
    inst.CreatePositionsAttr([(1, 0, 0), (2, 0, 0)])
    inst.CreateIdsAttr([10, 20])
    inst.CreateInvisibleIdsAttr([20])
    curves = UsdGeom.BasisCurves.Define(stage, "/World/Curves")
    curves.CreatePointsAttr([(0, 0, 0), (1, 0, 0)])
    curves.CreateCurveVertexCountsAttr([2])
    curves.CreateTypeAttr("linear")
    curves.CreateWidthsAttr([0.1])
    nurbs = UsdGeom.NurbsCurves.Define(stage, "/World/Nurbs")
    nurbs.CreatePointsAttr([(0, 0, 0), (1, 0, 0)])
    nurbs.CreateCurveVertexCountsAttr([2])
    nurbs.CreateOrderAttr([2])
    nurbs.CreateKnotsAttr([0, 0, 1, 1])
    nurbs.CreateRangesAttr([(0, 1)])
    mesh = UsdGeom.Mesh.Define(stage, "/World/Mesh")
    mesh.CreatePointsAttr([(0, 0, 0), (1, 0, 0), (0, 1, 0)])
    mesh.CreateFaceVertexCountsAttr([3])
    mesh.CreateFaceVertexIndicesAttr([0, 1, 2])
    mesh.CreateSubdivisionSchemeAttr("catmullClark")
    subset = UsdGeom.Subset.Define(stage, "/World/Mesh/Faces")
    subset.CreateElementTypeAttr("face")
    subset.CreateIndicesAttr([0])
    subset.CreateFamilyNameAttr("materialBind")
    material = UsdShade.Material.Define(stage, "/World/Material")
    shader = UsdShade.Shader.Define(stage, "/World/Material/Surface")
    shader.CreateIdAttr("UsdPreviewSurface")
    shader.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set((0.2, 0.4, 0.8))
    material.CreateSurfaceOutput().ConnectToSource(shader.ConnectableAPI(), "surface")
    UsdShade.MaterialBindingAPI.Apply(mesh.GetPrim()).Bind(material)
    fallback = UsdShade.Material.Define(stage, "/World/Fallback")
    for terminal in ("surface", "displacement", "volume"):
        node = UsdShade.Shader.Define(stage, "/World/Fallback/" + terminal)
        node.CreateIdAttr("test:" + terminal)
        node.CreateOutput(terminal, Sdf.ValueTypeNames.Token)
        getattr(fallback, "Create" + terminal.capitalize() + "Output")().ConnectToSource(node.ConnectableAPI(), terminal)
    ri = UsdShade.Shader.Define(stage, "/World/Fallback/Ri")
    ri.CreateIdAttr("test:ri")
    ri.CreateOutput("surface", Sdf.ValueTypeNames.Token)
    fallback.CreateSurfaceOutput("ri").ConnectToSource(ri.ConnectableAPI(), "surface")
    fallback.CreateSurfaceOutput("empty")
    fallback.CreateSurfaceOutput("broken").GetAttr().SetConnections(["/Missing.outputs:surface"])
    graph = UsdShade.NodeGraph.Define(stage, "/World/Fallback/Graph")
    graph.CreateOutput("surface", Sdf.ValueTypeNames.Token).ConnectToSource(ri.ConnectableAPI(), "surface")
    fallback.CreateSurfaceOutput("graph").ConnectToSource(graph.ConnectableAPI(), "surface")
    a = UsdShade.NodeGraph.Define(stage, "/World/Fallback/A")
    b = UsdShade.NodeGraph.Define(stage, "/World/Fallback/B")
    a.CreateOutput("surface", Sdf.ValueTypeNames.Token).ConnectToSource(b.ConnectableAPI(), "surface")
    b.CreateOutput("surface", Sdf.ValueTypeNames.Token).ConnectToSource(a.ConnectableAPI(), "surface")
    fallback.CreateSurfaceOutput("cycle").ConnectToSource(a.ConnectableAPI(), "surface")
    light = UsdLux.RectLight.Define(stage, "/World/Light")
    light.CreateIntensityAttr(500)
    light.CreateWidthAttr(2)
    light.CreateHeightAttr(3)
    camera = UsdGeom.Camera.Define(stage, "/World/Camera")
    camera.AddTranslateOp().Set((0, 0, 10))
    render = UsdRender.Settings.Define(stage, "/World/Render")
    render.CreateCameraRel().SetTargets([camera.GetPath()])
    render.CreateResolutionAttr(Gf.Vec2i(640, 480))
    product = UsdRender.Product.Define(stage, "/World/Product")
    product.CreateProductNameAttr("render.exr")
    var = UsdRender.Var.Define(stage, "/World/Color")
    var.CreateSourceNameAttr("color")
    product.CreateOrderedVarsRel().SetTargets([var.GetPath()])
    render.CreateProductsRel().SetTargets([product.GetPath()])
    stage.SetMetadata("renderSettingsPrimPath", str(render.GetPath()))
    root = UsdSkel.Root.Define(stage, "/Rig")
    skeleton = UsdSkel.Skeleton.Define(stage, "/Rig/Skeleton")
    skeleton.CreateJointsAttr(["root", "root/child"])
    bind = [Gf.Matrix4d(1), Gf.Matrix4d(1).SetTranslate((0, 1, 0))]
    skeleton.CreateBindTransformsAttr(bind)
    skeleton.CreateRestTransformsAttr(bind)
    animation = UsdSkel.Animation.Define(stage, "/Rig/Animation")
    animation.CreateJointsAttr(["root", "root/child"])
    animation.CreateTranslationsAttr([(2, 0, 0), (0, 1, 0)])
    animation.CreateRotationsAttr([Gf.Quatf(1), Gf.Quatf(1)])
    animation.CreateScalesAttr([(1, 1, 1), (1, 1, 1)])
    animation.CreateBlendShapesAttr(["raise"])
    animation.CreateBlendShapeWeightsAttr([0.5])
    UsdSkel.BindingAPI.Apply(skeleton.GetPrim()).CreateAnimationSourceRel().SetTargets([animation.GetPath()])
    skin = UsdGeom.Mesh.Define(stage, "/Rig/Skin")
    skin.CreatePointsAttr([(0, 1, 0)])
    skin.CreateFaceVertexCountsAttr([])
    skin.CreateFaceVertexIndicesAttr([])
    binding = UsdSkel.BindingAPI.Apply(skin.GetPrim())
    binding.CreateSkeletonRel().SetTargets([skeleton.GetPath()])
    binding.CreateJointIndicesPrimvar(False, 1).Set([1])
    binding.CreateJointWeightsPrimvar(False, 1).Set([1.0])
    blend = UsdSkel.BlendShape.Define(stage, "/Rig/Raise")
    blend.CreateOffsetsAttr([(0, 2, 0)])
    blend.CreatePointIndicesAttr([0])
    inbetween = blend.CreateInbetween("half")
    inbetween.SetWeight(0.5)
    inbetween.SetOffsets([(0, 3, 0)])
    binding.CreateBlendShapesAttr(["raise"])
    binding.CreateBlendShapeTargetsRel().SetTargets([blend.GetPath()])
    mapped = UsdGeom.Mesh.Define(stage, "/Rig/SkinMapped")
    mapped.CreatePointsAttr([(0, 1, 0)])
    mapped.CreateFaceVertexCountsAttr([])
    mapped.CreateFaceVertexIndicesAttr([])
    mapped_binding = UsdSkel.BindingAPI.Apply(mapped.GetPrim())
    mapped_binding.CreateSkeletonRel().SetTargets([skeleton.GetPath()])
    mapped_binding.CreateJointsAttr(["root/child", "root"])
    mapped_binding.CreateJointIndicesPrimvar(False, 1).Set([0])
    mapped_binding.CreateJointWeightsPrimvar(False, 1).Set([1.0])
    mapped_binding.CreateGeomBindTransformAttr(Gf.Matrix4d(1).SetTranslate((0, 3, 0)))
    mapped_binding.CreateBlendShapesAttr(["raise"])
    mapped_binding.CreateBlendShapeTargetsRel().SetTargets([blend.GetPath()])
    stage.GetRootLayer().Save()
    # Clip data lives in a separate file; mapping stage time 5 to clip time 1.
    clip_path = directory / "clip.usda"
    clip = Usd.Stage.CreateNew(str(clip_path))
    prim = clip.DefinePrim("/Animated", "Xform")
    attr = prim.CreateAttribute("gain", Sdf.ValueTypeNames.Double)
    attr.Set(2.0, 0)
    attr.Set(6.0, 1)
    clip.GetRootLayer().Save()
    animated = stage.DefinePrim("/Animated", "Xform")
    animated.CreateAttribute("gain", Sdf.ValueTypeNames.Double)
    clips = Usd.ClipsAPI(animated)
    clips.SetClipAssetPaths([Sdf.AssetPath("clip.usda")])
    clips.SetClipPrimPath("/Animated")
    clips.SetClipActive([(0, 0)])
    clips.SetClipTimes([(0, 0), (5, 1)])
    stage.GetRootLayer().Save()
    return path


def check(directory: Path, compile_consumer, root: Path, imports: Path) -> dict:
    work = directory / "expansion"
    work.mkdir()
    (work / "assets").mkdir()
    (work / "assets/resolver-target.usda").write_text('#usda 1.0\ndef Xform "Model" {\n double gain = 42\n}\n')
    (work / "resolver-root.usda").write_text('#usda 1.0\ndef Xform "Model" (prepend references = @resolver-target.usda@</Model>) {}\n')
    # The editing test writes independent files. SDK verifies the persisted result,
    # which excludes the stronger anonymous session value 9.
    for name in ("editing", "composition"):
        binary = work / name
        compile_consumer(root / f"tests/{name}.mojo", binary, imports)
        subprocess.run([str(binary), str(work)], check=True)
    persisted = Usd.Stage.Open(str(work / "root.usda"))
    assert persisted.GetPrimAtPath("/World/Robot").GetAttribute("tuning").Get() == 3
    assert persisted.GetPrimAtPath("/World/RefCopy").GetAttribute("tuning").Get() == 3
    assert persisted.GetPrimAtPath("/World/Watcher").GetRelationship("watch").GetTargets() == []
    assert not persisted.GetPrimAtPath("/World/Moved")
    nested = persisted.GetPrimAtPath("/World").GetCustomDataByKey("nested")
    assert nested == {"unsigned": 2**64 - 1, "signed": -(2**63)}
    reference = persisted.GetRootLayer().GetPrimAtPath("/World/Timed").referenceList.prependedItems[0]
    assert reference.layerOffset == Sdf.LayerOffset(5, 2)
    arcs = Usd.Stage.Open(str(work / "arc-root.usda"))
    spec = arcs.GetRootLayer().GetPrimAtPath("/Ref")
    assert spec.referenceList.explicitItems[0].layerOffset == Sdf.LayerOffset(7, 2)
    assert not list(spec.variantSets.keys())
    assert arcs.GetPrimAtPath("/Payload").GetAttribute("tuning").Get() == 3
    assert arcs.GetPrimAtPath("/Derived").GetAttribute("gain").Get() == 8
    path = fixture(work)
    (work / "unresolved.usda").write_text('#usda 1.0\ndef Xform "Missing" (prepend references = @missing.usda@) {}\n')
    binary = work / "domains"
    compile_consumer(root / "tests/domains.mojo", binary, imports)
    result = subprocess.check_output([str(binary), str(path), str(work)], text=True)
    stage = Usd.Stage.Open(str(path))
    fallback = UsdShade.Material(stage.GetPrimAtPath("/World/Fallback"))
    for context in ("unknown", "empty", "broken", "cycle", "ri", "graph"):
        nodes = {line.split()[2] for line in result.splitlines() if line.startswith("GRAPH " + context + " ")}
        for terminal in ("surface", "displacement", "volume"):
            source = getattr(fallback, "Compute" + terminal.capitalize() + "Source")(context)[0]
            assert source and str(source.GetPath()) in nodes, (context, terminal, nodes)
        if context in {"ri", "graph"}:
            assert "/World/Fallback/surface" not in nodes, (context, nodes)
    checked = 0
    seen = set()
    for line in result.splitlines():
        if not line.startswith("VALUE "):
            continue
        _, prim, attribute, type_name, channel, index, observed = line.split()
        value = stage.GetPrimAtPath(prim).GetAttribute(attribute).Get()
        identity = (prim, attribute, int(index))
        assert identity not in seen, line
        seen.add(identity)
        expected = flatten(value)[int(index)]
        if channel == "T":
            assert observed == str(expected), line
        elif channel in {"I", "U"}:
            assert int(observed) == int(expected), line
        else:
            actual, reference = float(observed), float(expected)
            if math.isfinite(reference):
                assert abs(actual - reference) <= 1e-5 * max(1, abs(reference)), line
            else:
                assert actual == reference or math.isnan(actual) and math.isnan(reference), line
        assert type_name == str(stage.GetPrimAtPath(prim).GetAttribute(attribute).GetTypeName()), line
        checked += 1
    assert checked > 100, checked
    expected_keys = set()
    for prim in stage.Traverse():
        for attr in prim.GetAttributes():
            value = attr.Get()
            if value is not None:
                for index, component in enumerate(flatten(value)):
                    if component != "":
                        expected_keys.add((str(prim.GetPath()), str(attr.GetName()), index))
    assert seen == expected_keys, (expected_keys - seen, seen - expected_keys)
    package = Usd.Stage.Open(str(work / "scene.usdz"))
    assert package.GetPrimAtPath("/Rig/Skeleton")
    assert package.GetPrimAtPath("/Animated").GetAttribute("gain").Get(5) == 6
    frozen = Usd.Stage.Open(str(work / "frozen.usda"))
    assert frozen.GetPrimAtPath("/World/Cube").GetAttribute("size").Get() == 2
    assert stage.GetPrimAtPath("/World/Cube").GetAttribute("size").Get() == 2
    for name in ("changes", "expansion_errors"):
        binary = work / name
        compile_consumer(root / f"tests/{name}.mojo", binary, imports)
        subprocess.run([str(binary), str(work)], check=True)
    assert not (work / "unsaved.usdz").exists()
    assert not (work / "unresolved.usdz").exists()
    binary = work / "scene_handoff"
    compile_consumer(root / "examples/scene_handoff.mojo", binary, imports)
    output = subprocess.check_output([str(binary), str(path)], text=True)
    assert "JOINT /World/Joint /World/Cube 25.0" in output, output
    assert output.splitlines()[-1].split()[-3:] == ["1", "1", "3.0"], output
    return {"status": "passed", "sdk_value_components": checked, "editing_roundtrip": True, "usdz_roundtrip": True,
            "skinning": check_skinning(directory, compile_consumer, root, imports),
            "compound_pipeline": check_pipeline(directory, compile_consumer, root, imports)}


if __name__ == "__main__":
    from build import BUILD, ROOT, require_compile
    import tempfile
    directory = Path(tempfile.mkdtemp(prefix="expansion-", dir=BUILD))
    print("Evidence directory:", directory, flush=True)
    report = check(directory, require_compile, ROOT, ROOT / "src")
    (BUILD / "expansion-verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
