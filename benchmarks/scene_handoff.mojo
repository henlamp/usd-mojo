# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Separate scene capture cost from repeated host matrix access."""
from std.sys import argv
from std.time import perf_counter_ns
from usd_mojo import Stage, SceneSnapshot


def main() raises:
    var stage = Stage(argv()[1])
    var repeats = Int(argv()[2])
    for i in range(repeats + 1):
        var start = perf_counter_ns()
        var scene = SceneSnapshot(stage)
        var captured = perf_counter_ns()
        var matrices = scene.transforms()
        var checksum = Float64(0)
        for j in range(len(matrices) // 16):
            checksum += (
                matrices[j * 16 + 12]
                + matrices[j * 16 + 13]
                + matrices[j * 16 + 14]
            )
        var consumed = perf_counter_ns()
        var paths = scene.paths()
        var prototypes = scene.prototypes()
        var instances = 0
        var first = String("")
        for prototype in prototypes:
            if prototype.byte_length() > 0:
                instances += 1
                if first.byte_length() == 0:
                    first = prototype
                elif first != prototype:
                    raise Error(
                        "Shared asset unexpectedly expanded into multiple"
                        " prototypes"
                    )
        if i > 0:
            print(
                "SAMPLE",
                Int64(captured - start),
                Int64(consumed - captured),
                len(paths),
                instances,
                checksum,
            )
