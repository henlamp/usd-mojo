# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Independent snapshot ownership, read-only views and transactional caller buffers."""
from std.collections import List, MutSpan
from std.sys import argv
from std.testing import assert_equal, assert_true
from usd_mojo import MeshSnapshot, Stage, UsdError, UsdErrorKind, Value


def capture(filename: String) raises UsdError -> MeshSnapshot:
    var stage = Stage(filename)
    return stage.mesh_snapshot("/World/Robot/Triangle")


def main() raises:
    var args = argv()
    var detached = capture(args[1])
    assert_equal(detached.point_count(), 3)
    assert_equal(detached.points()[0], Float32(0))
    var stage = Stage(args[1])
    var snapshot = stage.mesh_snapshot("/World/Robot/Triangle")
    var before = snapshot.points()
    var replacement: List[Float64] = [42, 0, 0, 1, 0, 0, 0, 1, 0]
    stage.set_value(
        "/World/Robot/Triangle",
        "points",
        Value.floating("point3f[]", replacement^),
    )
    assert_equal(before[0], Float32(0))
    assert_equal(stage.mesh("/World/Robot/Triangle").points[0], Float32(42))
    var owned = snapshot.materialize()
    owned.points[0] = 99
    assert_equal(before[0], Float32(0))
    var points = List[Float32](length=9, fill=-7)
    var counts = List[Int32](length=1, fill=-7)
    var indices = List[Int32](length=3, fill=-7)
    snapshot.copy_into(MutSpan(points), MutSpan(counts), MutSpan(indices))
    assert_equal(points[0], Float32(0))
    assert_equal(counts[0], Int32(3))
    assert_equal(indices[2], Int32(2))
    var bad = List[Float32](length=1, fill=123)
    var rejected = False
    try:
        snapshot.copy_into(MutSpan(bad), MutSpan(counts), MutSpan(indices))
    except e:
        assert_equal(e.kind, UsdErrorKind.invalid_argument)
        rejected = True
    assert_true(rejected)
    assert_equal(bad[0], Float32(123))
    assert_equal(counts[0], Int32(3))
    assert_equal(indices[2], Int32(2))
    var empty = Stage(args[2], create=True)
    empty.define_prim("/Empty", "Mesh")
    empty.set_value(
        "/Empty", "points", Value.floating("point3f[]", List[Float64]())
    )
    empty.set_value(
        "/Empty", "faceVertexCounts", Value.signed("int[]", List[Int64]())
    )
    empty.set_value(
        "/Empty", "faceVertexIndices", Value.signed("int[]", List[Int64]())
    )
    var nothing = empty.mesh_snapshot("/Empty")
    assert_equal(len(nothing.points()), 0)
    assert_equal(len(nothing.face_vertex_counts()), 0)
    assert_equal(len(nothing.materialize().points), 0)
    var moved = detached^
    assert_equal(moved.face_count(), 1)
    print(
        "PASS independent snapshot, stage edits, disjoint reuse and empty views"
    )
