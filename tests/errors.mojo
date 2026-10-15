# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Consumers recover from failures by category, without parsing messages."""
from std.sys import argv
from std.testing import assert_equal, assert_true
from usd_mojo import Stage, TimeCode, UsdError, UsdErrorKind


def main() raises:
    var args = argv()
    var stage = Stage(args[1])
    var rejected = False
    try:
        _ = stage.prim_type("relative/path")
    except e:
        assert_equal(e.kind, UsdErrorKind.invalid_argument)
        rejected = True
    assert_true(rejected)
    rejected = False
    try:
        _ = stage.prim_type("/Missing")
    except e:
        assert_equal(e.kind, UsdErrorKind.not_found)
        assert_true(e.message.byte_length() > 0)
        rejected = True
    assert_true(rejected)
    rejected = False
    try:
        _ = stage.read_float("/World/Robot/Triangle", "label")
    except e:
        assert_equal(e.kind, UsdErrorKind.type_mismatch)
        rejected = True
    assert_true(rejected)
    rejected = False
    try:
        _ = stage.read_float("/World/Robot/Triangle", "missing")
    except e:
        assert_equal(e.kind, UsdErrorKind.not_found)
        rejected = True
    assert_true(rejected)
    rejected = False
    try:
        _ = stage.read_text("/World/Robot/Triangle", "la\x00bel")
    except e:
        assert_equal(e.kind, UsdErrorKind.invalid_argument)
        rejected = True
    assert_true(rejected)
    rejected = False
    try:
        var missing = Stage(String(args[2], "/missing.usda"))
        _ = missing
    except e:
        assert_equal(e.kind, UsdErrorKind.io)
        rejected = True
    assert_true(rejected)
    assert_equal(
        stage.read_float("/World/Robot/Triangle", "gain"), Float64(1.5)
    )
    print("PASS typed error recovery and non-poisoning")
