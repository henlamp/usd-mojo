# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Notice coalescing, overflow invalidation and snapshots after source close."""
from std.sys import argv
from std.testing import assert_true, assert_equal
from usd_mojo import (
    Stage,
    Layer,
    SceneSnapshot,
    poll_changes,
    Value,
    UsdErrorKind,
)


def retained(filename: String) raises -> SceneSnapshot:
    var stage = Stage(filename)
    return SceneSnapshot(stage)


def main() raises:
    var filename = String(argv()[1], "/changes.usda")
    var stage = Stage(filename, create=True)
    stage.define_prim("/World", "Xform")
    stage.set_value("/World", "value", Value.floating("double", [Float64(3)]))
    stage.save()
    var frozen = retained(filename)
    var before = poll_changes(stage)
    var layer = Layer(stage)
    # Source layer notices must invalidate the stage even without a Stage setter.
    layer.replace_content(
        '#usda 1.0\ndef Xform "World" {\n double value = 4\n}\n'
    )
    var changed = poll_changes(stage)
    assert_true(changed.generation > before.generation)
    assert_true(len(changed.resynced) + len(changed.changed) > 0)
    assert_equal(frozen.value("/World", "value").numbers[0], Float64(3))
    # A successful metadata preflight must be invalidated by an external edit.
    var known = SceneSnapshot(stage)
    assert_equal(known.value("/World", "value").numbers[0], Float64(4))
    layer.replace_content(
        '#usda 1.0\ndef Xform "World" (vendorFlag = "retained") {\n double'
        " value = 4\n}\n"
    )
    var rejected = False
    try:
        var unsupported = SceneSnapshot(stage)
        _ = unsupported
    except error:
        assert_equal(error.kind, UsdErrorKind.unsupported)
        rejected = True
    assert_true(rejected)
    layer.replace_content(
        '#usda 1.0\ndef Xform "World" {\n double value = 4\n}\n'
    )
    for i in range(8200):
        stage.define_prim(String("/World/P", i), "Scope")
    var overflow = poll_changes(stage)
    assert_true(overflow.all_dirty)
    assert_equal(len(overflow.changed) + len(overflow.resynced), 0)
    var cleared = poll_changes(stage)
    assert_true(not cleared.all_dirty)
    stage.define_prim("/World/AfterOverflow", "Scope")
    assert_true(len(poll_changes(stage).resynced) > 0)
    print(
        "PASS external layer notices, independent frozen scene, bounded"
        " overflow and recovery"
    )
