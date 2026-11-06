# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Exercise independent owners repeatedly and bound post-warmup RSS growth."""
from std.ffi import external_call
from std.sys import argv
from std.testing import assert_true, assert_equal
from usd_mojo import (
    Stage,
    Layer,
    Metadata,
    SchemaSnapshot,
    SceneSnapshot,
    Value,
    ArraySnapshot,
    validate_stage,
    UsdErrorKind,
)


def capture(stage: Stage, invalid_strings: List[String]) raises:
    var layer = Layer(stage)
    var metadata = Metadata()
    var leaf = Metadata(Value.unsigned("uint64", [UInt64.MAX]))
    metadata.set("value", leaf)
    var child = Metadata(metadata, "value")
    assert_equal(child.value().unsigned_integers[0], UInt64.MAX)
    var schema = SchemaSnapshot(stage, "/World/Mesh")
    assert_equal(len(schema.value("points").numbers), 9)
    var snapshot = SceneSnapshot(stage)
    assert_equal(len(snapshot.transforms()), 32)
    assert_true(layer.content().byte_length() > 0)
    var array = ArraySnapshot(stage, "/World/Mesh", "points")
    assert_equal(len(array.view[DType.float32]()), 9)
    var report = validate_stage(
        stage, validators=[String("usd_mojo:MeshTopology")]
    )
    assert_true(report.is_valid())
    var rejected = False
    try:
        var invalid = Metadata(invalid_strings, kind="string")
        _ = invalid
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_argument)
        rejected = True
    assert_true(rejected)


def main() raises:
    var stage = Stage(argv()[1])
    # A failed second string must release the already copied 64 KiB prefix.
    var invalid_strings: List[String] = [String("x") * 65536, String("invalid\x00string")]
    for _ in range(100):
        capture(stage, invalid_strings)
    var before = external_call["usdm_test_peak_rss", Int64]()
    for _ in range(2000):
        capture(stage, invalid_strings)
    var after = external_call["usdm_test_peak_rss", Int64]()
    assert_true(before >= 0 and after >= before)
    assert_true(after - before < 32 * 1024 * 1024)
    print("PASS expansion owner lifetime", before, after)
