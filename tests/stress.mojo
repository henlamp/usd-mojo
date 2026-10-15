# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
from std.sys import argv
from std.testing import assert_equal, assert_true
from usd_mojo import Stage, Value, MeshData


def detached(filename: String) raises -> MeshData:
    var stage = Stage(filename)
    return stage.mesh("/World/Mesh")


def main() raises:
    var args = argv()
    var copy = detached(args[1])
    assert_equal(copy.point_count(), 300000)
    assert_equal(copy.points[len(copy.points) - 1], Float32(2))
    for _ in range(100):
        var stage = Stage(args[1])
        var data = stage.read_value("/World/Mesh", "points")
        assert_equal(len(data.numbers), 900000)
        assert_equal(data.numbers[3], Float64(1))
        var mesh = stage.mesh("/World/Mesh")
        assert_equal(mesh.face_vertex_indices[299999], Int32(299999))
    var stage = Stage(args[1])
    var bad = False
    try:
        _ = stage.prim_type("/World\x00/Mesh")
    except:
        bad = True
    assert_true(bad)
    print(
        "PASS 300k points, 100 read/close cycles, detached mesh, NUL rejection"
    )
