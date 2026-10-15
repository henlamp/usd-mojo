# SPDX-License-Identifier: MIT
"""Isolated C ABI parsing and snapshot lifetime checks, without Python interop."""
from std.collections import List
from std.ffi import external_call, c_int
from std.sys import argv
from std.testing import assert_true


struct Handles(Movable):
    var stage: UInt64
    var mesh: UInt64
    var value: UInt64
    var text: UInt64

    def __init__(out self):
        self.stage = 0
        self.mesh = 0
        self.value = 0
        self.text = 0

    def __deinit__(deinit self):
        if self.stage:
            external_call["usdm_stage_close", NoneType](self.stage)
        if self.mesh:
            external_call["usdm_mesh_close", NoneType](self.mesh)
        if self.value:
            external_call["usdm_value_close", NoneType](self.value)
        if self.text:
            external_call["usdm_text_close", NoneType](self.text)


def cycle(var filename: String) raises:
    var owner = Handles()
    owner.stage = external_call["usdm_stage_open", UInt64](
        filename.as_c_string_span(), c_int(0)
    )
    assert_true(owner.stage != 0, "stage")
    var path = String("/World/Mesh")
    var attribute = String("points")
    var empty = String("")
    owner.mesh = external_call["usdm_mesh_snapshot", UInt64](
        owner.stage, path.as_c_string_span(), Float64(0), c_int(1)
    )
    assert_true(owner.mesh != 0, "mesh")
    owner.value = external_call["usdm_value_read", UInt64](
        owner.stage,
        path.as_c_string_span(),
        attribute.as_c_string_span(),
        Float64(0),
        c_int(1),
    )
    assert_true(owner.value != 0, "value")
    owner.text = external_call["usdm_text_snapshot", UInt64](
        owner.stage,
        empty.as_c_string_span(),
        c_int(0),
        empty.as_c_string_span(),
        Float64(0),
        c_int(1),
    )
    assert_true(owner.text != 0, "text")
    external_call["usdm_stage_close", NoneType](owner.stage)
    owner.stage = 0
    # Owners destroy all three snapshots after their stage has closed.


def main() raises:
    var args = argv()
    if len(args) != 3:
        raise Error("MODE FIXTURE")
    if args[1] == "open":
        var stage = external_call["usdm_stage_open", UInt64](
            args[2].as_c_string_span(), c_int(0)
        )
        if stage:
            external_call["usdm_stage_close", NoneType](stage)
        print('{"opened":', "true" if stage else "false", "}")
        return
    assert_true(args[1] == "stress", "unknown mode")
    var samples = List[Int64]()
    for _ in range(6):
        for _ in range(200):
            cycle(args[2])
        var rss = external_call["usdm_test_peak_rss", Int64]()
        assert_true(rss > 0, "getrusage")
        samples.append(rss)
    var peak = samples[1]
    for i in range(2, len(samples)):
        peak = max(peak, samples[i])
    var growth = peak - samples[0]
    # A leaked 30k-point value per cycle exceeds this limit by far.
    assert_true(growth < 64 * 1024 * 1024, "native lifetime RSS growth")
    print('{"cycles":1200,"peak_rss_samples_bytes":[', end="")
    for i in range(len(samples)):
        if i:
            print(",", end="")
        print(samples[i], end="")
    print(
        '],"growth_after_warmup_bytes":',
        growth,
        (
            ',"growth_limit_bytes":67108864,"scope":"peak RSS; 200 warmup'
            " cycles then 1000 measured native open/read/snapshot/close"
            ' cycles"}'
        ),
    )
