# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
from std.sys import argv
from std.testing import assert_equal, assert_true
from usd_mojo import Stage, Value, TimeCode


def rejects(mut stage: Stage, value: Value) raises:
    var failed = False
    try:
        stage.set_value("/World", "invalid", value)
    except:
        failed = True
    assert_true(failed)
    assert_true(not stage.has_attribute("/World", "invalid"))


def main() raises:
    var args = argv()
    var input = Stage(args[1])
    var output = Stage(args[2], create=True)
    output.define_prim("/World", "Xform")
    output.set_default_prim("/World")
    output.set_text("/World", "empty_text", "")
    assert_equal(output.read_text("/World", "empty_text"), "")
    var text_types: List[String] = ["string", "token", "asset"]
    for type_name in text_types:
        var empty = Value.text(
            type_name, List[String](length=1, fill=String(""))
        )
        output.set_value("/World", String("empty_scalar_", type_name), empty)
        assert_equal(
            output.read_value(
                "/World", String("empty_scalar_", type_name)
            ).texts[0],
            "",
        )
    output.define_prim("/Untyped")
    assert_equal(output.prim_type("/Untyped"), "")
    var names = input.attribute_names("/Values")
    var count = 0
    for name in names:
        if name == "purpose" or name == "visibility" or name == "xformOpOrder":
            continue
        var value = input.read_value("/Values", name)
        output.set_value("/World", name, value)
        var copied = output.read_value("/World", name)
        assert_equal(copied.type_name, value.type_name)
        assert_equal(copied.numbers, value.numbers)
        assert_equal(copied.integers, value.integers)
        assert_equal(copied.unsigned_integers, value.unsigned_integers)
        assert_equal(copied.texts, value.texts)
        count += 1
    assert_equal(count, 93)
    rejects(
        output,
        Value.signed("int", List[Int64](length=1, fill=Int64(2147483648))),
    )
    rejects(
        output,
        Value.unsigned("uchar", List[UInt64](length=1, fill=UInt64(256))),
    )
    rejects(
        output, Value.unsigned("bool", List[UInt64](length=1, fill=UInt64(2)))
    )
    rejects(output, Value.floating("double3", List[Float64](length=2, fill=1)))
    rejects(
        output, Value.floating("float", List[Float64](length=1, fill=1e100))
    )
    rejects(output, Value.floating("int64", List[Float64](length=1, fill=1)))
    rejects(
        output,
        Value.text("string", List[String](length=1, fill=String("bad\0text"))),
    )
    var failed = False
    try:
        output.set_value(
            "/World",
            "scalar_double",
            Value.signed("int64", List[Int64](length=1, fill=1)),
        )
    except:
        failed = True
    assert_true(failed)
    output.define_prim("/World/Ref", "Xform")
    output.add_reference("/World/Ref", args[3], "/Asset", offset=1, scale=2)
    assert_equal(output.read_float("/World/Ref", "gain", TimeCode.at(3)), 2.0)
    output.add_sublayer(args[4])
    assert_equal(output.read_value("/Layer", "number").integers[0], Int64(42))
    output.define_prim("/World/Target", "Xform")
    output.add_relationship_target("/World", "link", "/World/Target")
    assert_equal(len(output.relationship_targets("/World", "link")), 1)
    output.clear_relationship_targets("/World", "link")
    assert_equal(len(output.relationship_targets("/World", "link")), 0)
    output.select_variant("/World", "mode", "a", create=True)
    output.edit_variant("/World", "mode")
    output.set_float("/World", "gain", 10)
    output.edit_root()
    output.select_variant("/World", "mode", "b", create=True)
    output.edit_variant("/World", "mode")
    output.set_float("/World", "gain", 20)
    output.edit_root()
    output.select_variant("/World", "mode", "a")
    assert_equal(output.read_float("/World", "gain"), 10.0)
    output.select_variant("/World", "mode", "b")
    assert_equal(output.read_float("/World", "gain"), 20.0)
    output.save()
    output.export(args[5])
    print(
        "PASS 31 scalar types, 31 arrays, 31 empty arrays, exact integers,"
        " references, sublayers and variants"
    )
