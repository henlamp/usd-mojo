"""Author the acceptance scenes through the independent official SDK API."""

import math
from pathlib import Path

from pxr import Gf, Sdf, Usd, UsdGeom, UsdPhysics, UsdShade

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "tests" / "fixtures"


def root(name: str, units: float = 1, kilograms: float = 1, up: str = "Z"):
    stage = Usd.Stage.CreateNew(str(TARGET / name))
    UsdGeom.SetStageMetersPerUnit(stage, units)
    UsdPhysics.SetStageKilogramsPerUnit(stage, kilograms)
    UsdGeom.SetStageUpAxis(stage, up)
    stage.SetTimeCodesPerSecond(60)
    world = UsdGeom.Xform.Define(stage, "/World")
    stage.SetDefaultPrim(world.GetPrim())
    scene = UsdPhysics.Scene.Define(stage, "/World/Physics")
    scene.CreateGravityDirectionAttr(
        Gf.Vec3f(0, 0, -1) if up == "Z" else Gf.Vec3f(0, -1, 0)
    )
    scene.CreateGravityMagnitudeAttr(9.81 / units)
    material = UsdShade.Material.Define(stage, "/World/Material")
    physics = UsdPhysics.MaterialAPI.Apply(material.GetPrim())
    physics.CreateStaticFrictionAttr(0.6)
    physics.CreateDynamicFrictionAttr(0.6)
    physics.CreateRestitutionAttr(0)
    UsdShade.MaterialBindingAPI.Apply(world.GetPrim()).Bind(
        material, materialPurpose="physics"
    )
    ground = UsdGeom.Cube.Define(stage, "/World/Ground")
    ground.AddTranslateOp().Set(
        Gf.Vec3d(0, 0, -0.1 / units) if up == "Z" else Gf.Vec3d(0, -0.1 / units, 0)
    )
    ground.AddScaleOp().Set(
        Gf.Vec3f(5 / units, 5 / units, 0.1 / units)
        if up == "Z"
        else Gf.Vec3f(5 / units, 0.1 / units, 5 / units)
    )
    UsdPhysics.CollisionAPI.Apply(ground.GetPrim())
    return stage


def body(stage, path, position, half_sizes, mass):
    item = UsdGeom.Xform.Define(stage, path)
    item.AddTranslateOp().Set(Gf.Vec3d(*position))
    UsdPhysics.RigidBodyAPI.Apply(item.GetPrim())
    UsdPhysics.MassAPI.Apply(item.GetPrim()).CreateMassAttr(mass)
    shape = UsdGeom.Cube.Define(stage, path + "/Collider")
    shape.AddScaleOp().Set(Gf.Vec3f(*half_sizes))
    UsdPhysics.CollisionAPI.Apply(shape.GetPrim())
    return item


def main():
    stage = root("physics_box.usda")
    item = body(stage, "/World/Box", (0, 0, 2), (0.25, 0.25, 0.25), 1)
    prim = item.GetPrim()
    for name, kind, value in (
        ("weights", Sdf.ValueTypeNames.FloatArray, [0.25, 0.5, 0.75]),
        ("indices", Sdf.ValueTypeNames.IntArray, [1, -2, 3]),
        ("offset", Sdf.ValueTypeNames.Double3, Gf.Vec3d(1, 2, 3)),
        ("orientation", Sdf.ValueTypeNames.Quatd, Gf.Quatd(1, Gf.Vec3d(0))),
        (
            "directions",
            Sdf.ValueTypeNames.Vector3fArray,
            [Gf.Vec3f(1, 0, 0), Gf.Vec3f(0, 1, 0)],
        ),
        ("matrix", Sdf.ValueTypeNames.Matrix4d, Gf.Matrix4d(1)),
    ):
        prim.CreateAttribute(name, kind).Set(value)
    fixed = UsdPhysics.FixedJoint.Define(stage, "/World/DisabledFixed")
    fixed.CreateJointEnabledAttr(False)
    fixed.CreateBody1Rel().SetTargets(["/World/Box"])
    stage.GetRootLayer().Save()

    stage = root("physics_chain.usda")
    body(stage, "/World/Arm0", (0, 0, 1.5), (0.12, 0.12, 0.5), 1)
    body(stage, "/World/Arm1", (0, 0, 0.5), (0.12, 0.12, 0.5), 1)
    for name, parent, child, p0, p1, limit, damping, velocity in (
        ("Shoulder", None, "/World/Arm0", (0, 0, 2), (0, 0, 0.5), 45, 100, 1),
        ("Elbow", "/World/Arm0", "/World/Arm1", (0, 0, -0.5), (0, 0, 0.5), 70, 2, 0),
    ):
        joint = UsdPhysics.RevoluteJoint.Define(stage, "/World/" + name)
        if parent:
            joint.CreateBody0Rel().SetTargets([parent])
        joint.CreateBody1Rel().SetTargets([child])
        joint.CreateLocalPos0Attr(Gf.Vec3f(*p0))
        joint.CreateLocalPos1Attr(Gf.Vec3f(*p1))
        joint.CreateAxisAttr("Y")
        joint.CreateLowerLimitAttr(-limit)
        joint.CreateUpperLimitAttr(limit)
        drive = UsdPhysics.DriveAPI.Apply(joint.GetPrim(), "angular")
        drive.CreateTypeAttr("force")
        drive.CreateDampingAttr(damping * math.pi / 180)
        drive.CreateStiffnessAttr(0)
        drive.CreateMaxForceAttr(20)
        drive.CreateTargetVelocityAttr(velocity * 180 / math.pi)
    stage.GetRootLayer().Save()

    asset = Usd.Stage.CreateNew(str(TARGET / "physics_units_asset.usda"))
    UsdGeom.SetStageMetersPerUnit(asset, 0.01)
    UsdPhysics.SetStageKilogramsPerUnit(asset, 0.001)
    UsdGeom.SetStageUpAxis(asset, "Y")
    asset.SetTimeCodesPerSecond(24)
    asset_root = UsdGeom.Xform.Define(asset, "/Asset")
    asset.SetDefaultPrim(asset_root.GetPrim())
    body(asset, "/Asset/Box", (0, 200, 0), (25, 25, 25), 1000)
    asset.GetRootLayer().Save()
    stage = root("physics_units.usda", 0.01, 0.001, "Y")
    reference = UsdGeom.Xform.Define(stage, "/World/Referenced")
    reference.GetPrim().GetReferences().AddReference(
        "physics_units_asset.usda", "/Asset"
    )
    stage.GetRootLayer().Save()


if __name__ == "__main__":
    main()
