# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Freeze a scene once, then use CPU matrix views without revisiting USD."""
from std.sys import argv
from usd_mojo import Stage, SceneSnapshot, read_body, read_joint


def main() raises:
    var stage = Stage(argv()[1])
    var snapshot = SceneSnapshot(stage)
    var paths = snapshot.paths()
    var matrices = snapshot.transforms()
    var mass = Float64(0)
    var bodies = 0
    var joints = 0
    for path in paths:
        if stage.has_schema(path, "PhysicsRigidBodyAPI"):
            bodies += 1
            mass += read_body(stage, path).mass.mass
        if stage.prim_type(path) == "PhysicsRevoluteJoint":
            var joint = read_joint(stage, path)
            joints += 1
            print("JOINT", path, joint.body1, joint.drive.stiffness)
    print("SCENE", len(paths), len(matrices), bodies, joints, mass)
