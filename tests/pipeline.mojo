# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
from std.sys import argv
from std.testing import assert_equal, assert_true
from usd_mojo import Stage, TimeCode, override_prim, export_usdz, read_primvar, read_normals


def main() raises:
    var args = argv()
    var stage = Stage(args[1])
    assert_equal(stage.read_float("/Robot", "gain"), Float64(13))
    stage.select_variant("/Robot", "lod", "low")
    assert_equal(stage.mesh("/Robot/Mesh").point_count(), 3)
    stage.set_payload_loaded("/Robot/Mesh", False)
    assert_true(not stage.prim_info("/Robot/Mesh").loaded)
    stage.set_payload_loaded("/Robot/Mesh", True)
    assert_equal(stage.mesh("/Robot/Mesh").point_count(), 3)
    stage.select_variant("/Robot", "lod", "high")
    assert_equal(stage.mesh("/Robot/Mesh").point_count(), 6)
    var times = stage.time_samples("/Robot/Mesh", "points")
    var expected_times: List[Float64] = [2.5, 4.5]
    assert_equal(times, expected_times)
    for frame in range(3):
        var time = Float64(2.5) + Float64(frame)
        var mesh = stage.mesh("/Robot/Mesh", TimeCode.at(time))
        for i in range(mesh.point_count()):
            for c in range(3):
                print("POINT", time, i, c, mesh.points[i * 3 + c])
    var uv = read_primvar(stage, "/Robot/Mesh", "st")
    assert_equal(uv.interpolation, "faceVarying")
    assert_equal(len(uv.indices), 6)
    assert_equal(read_normals(stage, "/Robot/Mesh").interpolation, "faceVarying")
    override_prim(stage, "/Robot/Mesh")
    uv.values.numbers[0] = 0.25
    stage.set_value("/Robot/Mesh", "primvars:st", uv.values)
    stage.set_float("/Robot", "gain", 21)
    assert_equal(stage.read_float("/Robot", "gain"), Float64(21))
    stage.save()
    stage.export(args[2])
    export_usdz(stage, args[3])
