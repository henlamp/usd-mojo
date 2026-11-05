# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Composition strengths, non-destructive mutations, streaming views and reports."""
from std.sys import argv
from std.testing import assert_equal, assert_true
from usd_mojo import (
    Stage,
    Layer,
    TimeCode,
    Value,
    ArraySnapshot,
    SceneSnapshot,
    AttributeEdit,
    set_values,
    override_prim,
    create_attribute,
    clear_attribute_values,
    clear_value_at,
    block_attribute,
    remove_property_opinion,
    set_active,
    poll_changes,
    set_connections,
    clear_connection_opinions,
    set_relationship_targets,
    validate_stage,
    validator_names,
    export_usdz,
    UsdErrorKind,
    EditTarget,
    set_array,
)


def captured(filename: String) raises -> ArraySnapshot:
    var stage = Stage(filename)
    return ArraySnapshot(stage, "/Robot/Visual/Geometry", "points")


def rejects_batch_collision(mut stage: Stage, layer: Layer, path: String, name: String) raises:
    var before = layer.content()
    var generation = poll_changes(stage).generation
    var rejected = False
    try:
        set_values(stage, [
            AttributeEdit(path, "runtime:preflightProbe", Value.floating("double", [Float64(9)]), .default),
            AttributeEdit(path, name, Value.floating("double", [Float64(9)]), .default),
        ])
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_argument)
        rejected = True
    assert_true(rejected)
    assert_equal(layer.content(), before)
    assert_equal(poll_changes(stage).generation, generation)


def rejects_metadata(directory: String, name: String) raises:
    var stage = Stage(String(directory, "/", name, ".usda"))
    var rejected = False
    try:
        stage.export(String(directory, "/rejected-", name, ".usdc"))
    except error:
        assert_equal(error.kind, UsdErrorKind.unsupported)
        rejected = True
    assert_true(rejected)
    rejected = False
    try:
        var frozen = SceneSnapshot(stage)
        _ = frozen
    except error:
        assert_equal(error.kind, UsdErrorKind.unsupported)
        rejected = True
    assert_true(rejected)


def main() raises:
    var args = argv()
    var directory = args[1]
    rejects_metadata(directory, "inactive-unregistered")
    rejects_metadata(directory, "property-unregistered")
    rejects_metadata(directory, "instance-unregistered")
    var unregistered = Stage(String(directory, "/unregistered.usda"))
    var original_layer = Layer(unregistered)
    original_layer.export(String(directory, "/unregistered.usdc"))
    var refused = False
    try:
        unregistered.export(String(directory, "/rejected-flat.usdc"))
    except error:
        assert_equal(error.kind, UsdErrorKind.unsupported)
        refused = True
    assert_true(refused)
    refused = False
    try:
        var frozen = SceneSnapshot(unregistered)
        _ = frozen
    except error:
        assert_equal(error.kind, UsdErrorKind.unsupported)
        refused = True
    assert_true(refused)
    var stage = Stage(String(directory, "/assembly.usda"))
    for name in [
        String("l_i"),
        String("i_v"),
        String("v_r"),
        String("r_p"),
        String("p_s"),
    ]:
        print("STRENGTH", name, stage.read_float("/Model", name))
    assert_equal(stage.read_float("/Model", "l_i"), Float64(9))
    assert_equal(stage.read_float("/Model", "i_v"), Float64(8))
    assert_equal(stage.read_float("/Model", "v_r"), Float64(7))
    assert_equal(stage.read_float("/Model", "r_p"), Float64(6))
    assert_equal(stage.read_float("/Model", "p_s"), Float64(5))
    var root = Layer(stage)
    assert_equal(stage.read_float("/Robot", "order"), Float64(1))
    root.set_sublayers([String("weaker.usda"), String("base.usda")])
    assert_equal(stage.read_float("/Robot", "order"), Float64(2))
    root.set_sublayers([String("base.usda"), String("weaker.usda")])
    override_prim(stage, "/Robot")
    create_attribute(stage, "/Robot", "runtime:gain", "double", uniform=True)
    stage.set_value(
        "/Robot", "runtime:gain", Value.floating("double", [Float64(3)])
    )
    stage.set_value("/Robot", "order", Value.floating("double", [Float64(99)]))
    assert_equal(stage.read_float("/Robot", "order"), Float64(99))
    block_attribute(stage, "/Robot", "order")
    var rejected = False
    try:
        var blocked = stage.read_value("/Robot", "order")
        _ = blocked
    except error:
        rejected = True
    assert_true(rejected)
    clear_attribute_values(stage, "/Robot", "order")
    assert_equal(stage.read_float("/Robot", "order"), Float64(1))
    stage.set_value(
        "/Robot",
        "order",
        Value.floating("double", [Float64(7)]),
        TimeCode.at(1),
    )
    clear_value_at(stage, "/Robot", "order", TimeCode.at(1))
    assert_equal(
        stage.read_float("/Robot", "order", TimeCode.at(1)), Float64(1)
    )
    remove_property_opinion(stage, "/Robot", "order")
    assert_equal(stage.read_float("/Robot", "order"), Float64(1))
    create_attribute(stage, "/Robot", "runtime:input", "double")
    set_connections(
        stage, "/Robot", "runtime:input", [String("/Robot.runtime:gain")]
    )
    assert_equal(
        stage.connections("/Robot", "runtime:input")[0],
        String("/Robot.runtime:gain"),
    )
    set_connections(stage, "/Robot", "runtime:input", List[String]())
    assert_equal(len(stage.connections("/Robot", "runtime:input")), 0)
    clear_connection_opinions(stage, "/Robot", "runtime:input")
    assert_equal(len(stage.connections("/Robot", "runtime:input")), 0)
    set_relationship_targets(
        stage, "/Robot", "runtime:visual", [String("/Robot/Visual")]
    )
    rejects_batch_collision(stage, root, "/Robot", "runtime:visual")
    set_active(stage, "/Robot/Visual", False)
    assert_true(not stage.prim_info("/Robot/Visual").active)
    set_active(stage, "/Robot/Visual", True)

    var low = ArraySnapshot(stage, "/Robot/Visual/Geometry", "points")
    assert_equal(low.element_count, 3)
    assert_equal(low.components_per_element, 3)
    assert_equal(len(low.view[DType.float32]()), 9)
    stage.select_variant("/Robot/Visual", "lod", "high")
    var high = ArraySnapshot(stage, "/Robot/Visual/Geometry", "points")
    assert_equal(high.element_count, 300000)
    assert_equal(len(high.view[DType.float32]()), 900000)
    set_array(
        stage,
        "/Robot",
        "runtime:copiedPoints",
        "point3f[]",
        high.view[DType.float32](),
    )
    assert_equal(
        ArraySnapshot(stage, "/Robot", "runtime:copiedPoints").element_count,
        300000,
    )
    remove_property_opinion(stage, "/Robot", "runtime:copiedPoints")
    assert_equal(low.view[DType.float32]()[3], Float32(1))
    rejected = False
    try:
        var wrong = high.view[DType.float64]()
        _ = wrong
    except error:
        assert_equal(error.kind, UsdErrorKind.type_mismatch)
        rejected = True
    assert_true(rejected)
    var held = captured(String(directory, "/assembly.usda"))
    stage.select_variant("/Robot/Visual", "lod", "low")
    assert_equal(held.element_count, 300000)
    stage.edit_variant("/Robot/Visual", "lod")
    set_values(
        stage,
        [
            AttributeEdit(
                "/Robot/Visual",
                "quality",
                Value.floating("double", [Float64(1)]),
                .default,
            )
        ],
    )
    stage.edit_root()
    assert_equal(stage.read_float("/Robot/Visual", "quality"), Float64(1))
    stage.select_variant("/Robot/Visual", "lod", "high")
    assert_true(not stage.has_attribute("/Robot/Visual", "quality"))
    stage.select_variant("/Robot/Visual", "lod", "low")
    set_values(
        stage,
        [
            AttributeEdit(
                "/Robot",
                "runtime:duplicate",
                Value.floating("double", [Float64(1)]),
                .default,
            ),
            AttributeEdit(
                "/Robot",
                "runtime:duplicate",
                Value.floating("double", [Float64(2)]),
                .default,
            ),
        ],
    )
    assert_equal(stage.read_float("/Robot", "runtime:duplicate"), Float64(2))
    var edits = List[AttributeEdit](capacity=2000)
    for i in range(2000):
        edits.append(
            AttributeEdit(
                "/Robot",
                String("runtime:a", i),
                Value.floating("double", [Float64(i)]),
                .default,
            )
        )
    _ = poll_changes(stage)
    var before = poll_changes(stage)
    set_values(stage, edits)
    var after = poll_changes(stage)
    assert_equal(after.generation - before.generation, UInt64(1))
    assert_equal(stage.read_float("/Robot", "runtime:a1999"), Float64(1999))
    var preserved = root.content()
    rejected = False
    try:
        set_values(
            stage,
            [
                AttributeEdit(
                    "/Robot",
                    "runtime:a0",
                    Value.floating("double", [Float64(999)]),
                    .default,
                ),
                AttributeEdit(
                    "/Robot",
                    "runtime:a1999",
                    Value.text("string", [String("wrong")]),
                    .default,
                ),
            ],
        )
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_argument)
        rejected = True
    assert_true(rejected)
    assert_equal(root.content(), preserved)
    assert_true(len(validator_names()) >= 1)
    var report = validate_stage(
        stage,
        validators=[
            String("usdValidation:CompositionErrorTest"),
            String("usd_mojo:MeshTopology"),
        ],
    )
    assert_true(report.is_valid())
    assert_equal(len(report.validators), 2)
    stage.save()
    root.export(String(directory, "/assembly.usdc"))
    stage.export(String(directory, "/flat.usdc"))
    var package_source = root.content()
    export_usdz(stage, String(directory, "/bundle.usdz"))
    assert_equal(root.content(), package_source)
    assert_equal(stage.read_float("/Robot", "order"), Float64(1))
    assert_equal(
        ArraySnapshot(stage, "/Robot/Visual/Geometry", "points").element_count,
        3,
    )
    assert_equal(len(stage.composition_errors()), 0)
    var archive = Stage(String(directory, "/bundle.usdz"))
    assert_equal(archive.read_float("/Robot", "runtime:gain"), Float64(3))
    var overlay = Stage(String(directory, "/overlay.usda"), create=True)
    override_prim(overlay, "/Edited")
    overlay.add_reference("/Edited", "bundle.usdz", "/Robot")
    overlay.set_value(
        "/Edited", "runtime:gain", Value.floating("double", [Float64(4)])
    )
    overlay.set_default_prim("/Edited")
    overlay.save()
    export_usdz(overlay, String(directory, "/edited.usdz"))
    assert_equal(archive.read_float("/Robot", "runtime:gain"), Float64(3))
    var edited_archive = Stage(String(directory, "/edited.usdz"))
    assert_equal(
        edited_archive.read_float("/Edited", "runtime:gain"), Float64(4)
    )
    var no_payload = Stage(
        String(directory, "/assembly.usda"), load_payloads=False
    )
    var partial = validate_stage(
        no_payload, validators=[String("usd_mojo:MeshTopology")]
    )
    assert_true(len(partial.unloaded_payloads) > 0)
    var invalid = Stage(String(directory, "/invalid.usda"))
    var all = validate_stage(
        invalid, validators=[String("usd_mojo:MeshTopology")], max_issues=0
    )
    assert_true(not all.is_valid())
    assert_true(all.truncated())
    assert_equal(len(all.issues), 0)
    var sample = validate_stage(
        invalid,
        validators=[String("usd_mojo:MeshTopology")],
        time=TimeCode.at(0),
    )
    assert_true(sample.is_valid())
    var later = validate_stage(
        invalid,
        validators=[String("usd_mojo:MeshTopology")],
        time=TimeCode.at(1),
    )
    assert_true(not later.is_valid())
    assert_equal(later.issues[0].sites[0].object_path, String("/Broken"))
    rejected = False
    try:
        var unavailable = validate_stage(
            stage, validators=[String("usd_mojo:MissingValidator")]
        )
        _ = unavailable
    except error:
        assert_equal(error.kind, UsdErrorKind.not_found)
        rejected = True
    assert_true(rejected)
    rejected = False
    try:
        var invalid_limit = validate_stage(stage, max_issues=-1)
        _ = invalid_limit
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_argument)
        rejected = True
    assert_true(rejected)
    for issue in validate_stage(
        stage, validators=[String("usdGeomValidators:StageMetadataChecker")]
    ).issues:
        print("ISSUE", issue.identifier, issue.severity)
    var mass = Stage(String(directory, "/mass.usda"))
    var mass_report = validate_stage(
        mass, validators=[String("usd_mojo:MassValues")]
    )
    assert_equal(mass_report.error_count, UInt64(1))
    assert_equal(
        mass_report.issues[0].sites[0].object_path, String("/Body.physics:mass")
    )
    for issue in validate_stage(
        mass, validators=[String("usdGeomValidators:StageMetadataChecker")]
    ).issues:
        print("ISSUE_BAD", issue.identifier, issue.severity)
    var original_target = EditTarget(stage)
    var referenced = Layer(String(directory, "/reference.usda"))
    var reference_content = referenced.content()
    var mapped_target = EditTarget(stage, referenced, reference_prim="/Timed")
    # A stronger attribute hides the target layer's relationship. Preflight
    # must check the authored spec as well as the composed property kind.
    mapped_target.apply(stage)
    rejects_batch_collision(stage, referenced, "/Timed", "batch:conflict")
    assert_equal(stage.read_float("/Timed", "batch:hidden"), Float64(1))
    rejects_batch_collision(stage, referenced, "/Timed", "batch:hidden")
    set_values(
        stage,
        [
            AttributeEdit(
                "/Timed",
                "sampled",
                Value.floating("double", [Float64(99)]),
                TimeCode.at(14),
            ),
            AttributeEdit(
                "/Timed",
                "clock",
                Value.floating("timecode", [Float64(20)]),
                .default,
            ),
        ],
    )
    assert_equal(
        stage.read_float("/Timed", "sampled", TimeCode.at(14)), Float64(99)
    )
    assert_equal(stage.read_value("/Timed", "clock").numbers[0], Float64(20))
    referenced.export(String(directory, "/mapped-ref.usda"))
    original_target.apply(stage)
    referenced.replace_content(reference_content)
    print(
        "PASS composition strengths, over/value mutations, high/low streaming"
        " views, batch preflight, validation and formats"
    )
