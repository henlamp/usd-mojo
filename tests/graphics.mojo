# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
from std.sys import argv
from std.testing import assert_equal, assert_true
from usd_mojo import Stage, read_primvar, read_normals, read_camera


def main() raises:
    var args = argv()
    var stage = Stage(args[1])
    var uv = read_primvar(stage, "/World/Mesh", "st")
    assert_equal(uv.values.type_name, "texCoord2f[]")
    assert_equal(len(uv.values.numbers), 6)
    assert_equal(len(uv.indices), 3)
    assert_equal(uv.interpolation, "faceVarying")
    assert_equal(uv.values.numbers[2], 1.0)
    var normals = read_normals(stage, "/World/Mesh")
    assert_equal(normals.interpolation, "vertex")
    assert_equal(normals.values.numbers[2], 1.0)
    assert_equal(stage.material_path("/World/Mesh"), "/World/Material")
    var camera = read_camera(stage, "/World/Camera")
    assert_equal(camera.projection, "perspective")
    assert_equal(camera.focal_length, 35.0)
    assert_equal(len(camera.clipping_range), 2)
    assert_true(abs(camera.clipping_range[0] - 0.1) < 1e-6)
    assert_equal(camera.world_matrix[14], 5.0)
    stage.apply_schema("/World/Mesh", "PhysicsCollisionAPI")
    assert_true(stage.has_schema("/World/Mesh", "PhysicsCollisionAPI"))
    stage.apply_schema("/World/Mesh", "PhysicsRigidBodyAPI")
    stage.apply_schema("/World/Mesh", "PhysicsDriveAPI", "angular")
    assert_true(stage.has_schema("/World/Mesh", "PhysicsDriveAPI:angular"))
    var failed = False
    try:
        stage.apply_schema("/World/Mesh", "MissingAPI")
    except:
        failed = True
    assert_true(failed)
    print(
        "PASS owned UVs, normals, inherited visual materials, camera,"
        " single/multiple API schemas"
    )
