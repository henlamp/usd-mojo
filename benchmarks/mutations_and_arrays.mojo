# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Compare mutation notification costs and distinct array ownership contracts."""
from std.sys import argv
from std.time import perf_counter_ns
from std.ffi import external_call
from usd_mojo import (
    Stage,
    Value,
    AttributeEdit,
    set_values,
    poll_changes,
    ArraySnapshot,
)


def main() raises:
    var args = argv()
    var opening = perf_counter_ns()
    var stage = Stage(args[1])
    print("OPEN", perf_counter_ns() - opening)
    var mode = args[2]
    if mode == "single" or mode == "batch":
        for round in range(4):
            var edits = List[AttributeEdit](capacity=2000)
            for i in range(2000):
                edits.append(
                    AttributeEdit(
                        "/Robot",
                        String("perf:a", i),
                        Value.floating("double", [Float64(round + i)]),
                        .default,
                    )
                )
            _ = poll_changes(stage)
            var generation = poll_changes(stage).generation
            var start = perf_counter_ns()
            if mode == "batch":
                set_values(stage, edits)
            else:
                for edit in edits:
                    stage.set_value(edit.path, edit.name, edit.value)
            var elapsed = perf_counter_ns() - start
            var notices = poll_changes(stage).generation - generation
            if stage.read_float("/Robot", "perf:a1999") != Float64(
                round + 1999
            ):
                raise Error("Mutation benchmark result differs")
            if round > 0:
                print("MUTATION", elapsed, notices)
            else:
                print("FIRST_MUTATION", elapsed, notices)
    else:
        var switching = perf_counter_ns()
        stage.select_variant("/Robot/Visual", "lod", "high")
        print("LOD", perf_counter_ns() - switching)
        var peak_before = external_call["usdm_test_peak_rss", Int64]()
        for round in range(4):
            var start = Int64(perf_counter_ns())
            var checksum = Float64(0)
            var captured: Int64
            var count: Int
            if mode == "native":
                var array = ArraySnapshot(
                    stage, "/Robot/Visual/Geometry", "points"
                )
                captured = Int64(perf_counter_ns())
                var view = array.view[DType.float32]()
                count = len(view)
                for value in view:
                    checksum += Float64(value)
            elif mode == "value":
                var value = stage.read_value("/Robot/Visual/Geometry", "points")
                captured = Int64(perf_counter_ns())
                count = len(value.numbers)
                for component in value.numbers:
                    checksum += component
            else:
                raise Error("Unknown benchmark mode")
            if round > 0:
                print("ARRAY", captured - start, count, checksum)
            else:
                print("FIRST_ARRAY", captured - start, count, checksum)
        print("RSS", peak_before, external_call["usdm_test_peak_rss", Int64]())
