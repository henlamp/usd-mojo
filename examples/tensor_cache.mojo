# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Prepare a coordinate-major USD mesh cache using three independent libraries."""
from std.collections import List, Span
from std.sys import argv
from axisweave import plan, execute_into
from filelock_mojo import atomic_write, locked_read
from usd_mojo import Stage


def main() raises:
    var args = argv()
    if len(args) != 4:
        raise Error("tensor_cache SCENE MESH_PATH CACHE")
    var stage = Stage(args[1])
    var snapshot = stage.mesh_snapshot(args[2])
    var shape: List[Int] = [snapshot.point_count(), 3]
    var recipe = plan("point coordinate -> coordinate point", Span(shape))
    var coordinates = List[Float32](length=len(snapshot.points()), fill=0)
    execute_into(recipe, snapshot.points(), Span(coordinates))
    var text = String("USD-MESH-TENSOR-1 ", snapshot.point_count(), "\n")
    for value in coordinates:
        text += String(value, "\n")
    atomic_write(args[3], text)
    if locked_read(args[3], max_bytes=67108864) != text:
        raise Error("Tensor cache differs after publication")
    print(snapshot.point_count(), snapshot.face_count(), len(coordinates))
