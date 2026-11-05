# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Layer isolation, edit mappings, opaque metadata and namespace edits."""
from std.sys import argv
from std.testing import assert_equal, assert_true
from usd_mojo import (
    Stage,
    Layer,
    EditTarget,
    Metadata,
    Value,
    UsdError,
    UsdErrorKind,
    set_metadata,
    clear_metadata,
    rename_prim,
    remove_prim,
    add_inherit,
    add_specialize,
    NamespaceEditor,
)


def retained_layer(filename: String) raises -> Layer:
    var stage = Stage(filename)
    return Layer(stage)


def main() raises:
    var args = argv()
    var directory = args[1]
    var filename = String(directory, "/root.usda")
    var weak_path = String(directory, "/weak.usda")
    var weak = Layer(weak_path, create=True)
    weak.replace_content(
        '#usda 1.0\ndef Xform "World" {\n def Xform "Robot" {\n double tuning ='
        " 1\n }\n}\n"
    )
    weak.save()
    var stage = Stage(filename, create=True)
    stage.define_prim("/World", "Xform")
    var root = Layer(stage)
    root.set_sublayers(List[String](length=1, fill=String("weak.usda")))
    assert_equal(len(root.sublayers()), 1)
    assert_equal(stage.read_float("/World/Robot", "tuning"), Float64(1))
    var original = EditTarget(stage)
    var weak_target = EditTarget(stage, weak)
    weak_target.apply(stage)
    stage.set_value(
        "/World/Robot",
        "tuning",
        Value.floating("double", List[Float64](length=1, fill=2)),
    )
    assert_equal(stage.read_float("/World/Robot", "tuning"), Float64(2))
    assert_true(weak.dirty())
    weak.save()
    original.apply(stage)
    var session = Layer(stage, session=True)
    assert_true(session.is_anonymous())
    var session_target = EditTarget(stage, session)
    session_target.apply(stage)
    stage.set_value(
        "/World/Robot",
        "tuning",
        Value.floating("double", List[Float64](length=1, fill=9)),
    )
    assert_equal(stage.read_float("/World/Robot", "tuning"), Float64(9))
    original.apply(stage)

    var dictionary = Metadata()
    var nested = Metadata()
    var unsigned = Metadata(
        Value.unsigned("uint64", List[UInt64](length=1, fill=UInt64.MAX))
    )
    var signed = Metadata(
        Value.signed("int64", List[Int64](length=1, fill=Int64.MIN))
    )
    nested.set("unsigned", unsigned)
    nested.set("signed", signed)
    dictionary.set("nested", nested)
    set_metadata(stage, "customData", dictionary, path="/World")
    var snapshot = Metadata(stage, "customData", path="/World")
    assert_true(snapshot.is_dictionary())
    var child = Metadata(snapshot, "nested")
    var leaf = Metadata(child, "unsigned")
    assert_equal(leaf.value().unsigned_integers[0], UInt64.MAX)
    var negative = Metadata(child, "signed")
    assert_equal(negative.value().integers[0], Int64.MIN)
    child.erase("unsigned")
    assert_equal(len(child.keys()), 1)
    var unchanged = Metadata(snapshot, "nested")
    assert_equal(len(unchanged.keys()), 2)
    set_metadata(
        stage, "customData", signed, path="/World", dictionary="nested:extra"
    )
    clear_metadata(
        stage, "customData", path="/World", dictionary="nested:extra"
    )

    stage.define_prim("/World/Ref", "Xform")
    stage.add_reference("/World/Ref", "weak.usda", "/World/Robot")
    var reference = Metadata(stage, "references", path="/World/Ref")
    assert_true(reference.type_name().byte_length() > 0)
    stage.define_prim("/World/RefCopy", "Xform")
    set_metadata(stage, "references", reference, path="/World/RefCopy")
    assert_equal(stage.read_float("/World/RefCopy", "tuning"), Float64(2))
    var reference_target = EditTarget(stage, weak, reference_prim="/World/Ref")
    assert_equal(
        reference_target.map_to_spec_path("/World/Ref"), String("/World/Robot")
    )
    reference_target.apply(stage)
    stage.set_value(
        "/World/Ref",
        "tuning",
        Value.floating("double", List[Float64](length=1, fill=3)),
    )
    weak.save()
    original.apply(stage)
    assert_equal(stage.read_float("/World/RefCopy", "tuning"), Float64(3))

    stage.define_prim("/World/Move", "Xform")
    stage.define_prim("/World/Watcher", "Scope")
    stage.add_relationship_target("/World/Watcher", "watch", "/World/Move")
    rename_prim(stage, "/World/Move", "/World/Moved")
    assert_equal(
        stage.relationship_targets("/World/Watcher", "watch")[0],
        String("/World/Moved"),
    )
    remove_prim(stage, "/World/Moved")
    assert_equal(len(stage.relationship_targets("/World/Watcher", "watch")), 0)
    var other = Stage(String(directory, "/other.usda"), create=True)
    var other_root = Layer(other)
    var before = other_root.content()
    var rejected = False
    try:
        original.apply(other)
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_argument)
        rejected = True
    assert_true(rejected)
    assert_equal(other_root.content(), before)
    rejected = False
    try:
        var invalid = EditTarget(stage, other_root)
        _ = invalid
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_argument)
        rejected = True
    assert_true(rejected)
    var preserved = root.content()
    rejected = False
    try:
        root.replace_content("#usda 1.0\ndef Xform {")
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_data)
        rejected = True
    assert_true(rejected)
    assert_equal(root.content(), preserved)
    assert_equal(stage.prim_type("/World"), String("Xform"))
    root.set_sublayer_offset(0, 4, 2)
    assert_equal(root.sublayer_offsets()[0].offset, Float64(4))
    assert_equal(root.sublayer_offsets()[0].scale, Float64(2))
    root.set_sublayer_offset(0, 0)
    stage.save()
    var independent = retained_layer(filename)
    assert_true(independent.content().byte_length() > 0)
    var source = Stage(String(directory, "/namespace-source.usda"), create=True)
    source.define_prim("/Model", "Xform")
    source.set_value("/Model", "gain", Value.floating("double", [Float64(5)]))
    source.save()
    var dependent = Stage(
        String(directory, "/namespace-dependent.usda"), create=True
    )
    dependent.define_prim("/Ref", "Xform")
    dependent.add_reference("/Ref", "namespace-source.usda", "/Model")
    var editor = NamespaceEditor(source)
    editor.add_dependent_stage(dependent)
    editor.move_prim("/Model", "/Renamed")
    assert_true(editor.check().can_apply())
    editor.apply()
    assert_equal(dependent.read_float("/Ref", "gain"), Float64(5))
    var renamed_reference = Metadata(dependent, "references", path="/Ref")
    assert_equal(renamed_reference.arcs()[0].prim_path, String("/Renamed"))
    editor.move_property("/Renamed.gain", "/Renamed.tuning")
    assert_true(editor.check().can_apply())
    editor.apply()
    assert_equal(dependent.read_float("/Ref", "tuning"), Float64(5))
    editor.delete_property("/Renamed.tuning")
    editor.apply()
    assert_true(not dependent.has_attribute("/Ref", "tuning"))
    print(
        "PASS layer edits, session isolation, reference mapping, metadata"
        " ownership, namespace and errors"
    )
