# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
from std.sys import argv
from std.time import perf_counter_ns
from usd_mojo import Stage


def main() raises:
    var args = argv()
    var repeats = Int(args[3])
    var total = Int64(0)
    var checksum = Float64(0)
    if args[1] == "open":
        for iteration in range(repeats + 3):
            var start = perf_counter_ns()
            var stage = Stage(args[2])
            if iteration >= 3:
                total += Int64(perf_counter_ns() - start)
            checksum += Float64(stage.meters_per_unit())
    else:
        var stage = Stage(args[2])
        for iteration in range(repeats + 3):
            var start = perf_counter_ns()
            if args[1] == "traverse":
                var paths = stage.prim_paths()
                if iteration >= 3:
                    total += Int64(perf_counter_ns() - start)
                checksum += Float64(len(paths))
                for path in paths:
                    checksum += Float64(path.byte_length())
            elif args[1] == "mesh":
                var mesh = stage.mesh("/World/Mesh")
                if iteration >= 3:
                    total += Int64(perf_counter_ns() - start)
                for value in mesh.points:
                    checksum += Float64(value)
                for value in mesh.face_vertex_counts:
                    checksum += Float64(value)
                for value in mesh.face_vertex_indices:
                    checksum += Float64(value)
            else:
                var value = stage.read_value("/World/Mesh", "points")
                if iteration >= 3:
                    total += Int64(perf_counter_ns() - start)
                for item in value.numbers:
                    checksum += item
    print(total, checksum)
