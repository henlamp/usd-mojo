# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Hand-derived geometry/animation expectations plus an independent SDK probe."""
from std.sys import argv
from std.testing import assert_equal, assert_true, assert_almost_equal
from usd_mojo import (
    Stage,
    TimeCode,
    Value,
    SchemaSnapshot,
    schema_properties,
    visibility,
    purpose,
    world_bounds,
    inherited_primvar,
    instance_transforms,
    instance_mask,
    bound_material,
    skeleton_joints,
    joint_transforms,
    skinned_points,
    collection_members,
    dependencies,
    export_usdz,
    poll_changes,
    SceneSnapshot,
    clip_sets,
    clip_set,
    set_clip_set,
    UsdErrorKind,
    shader_graph,
)


def retained(filename: String) raises -> SchemaSnapshot:
    var stage = Stage(filename)
    return SchemaSnapshot(stage, "/World/Cube")


def main() raises:
    var args = argv()
    var stage = Stage(args[1])
    var directory = args[2]
    assert_equal(visibility(stage, "/World/Hidden/Points"), String("invisible"))
    assert_equal(purpose(stage, "/World/Cube"), String("default"))
    var bounds = world_bounds(stage, "/World/Cube")
    assert_equal(bounds.numbers[0], Float64(10))
    assert_equal(bounds.numbers[3], Float64(12))
    assert_equal(
        inherited_primvar(stage, "/World/Cube", "quality").integers[0], Int64(7)
    )
    var transforms = instance_transforms(stage, "/World/Instances")
    assert_equal(len(transforms.numbers), 32)
    assert_equal(transforms.numbers[12], Float64(6))
    assert_equal(transforms.numbers[28], Float64(7))
    var mask = instance_mask(stage, "/World/Instances")
    assert_equal(mask.integers[0], Int64(1))
    assert_equal(mask.integers[1], Int64(0))
    assert_equal(
        bound_material(stage, "/World/Mesh"), String("/World/Material")
    )
    var graph = shader_graph(stage, "/World/Material")
    assert_equal(len(graph.nodes), 2)
    assert_equal(len(graph.connections), 1)
    assert_true(graph.connections[0].resolved)
    assert_equal(
        graph.connections[0].source,
        String("/World/Material/Surface.outputs:surface"),
    )
    for context in [String("unknown"), String("empty"), String("broken"), String("cycle")]:
        var fallback = shader_graph(stage, "/World/Fallback", context)
        assert_true(String("/World/Fallback/surface") in fallback.nodes)
        assert_true(String("/World/Fallback/displacement") in fallback.nodes)
        assert_true(String("/World/Fallback/volume") in fallback.nodes)
        for node in fallback.nodes:
            print("GRAPH", context, node)
        if context == "broken":
            var unresolved = False
            for edge in fallback.connections:
                unresolved = unresolved or not edge.resolved
            assert_true(unresolved)
        if context == "cycle":
            assert_true(String("/World/Fallback/A") in fallback.nodes)
            assert_true(String("/World/Fallback/B") in fallback.nodes)
    for context in [String("ri"), String("graph")]:
        var selected = shader_graph(stage, "/World/Fallback", context)
        assert_true(String("/World/Fallback/Ri") in selected.nodes)
        assert_true(String("/World/Fallback/surface") not in selected.nodes)
        assert_true(String("/World/Fallback/displacement") in selected.nodes)
        assert_true(String("/World/Fallback/volume") in selected.nodes)
        for node in selected.nodes:
            print("GRAPH", context, node)
    assert_equal(
        skeleton_joints(stage, "/Rig/Skeleton").texts[1], String("root/child")
    )
    var joints = joint_transforms(stage, "/Rig/Skeleton")
    assert_equal(joints.numbers[28], Float64(2))
    assert_equal(joints.numbers[29], Float64(1))
    var points = skinned_points(stage, "/Rig/Skeleton", "/Rig/Skin")
    assert_equal(points.numbers[0], Float64(2))
    assert_equal(points.numbers[1], Float64(4))
    var mapped = skinned_points(stage, "/Rig/Skeleton", "/Rig/SkinMapped")
    assert_equal(mapped.numbers[0], Float64(2))
    assert_equal(mapped.numbers[1], Float64(7))
    assert_equal(
        collection_members(stage, "/World/CollisionGroup", "colliders")[0],
        String("/World/Cube"),
    )
    assert_true(len(schema_properties("Mesh")) > 10)
    assert_true(len(schema_properties("PhysicsDriveAPI", api=True)) > 0)
    assert_equal(clip_sets(stage, "/Animated")[0], String("default"))
    assert_equal(
        stage.read_float("/Animated", "gain", TimeCode.at(5)), Float64(6)
    )
    var clips = clip_set(stage, "/Animated")
    set_clip_set(stage, "/Animated", clips)
    stage.save()
    var assets = dependencies(stage)
    var clip_found = False
    for asset in assets:
        assert_true(asset.kind != "unresolved")
        if "clip.usda" in asset.path:
            clip_found = True
    assert_true(clip_found)
    export_usdz(stage, String(directory, "/scene.usdz"))
    var rejected = False
    try:
        export_usdz(stage, String(directory, "/scene.usdz"))
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_argument)
        rejected = True
    assert_true(rejected)

    var before = poll_changes(stage)
    var frozen = SceneSnapshot(stage)
    assert_equal(len(frozen.transforms()), len(frozen.paths()) * 16)
    stage.set_value(
        "/World/Cube", "size", Value.floating("double", [Float64(4)])
    )
    var changes = poll_changes(stage)
    assert_true(changes.generation > before.generation)
    assert_true(len(changes.changed) + len(changes.resynced) > 0)
    assert_equal(frozen.value("/World/Cube", "size").numbers[0], Float64(2))
    frozen.export(String(directory, "/frozen.usda"))
    var cleared = poll_changes(stage)
    assert_equal(len(cleared.changed) + len(cleared.resynced), 0)
    assert_equal(retained(args[1]).value("size").numbers[0], Float64(4))
    stage.set_value(
        "/World/Cube", "size", Value.floating("double", [Float64(2)])
    )

    # Emit every supported property component; Python compares to the SDK.
    for path in stage.prim_paths():
        var snapshot = SchemaSnapshot(stage, path)
        var missing = snapshot.missing_values()
        for name in snapshot.attributes():
            var absent = False
            for item in missing:
                if item == name:
                    absent = True
            if absent:
                continue
            var value = snapshot.value(name)
            for i in range(len(value.numbers)):
                print(
                    "VALUE",
                    path,
                    name,
                    value.type_name,
                    "N",
                    i,
                    value.numbers[i],
                )
            for i in range(len(value.integers)):
                print(
                    "VALUE",
                    path,
                    name,
                    value.type_name,
                    "I",
                    i,
                    value.integers[i],
                )
            for i in range(len(value.unsigned_integers)):
                print(
                    "VALUE",
                    path,
                    name,
                    value.type_name,
                    "U",
                    i,
                    value.unsigned_integers[i],
                )
            for i in range(len(value.texts)):
                if value.texts[i].byte_length() > 0:
                    print(
                        "VALUE",
                        path,
                        name,
                        value.type_name,
                        "T",
                        i,
                        value.texts[i],
                    )
    print(
        "PASS schema values, geometry, instancing, skeleton/blend shapes,"
        " clips, collections, USDZ and snapshots"
    )
