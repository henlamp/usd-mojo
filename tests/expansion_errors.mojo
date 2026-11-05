# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Errors before publication, invalid instance data and namespace preflight."""
from std.sys import argv
from std.testing import assert_true, assert_equal
from usd_mojo import (
    Stage,
    Layer,
    Value,
    instance_transforms,
    NamespaceEditor,
    export_usdz,
    dependencies,
    UsdErrorKind,
)


def main() raises:
    var directory = argv()[1]
    var stage = Stage(String(directory, "/domains.usda"))
    var rejected = False
    try:
        var invalid = instance_transforms(stage, "/World/Cube")
        _ = invalid
    except error:
        assert_equal(error.kind, UsdErrorKind.type_mismatch)
        rejected = True
    assert_true(rejected)
    stage.set_value(
        "/World/Instances",
        "protoIndices",
        Value.signed("int[]", [Int64(99), Int64(0)]),
    )
    rejected = False
    try:
        var invalid = instance_transforms(stage, "/World/Instances")
        _ = invalid
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_data)
        rejected = True
    assert_true(rejected)
    rejected = False
    try:
        export_usdz(stage, String(directory, "/unsaved.usdz"))
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_argument)
        rejected = True
    assert_true(rejected)
    var root = Layer(stage)
    var before = root.content()
    var editor = NamespaceEditor(stage)
    editor.move_prim("/World", "/World/Inside")
    assert_true(not editor.check().can_apply())
    rejected = False
    try:
        editor.apply()
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_argument)
        rejected = True
    assert_true(rejected)
    assert_equal(root.content(), before)
    var missing = Stage(String(directory, "/unresolved.usda"))
    var reported = False
    for item in dependencies(missing):
        if item.kind == "unresolved":
            reported = True
    assert_true(reported)
    rejected = False
    try:
        export_usdz(missing, String(directory, "/unresolved.usdz"))
    except error:
        assert_equal(error.kind, UsdErrorKind.not_found)
        rejected = True
    assert_true(rejected)
    assert_true(stage.prim_type("/World/Cube") == "Cube")
    print(
        "PASS invalid instancer data, namespace preflight, dirty/unresolved"
        " package rejection and recovery"
    )
