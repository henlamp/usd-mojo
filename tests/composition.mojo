# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Working-set controls and authored opinions retain SDK semantics."""
from std.sys import argv
from std.testing import assert_equal, assert_true
from usd_mojo import (
    Stage,
    Layer,
    Metadata,
    CompositionArc,
    Value,
    LoadRule,
    UsdErrorKind,
    population_mask,
    set_population_mask,
    load_rules,
    set_load_rules,
    muted_layers,
    mute_layer,
    composition_arcs,
    add_inherit,
    add_specialize,
    set_metadata,
    set_layer_field,
    ResolverContext,
    set_reference_opinions,
    set_payload_opinions,
    set_inherit_opinions,
    set_specialize_opinions,
    clear_arc_opinions,
    create_class_prim,
    override_prim,
)


def main() raises:
    var directory = argv()[1]
    var weak = Layer(String(directory, "/weak.usda"))
    var filename = String(directory, "/root.usda")
    var stage = Stage(filename, [String("/World/Ref")])
    assert_equal(len(population_mask(stage)), 1)
    assert_equal(len(stage.prim_paths()), 2)
    assert_equal(stage.read_float("/World/Ref", "tuning"), Float64(3))
    set_population_mask(stage, [String("/")])
    assert_true(len(stage.prim_paths()) > 2)
    mute_layer(stage, weak.identifier())
    assert_equal(len(muted_layers(stage)), 1)
    mute_layer(stage, weak.identifier(), muted=False)
    assert_equal(len(muted_layers(stage)), 0)
    var arcs = composition_arcs(stage, "/World/Ref")
    var found = False
    for arc in arcs:
        if arc.source_path == "/World/Robot":
            found = True
    assert_true(found)
    stage.define_prim("/World/Inherit", "Xform")
    stage.define_prim("/World/Special", "Xform")
    add_inherit(stage, "/World/Inherit", "/World/Robot")
    add_specialize(stage, "/World/Special", "/World/Robot")
    assert_equal(stage.read_float("/World/Inherit", "tuning"), Float64(3))
    assert_equal(stage.read_float("/World/Special", "tuning"), Float64(3))

    # Authored list operations stay separate from their composed result.
    var root = Layer(stage)
    var references = Metadata(root, "references", path="/World/Ref")
    assert_equal(references.arcs()[0].asset_path, String("weak.usda"))
    for operation in [
        String("explicit"),
        String("prepend"),
        String("append"),
        String("delete"),
        String("add"),
        String("order"),
    ]:
        var items = Metadata([String("/World/Ref")], operation=operation)
        assert_equal(items.items(operation=operation)[0], String("/World/Ref"))
    stage.define_prim("/World/Timed", "Xform")
    var timed = Metadata([CompositionArc("weak.usda", "/World/Robot", 5, 2)])
    set_layer_field(root, "references", timed, path="/World/Timed")
    var authored = Metadata(root, "references", path="/World/Timed")
    assert_equal(authored.arcs()[0].offset, Float64(5))
    assert_equal(authored.arcs()[0].scale, Float64(2))
    stage.define_prim("/World/Payload", "Xform")
    stage.add_payload("/World/Payload", "weak.usda", "/World/Robot")
    set_load_rules(stage, [LoadRule("/", "none")])
    assert_equal(load_rules(stage)[0].mode, String("none"))
    assert_true(not stage.prim_info("/World/Payload").loaded)
    set_load_rules(stage, [LoadRule("/", "all")])
    assert_true(stage.prim_info("/World/Payload").loaded)
    var previous = load_rules(stage)
    var rejected = False
    try:
        set_load_rules(stage, [LoadRule("/", "none"), LoadRule("/", "all")])
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_argument)
        rejected = True
    assert_true(rejected)
    assert_equal(len(load_rules(stage)), len(previous))
    stage.save()
    var empty = Stage(filename, List[String]())
    assert_equal(len(empty.prim_paths()), 0)
    var resolver = Stage(
        String(directory, "/resolver-root.usda"),
        [String("/")],
        search_paths=[String(directory, "/assets")],
    )
    assert_equal(resolver.read_float("/Model", "gain"), Float64(42))
    var context = ResolverContext([String(directory, "/assets")])
    var contextual = Stage(String(directory, "/resolver-root.usda"), context)
    assert_equal(contextual.read_float("/Model", "gain"), Float64(42))
    var parsed_context = ResolverContext(String(directory, "/assets"))
    var parsed = Stage(String(directory, "/resolver-root.usda"), parsed_context)
    assert_equal(parsed.read_float("/Model", "gain"), Float64(42))
    var weak_arcs = Stage(String(directory, "/arc-weak.usda"), create=True)
    weak_arcs.define_prim("/Ref", "Xform")
    weak_arcs.add_reference("/Ref", "weak.usda", "/World/Robot")
    weak_arcs.save()
    var arc_stage = Stage(String(directory, "/arc-root.usda"), create=True)
    arc_stage.add_sublayer("arc-weak.usda")
    arc_stage.define_prim("/Ref", "Xform")
    override_prim(arc_stage, "/Ref")
    var arc_layer = Layer(arc_stage)
    assert_equal(arc_stage.read_float("/Ref", "tuning"), Float64(3))
    set_reference_opinions(arc_layer, "/Ref", List[CompositionArc]())
    assert_true(not arc_stage.has_attribute("/Ref", "tuning"))
    clear_arc_opinions(arc_layer, "/Ref", "references")
    assert_equal(arc_stage.read_float("/Ref", "tuning"), Float64(3))
    set_reference_opinions(arc_layer, "/Ref", [CompositionArc("weak.usda", "/World/Robot")], operation="delete")
    assert_true(not arc_stage.has_attribute("/Ref", "tuning"))
    set_reference_opinions(arc_layer, "/Ref", [CompositionArc("weak.usda", "/World/Robot", 7, 2)])
    assert_equal(arc_stage.read_float("/Ref", "tuning"), Float64(3))
    arc_stage.define_prim("/Payload", "Xform")
    set_payload_opinions(arc_layer, "/Payload", [CompositionArc("weak.usda", "/World/Robot")])
    assert_equal(arc_stage.read_float("/Payload", "tuning"), Float64(3))
    create_class_prim(arc_stage, "/Class")
    arc_stage.set_float("/Class", "gain", 8)
    arc_stage.define_prim("/Derived", "Xform")
    set_inherit_opinions(arc_layer, "/Derived", [String("/Class")])
    assert_equal(arc_stage.read_float("/Derived", "gain"), Float64(8))
    arc_stage.define_prim("/Special", "Xform")
    set_specialize_opinions(arc_layer, "/Special", [String("/Class")])
    assert_equal(arc_stage.read_float("/Special", "gain"), Float64(8))
    arc_stage.select_variant("/Ref", "lod", "low", create=True)
    arc_stage.select_variant("/Ref", "lod", "high", create=True)
    arc_layer.remove_variant("/Ref", "lod", "low")
    assert_equal(len(arc_stage.variant_names("/Ref", "lod")), 1)
    arc_layer.remove_variant_set("/Ref", "lod")
    if String("lod") in arc_stage.variant_sets("/Ref"):
        assert_equal(len(arc_stage.variant_names("/Ref", "lod")), 0)
    arc_stage.save()
    print(
        "PASS masks, muting, load rules, provenance, inherits, specializes and"
        " authored list operations"
    )
