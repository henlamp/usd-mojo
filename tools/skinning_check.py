"""Compare neutral, animated and sparse blend shapes with SDK skinning bake."""

import math
import subprocess

from pxr import Gf, Sdf, Usd, UsdGeom, UsdSkel


VALID = ("rest", "joints", "order_only", "blocked", "zero", "active", "sparse", "empty", "sampled", "sampled_default", "blocked_sample")
INVALID = ("wrong_length", "empty_mismatch", "nan", "infinity")


def fixture(path, mode):
    stage = Usd.Stage.CreateNew(str(path))
    UsdSkel.Root.Define(stage, "/Rig")
    skeleton = UsdSkel.Skeleton.Define(stage, "/Rig/Skeleton")
    skeleton.CreateJointsAttr(["root"])
    skeleton.CreateRestTransformsAttr([Gf.Matrix4d(1)])
    skeleton.CreateBindTransformsAttr([Gf.Matrix4d(1)])
    mesh = UsdGeom.Mesh.Define(stage, "/Rig/Mesh")
    mesh.CreatePointsAttr([(0, 0, 0), (1, 0, 0), (0, 1, 0)])
    mesh.CreateFaceVertexCountsAttr([3])
    mesh.CreateFaceVertexIndicesAttr([0, 1, 2])
    binding = UsdSkel.BindingAPI.Apply(mesh.GetPrim())
    binding.CreateSkeletonRel().SetTargets([skeleton.GetPath()])
    binding.CreateJointIndicesPrimvar(False, 1).Set([0, 0, 0])
    binding.CreateJointWeightsPrimvar(False, 1).Set([1, 1, 1])
    shape = UsdSkel.BlendShape.Define(stage, "/Rig/Smile")
    shape.CreateOffsetsAttr([(0, 0, 2)])
    shape.CreatePointIndicesAttr([0])
    names, targets = ["smile"], [shape.GetPath()]
    if mode == "sparse":
        extra = UsdSkel.BlendShape.Define(stage, "/Rig/Unused")
        extra.CreateOffsetsAttr([(0, 5, 0)])
        extra.CreatePointIndicesAttr([1])
        names.append("unused")
        targets.append(extra.GetPath())
    binding.CreateBlendShapesAttr(names)
    binding.CreateBlendShapeTargetsRel().SetTargets(targets)
    if mode != "rest":
        animation = UsdSkel.Animation.Define(stage, "/Rig/Animation")
        animation.CreateJointsAttr(["root"])
        animation.CreateTranslationsAttr([(2, 0, 0)])
        animation.CreateRotationsAttr([Gf.Quatf(1)])
        animation.CreateScalesAttr([(1, 1, 1)])
        UsdSkel.BindingAPI.Apply(skeleton.GetPrim()).CreateAnimationSourceRel().SetTargets([animation.GetPath()])
        if mode != "joints":
            animation.CreateBlendShapesAttr([] if mode == "empty" else ["smile"])
        if mode not in ("joints", "order_only"):
            weights = animation.CreateBlendShapeWeightsAttr()
            if mode == "blocked":
                weights.Block()
            elif mode in ("sampled", "sampled_default", "blocked_sample"):
                weights.Set([0], 1)
                weights.Set([1], 3)
                if mode == "blocked_sample":
                    weights.Set(Sdf.ValueBlock(), 2)
            else:
                weights.Set({
                    "zero": [0], "active": [0.5], "sparse": [0.5],
                    "empty": [], "wrong_length": [0.5, 0.2],
                    "empty_mismatch": [], "nan": [float("nan")],
                    "infinity": [float("inf")],
                }[mode])
    stage.GetRootLayer().Save()


def check(directory, compile_consumer, root, imports):
    work = directory / "skinning"
    work.mkdir()
    binary = work / "skinning"
    compile_consumer(root / "tests/skinning.mojo", binary, imports)
    components, samples = 0, 0
    for mode in (*VALID, *INVALID):
        path = work / (mode + ".usda")
        fixture(path, mode)
        original = path.read_bytes()
        times = (1, 2, 3) if mode in ("sampled", "blocked_sample") else (None,)
        for time in times:
            label = "default" if time is None else str(time)
            tc = Usd.TimeCode.Default() if time is None else Usd.TimeCode(time)
            reference_path = work / (mode + "-reference-" + label + ".usda")
            reference_path.write_bytes(original)
            reference = Usd.Stage.Open(str(reference_path))
            weights = reference.GetPrimAtPath("/Rig/Animation").GetAttribute("blendShapeWeights") if mode != "rest" else None
            if mode in INVALID:
                weights.Set([0.5])
            elif weights and weights.Get(tc) is None:
                # Resolved absence must equal the same rig with unanimated shapes.
                # Bake that neutral reference independently of the bridge.
                weights.Clear()
            assert UsdSkel.BakeSkinning(UsdSkel.Root(reference.GetPrimAtPath("/Rig"))), (mode, label)
            points = reference.GetPrimAtPath("/Rig/Mesh").GetAttribute("points")
            result = subprocess.run(
                [str(binary), str(path), label, "invalid" if mode in INVALID else "valid"],
                capture_output=True, text=True, check=True,
            )
            (work / (mode + "-" + label + ".log")).write_text(result.stdout + result.stderr)
            actual = [float(line.split()[2]) for line in result.stdout.splitlines() if line.startswith("POINT ")]
            expected = [float(c) for p in points.Get(tc) for c in p]
            assert len(actual) == len(expected) == 9, (mode, label, actual)
            assert all(math.isclose(a, b, rel_tol=1e-6, abs_tol=1e-6) for a, b in zip(actual, expected)), (mode, label, actual, expected)
            components += len(actual)
            samples += 1
        assert path.read_bytes() == original, mode
    return {"status": "passed", "neutral_and_animated_cases": list(VALID),
            "invalid_weight_cases": list(INVALID), "sdk_samples": samples,
            "sdk_point_components": components, "source_files_unchanged": True}
