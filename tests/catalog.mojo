# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
from std.sys import argv
from std.testing import assert_equal, assert_true
from usd_mojo import Stage, TimeCode, Value, export_usdz, value_types, schema_types


def same(a: Value, b: Value) raises:
    assert_equal(a.type_name, b.type_name)
    assert_equal(a.numbers, b.numbers)
    assert_equal(a.integers, b.integers)
    assert_equal(a.unsigned_integers, b.unsigned_integers)
    assert_equal(a.texts, b.texts)


def main() raises:
    var args = argv()
    var source = Stage(args[1])
    var output = Stage(args[2], create=True)
    output.define_prim("/Types")
    var types = value_types()
    for i in range(len(types)):
        var t = types[i].copy()
        print(
            String(
                "TYPE\t",
                t.name,
                "\t",
                t.cpp_type,
                "\t",
                t.role if t.role != "" else String("-"),
                "\t",
                Int(t.is_array),
                "\t",
                Int(t.readable_writable),
                "\t",
                Int(t.native_view),
            )
        )
        if t.readable_writable:
            var name = String("v", i)
            var value = source.read_value("/Types", name)
            output.set_value("/Types", name, value)
            same(output.read_value("/Types", name), value)
            for frame in range(1, 6):
                var time = TimeCode.at(Float64(frame))
                var animated = source.read_value("/Types", name, time)
                if frame % 2 == 1:
                    output.set_value("/Types", name, animated, time)
            for frame in range(1, 6):
                var time = TimeCode.at(Float64(frame))
                var animated = source.read_value("/Types", name, time)
                same(output.read_value("/Types", name, time), animated)
            var changed = source.read_value("/Types", name, TimeCode.at(1))
            output.set_value("/Types", name, changed)
            same(output.read_value("/Types", name), changed)
        else:
            assert_true(t.cpp_type == "SdfOpaqueValue")
    for schema in schema_types():
        print(String("SCHEMA\t", schema.name, "\t", schema.kind))
        for property in schema.properties:
            print(String("PROPERTY\t", schema.name, "\t", property))
    output.save()
    output.export(args[3])
    export_usdz(output, args[4])
    for i in range(len(types)):
        if types[i].readable_writable:
            var name = String("v", i)
            same(output.read_value("/Types", name), source.read_value("/Types", name, TimeCode.at(1)))
