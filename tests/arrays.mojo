# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Exact component dtypes, independent ownership and explicit unsupported layouts."""
from std.sys import argv
from std.collections import ImmSpan
from std.testing import assert_equal, assert_true
from usd_mojo import Stage, Value, ArraySnapshot, set_array, UsdErrorKind, Layer


def main() raises:
    var stage = Stage(String(argv()[1], "/arrays.usda"), create=True)
    stage.define_prim("/Data", "Scope")
    stage.set_value("/Data", "u64", Value.unsigned("uint64[]", [UInt64.MAX]))
    stage.set_value("/Data", "i64", Value.signed("int64[]", [Int64.MIN]))
    stage.set_value(
        "/Data",
        "half",
        Value.floating("half3[]", [Float64(0.5), Float64(1), Float64(-2)]),
    )
    stage.set_value(
        "/Data",
        "matrix",
        Value.floating(
            "matrix2d[]", [Float64(1), Float64(2), Float64(3), Float64(4)]
        ),
    )
    stage.set_value(
        "/Data", "empty", Value.floating("float[]", List[Float64]())
    )
    stage.set_value(
        "/Data", "text", Value.text("string[]", [String("unsupported")])
    )
    stage.set_value(
        "/Data", "bytes", Value.unsigned("uchar[]", [UInt64(0), UInt64(255)])
    )
    stage.set_value(
        "/Data", "bools", Value.unsigned("bool[]", [UInt64(0), UInt64(1)])
    )
    stage.set_value(
        "/Data",
        "ints",
        Value.signed("int3[]", [Int64(Int32.MIN), Int64(0), Int64(Int32.MAX)]),
    )
    stage.set_value(
        "/Data", "uints", Value.unsigned("uint[]", [UInt64(UInt32.MAX)])
    )
    var unsigned = ArraySnapshot(stage, "/Data", "u64")
    var signed = ArraySnapshot(stage, "/Data", "i64")
    var half = ArraySnapshot(stage, "/Data", "half")
    var matrix = ArraySnapshot(stage, "/Data", "matrix")
    var empty = ArraySnapshot(stage, "/Data", "empty")
    assert_equal(unsigned.view[DType.uint64]()[0], UInt64.MAX)
    assert_equal(signed.view[DType.int64]()[0], Int64.MIN)
    assert_equal(half.view[DType.float16]()[2], Float16(-2))
    assert_equal(matrix.view[DType.float64]()[2], Float64(3))
    assert_equal(len(empty.view[DType.float32]()), 0)
    var bytes = ArraySnapshot(stage, "/Data", "bytes")
    var bools = ArraySnapshot(stage, "/Data", "bools")
    var ints = ArraySnapshot(stage, "/Data", "ints")
    var uints = ArraySnapshot(stage, "/Data", "uints")
    assert_equal(bytes.view[DType.uint8]()[1], UInt8(255))
    assert_equal(bools.view[DType.uint8]()[1], UInt8(1))
    assert_equal(ints.view[DType.int32]()[2], Int32.MAX)
    assert_equal(uints.view[DType.uint32]()[0], UInt32.MAX)
    set_array(
        stage, "/Data", "u64copy", "uint64[]", unsigned.view[DType.uint64]()
    )
    assert_equal(
        ArraySnapshot(stage, "/Data", "u64copy").view[DType.uint64]()[0],
        UInt64.MAX,
    )
    var source: List[Float32] = [1, 2, 3, 4, 5, 6]
    set_array(stage, "/Data", "native", "point3f[]", ImmSpan(source))
    source[0] = 99
    var native = ArraySnapshot(stage, "/Data", "native")
    assert_equal(native.element_count, 2)
    assert_equal(native.view[DType.float32]()[0], Float32(1))
    var root = Layer(stage)
    var before = root.content()
    var invalid_bool: List[UInt8] = [2]
    var invalid_components: List[Float32] = [1, 2]
    var rejected_input = False
    try:
        set_array(stage, "/Data", "invalid", "bool[]", ImmSpan(invalid_bool))
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_argument)
        rejected_input = True
    assert_true(rejected_input)
    rejected_input = False
    try:
        set_array(
            stage, "/Data", "invalid", "point3f[]", ImmSpan(invalid_components)
        )
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_argument)
        rejected_input = True
    assert_true(rejected_input)
    assert_equal(root.content(), before)
    stage.set_value("/Data", "u64", Value.unsigned("uint64[]", [UInt64(0)]))
    assert_equal(unsigned.view[DType.uint64]()[0], UInt64.MAX)
    var rejected = False
    try:
        var bad = ArraySnapshot(stage, "/Data", "text")
        _ = bad
    except error:
        assert_equal(error.kind, UsdErrorKind.unsupported)
        rejected = True
    assert_true(rejected)
    stage.save()
    print(
        "PASS exact array dtypes, half/vector/matrix layouts, empty arrays and"
        " source mutations"
    )
