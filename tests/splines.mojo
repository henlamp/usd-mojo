# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
from std.sys import argv
from std.testing import assert_equal, assert_true
from usd_mojo import Stage, Spline, SplineKnot, Metadata, Value, TimeCode


def detached(filename: String) raises -> Spline:
    var stage = Stage(filename)
    return Spline(stage, "/Animation", "curve_double")


def main() raises:
    var args = argv()
    var input = Stage(args[1])
    var output = Stage(args[2], create=True)
    output.define_prim("/Animation")
    for kind in [String("double"), String("float"), String("half"), String("timecode")]:
        var original = Spline(input, "/Animation", String("curve_", kind))
        var copied = Spline(original)
        copied.author(output, "/Animation", String("curve_", kind))
        for i in range(33):
            var time = Float64(i - 8) / 8
            for mode in [
                String("value"),
                String("pre_value"),
                String("derivative"),
                String("held"),
            ]:
                print("SAMPLE", kind, time, mode, copied.evaluate(time, mode=mode))
        var edited = Spline(kind)
        edited.set_knot(SplineKnot(0, 0, interpolation="linear"))
        edited.set_knot(SplineKnot(1, 2, interpolation="held"))
        assert_equal(edited.evaluate(0.5), Float64(1))
        assert_equal(edited.knot(0).value, Float64(0))
        edited.set_extrapolation("sloped", slope=3)
        assert_equal(edited.evaluate(2), Float64(5))
        var metadata = Metadata()
        var label = Metadata(Value.text("string", [String("retained")]))
        metadata.set("label", label)
        edited.set_knot_metadata(0, metadata)
        edited.set_knot(SplineKnot(0, 1, interpolation="linear"))
        var held_metadata = edited.knot_metadata(0)
        assert_equal(
            Metadata(held_metadata, "label").value().texts[0], String("retained")
        )
        var before = edited.evaluate(0.5)
        var rejected = False
        try:
            edited.set_knot(SplineKnot(0, 9, pre_width=-1))
        except:
            rejected = True
        assert_true(rejected)
        assert_equal(edited.evaluate(0.5), before)
        edited.set_inner_loop(0, 1, after=2, offset=1)
        assert_equal(edited.inner_loop().after, 2)
        edited.set_inner_loop(0, 0)
        edited.author(output, "/Animation", String("authored_", kind))
        copied.remove_knot(1)
        assert_equal(len(original.knot_times()), 3)
    var hermite = Spline("double", curve="hermite")
    hermite.set_knot(SplineKnot(0, 0, post_slope=1))
    hermite.set_knot(SplineKnot(1, 1, pre_slope=1))
    assert_equal(hermite.evaluate(0.5), Float64(0.5))
    hermite.author(output, "/Animation", "hermite")
    var held = detached(args[1])
    assert_equal(held.evaluate(0), Float64(0))
    var moved = held^
    assert_equal(moved.evaluate(1), Float64(2))
    output.save()
    output.export(args[3])
    print("PASS owned splines, metadata, edits, preflight, loops and typed evaluation")
