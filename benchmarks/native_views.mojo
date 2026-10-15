# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Validated owned copies, borrowed snapshot views and reused output buffers."""
from std.collections import List, MutSpan
from std.sys import argv
from std.time import perf_counter_ns
from usd_mojo import Stage


def main() raises:
    var args = argv()
    var stage = Stage(args[2])
    var repeats = Int(args[3])
    var initial = stage.mesh("/World/Mesh")
    var points = List[Float32](length=len(initial.points), fill=0)
    var counts = List[Int32](length=len(initial.face_vertex_counts), fill=0)
    var indices = List[Int32](length=len(initial.face_vertex_indices), fill=0)
    var total = Int64(0)
    var checksum = Float64(0)
    for i in range(repeats + 3):
        var start = perf_counter_ns()
        if args[1] == "owned":
            var data = stage.mesh("/World/Mesh")
            if i >= 3:
                total += Int64(perf_counter_ns() - start)
            for x in data.points:
                checksum += Float64(x)
            for x in data.face_vertex_counts:
                checksum += Float64(x)
            for x in data.face_vertex_indices:
                checksum += Float64(x)
        elif args[1] == "borrowed":
            var data = stage.mesh_snapshot("/World/Mesh")
            var p = data.points()
            var c = data.face_vertex_counts()
            var indices_view = data.face_vertex_indices()
            if i >= 3:
                total += Int64(perf_counter_ns() - start)
            for x in p:
                checksum += Float64(x)
            for x in c:
                checksum += Float64(x)
            for x in indices_view:
                checksum += Float64(x)
        elif args[1] == "reuse":
            var data = stage.mesh_snapshot("/World/Mesh")
            data.copy_into(MutSpan(points), MutSpan(counts), MutSpan(indices))
            if i >= 3:
                total += Int64(perf_counter_ns() - start)
            for x in points:
                checksum += Float64(x)
            for x in counts:
                checksum += Float64(x)
            for x in indices:
                checksum += Float64(x)
        else:
            raise Error("Unknown native benchmark operation")
    print(total, checksum)
