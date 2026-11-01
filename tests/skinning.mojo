# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
from std.sys import argv
from std.testing import assert_equal, assert_true
from usd_mojo import Stage, TimeCode, Value, UsdErrorKind, skinned_points


def main() raises:
    var args = argv()
    var stage = Stage(args[1])
    var time = TimeCode.default
    if args[2] != "default":
        time = TimeCode.at(Float64(args[2]))
    if args[3] == "invalid":
        var rejected = False
        try:
            var invalid = skinned_points(stage, "/Rig/Skeleton", "/Rig/Mesh", time)
            _ = invalid
        except error:
            assert_equal(error.kind, UsdErrorKind.invalid_data)
            rejected = True
        assert_true(rejected)
        stage.set_value("/Rig/Animation", "blendShapeWeights", Value.floating("float[]", [0.5]))
    var points = skinned_points(stage, "/Rig/Skeleton", "/Rig/Mesh", time)
    assert_equal(len(points.numbers), 9)
    for index in range(len(points.numbers)):
        print("POINT", index, points.numbers[index])
