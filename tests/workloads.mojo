# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Installed-library application workflows; source assets are never saved."""
from std.collections import ImmSpan
from std.memory import bitcast
from std.ffi import external_call
from std.sys import argv
from std.time import perf_counter_ns
from std.testing import assert_equal, assert_true
from usd_mojo import (
    Stage,
    Layer,
    EditTarget,
    ArraySnapshot,
    SceneSnapshot,
    Value,
    TimeCode,
    AttributeEdit,
    set_values,
    poll_changes,
    override_prim,
    export_usdz,
    read_body,
    read_joint,
    UsdErrorKind,
    set_connections,
    Metadata,
    set_metadata,
)


def float_hash(values: ImmSpan[Float32, _]) -> UInt64:
    var result = UInt64(14695981039346656037)
    for value in values:
        result = (
            result ^ UInt64(bitcast[DType.uint32](Float32(value)))
        ) * UInt64(1099511628211)
    return result


def int_hash(values: ImmSpan[Int32, _]) -> UInt64:
    var result = UInt64(14695981039346656037)
    for value in values:
        result = (
            result ^ UInt64(bitcast[DType.uint32](Int32(value)))
        ) * UInt64(1099511628211)
    return result


def captures(stage: Stage) raises:
    for sample in range(3):
        var start = perf_counter_ns()
        var frozen = SceneSnapshot(stage)
        var elapsed = perf_counter_ns() - start
        var matrices = frozen.transforms()
        var checksum = Float64(0)
        for value in matrices:
            checksum += value
        print("CAPTURE", elapsed, len(matrices), checksum)
        if sample == 0:
            var paths = frozen.paths()
            var kinds = frozen.types()
            var prototypes = frozen.prototypes()
            for i in range(len(paths)):
                print(
                    String(
                        "FROZEN\t",
                        paths[i],
                        "\t",
                        kinds[i],
                        "\t",
                        Int(prototypes[i].byte_length() > 0),
                    ),
                    end="",
                )
                for j in range(16):
                    print(String("\t", matrices[i * 16 + j]), end="")
                print()


def inspect(filename: String, root: String, freezeable: Bool) raises:
    var start = perf_counter_ns()
    var stage = Stage(filename)
    print("OPEN", perf_counter_ns() - start)
    assert_equal(len(stage.composition_errors()), 0)
    start = perf_counter_ns()
    for path in stage.instance_paths():
        var kind = stage.prim_type(path)
        print(String("PRIM\t", path, "\t", kind))
        var matrix = stage.world_transform(path)
        print(String("XFORM\t", path), end="")
        for value in matrix:
            print(String("\t", value), end="")
        print()
        if kind == "Mesh":
            var mesh = stage.mesh_snapshot(path)
            var points = ArraySnapshot(stage, path, "points")
            assert_equal(
                float_hash(mesh.points()),
                float_hash(points.view[DType.float32]()),
            )
            print(
                String(
                    "MESH\t",
                    path,
                    "\t",
                    mesh.point_count(),
                    "\t",
                    mesh.face_count(),
                    "\t",
                    float_hash(mesh.points()),
                    "\t",
                    int_hash(mesh.face_vertex_counts()),
                    "\t",
                    int_hash(mesh.face_vertex_indices()),
                    "\t",
                    stage.material_path(path),
                )
            )
        if stage.has_schema(path, "PhysicsRigidBodyAPI"):
            var body = read_body(stage, path)
            print(
                String(
                    "BODY\t",
                    path,
                    "\t",
                    body.mass.mass,
                    "\t",
                    Int(body.enabled),
                    "\t",
                    Int(body.kinematic),
                )
            )
        if (
            kind == "PhysicsFixedJoint"
            or kind == "PhysicsRevoluteJoint"
            or kind == "PhysicsPrismaticJoint"
        ):
            var joint = read_joint(stage, path)
            print(
                String(
                    "JOINT\t",
                    path,
                    "\t",
                    joint.body0,
                    "\t",
                    joint.body1,
                    "\t",
                    joint.axis,
                    "\t",
                    joint.lower_limit,
                    "\t",
                    joint.upper_limit,
                )
            )
        for name in stage.variant_sets(path):
            for variant in stage.variant_names(path, name):
                print(String("VARIANT\t", path, "\t", name, "\t", variant))
    print("SCAN", perf_counter_ns() - start)
    if freezeable:
        captures(stage)
    else:
        var rejected = False
        try:
            var frozen = SceneSnapshot(stage)
            _ = frozen
        except error:
            assert_equal(error.kind, UsdErrorKind.unsupported)
            rejected = True
        assert_true(rejected)
        print("FROZEN_REJECTED unregistered metadata")
        var masked = Stage(filename, [root])
        captures(masked)
    print("PEAK_RSS", external_call["usdm_test_peak_rss", Int64]())


def copy_conventions(mut stage: Stage, source: Stage) raises:
    set_metadata(
        stage, "upAxis", Metadata(Value.text("token", [source.up_axis()]))
    )
    set_metadata(
        stage,
        "metersPerUnit",
        Metadata(Value.floating("double", [source.meters_per_unit()])),
    )
    set_metadata(
        stage,
        "kilogramsPerUnit",
        Metadata(Value.floating("double", [source.kilograms_per_unit()])),
    )
    var info = source.stage_info()
    set_metadata(
        stage,
        "timeCodesPerSecond",
        Metadata(Value.floating("double", [info.time_codes_per_second])),
    )
    set_metadata(
        stage,
        "framesPerSecond",
        Metadata(Value.floating("double", [info.frames_per_second])),
    )
    if info.has_authored_range:
        stage.set_time_range(
            info.start_time,
            info.end_time,
            info.time_codes_per_second,
            info.frames_per_second,
        )


def author(
    filename: String, root: String, directory: String, packageable: Bool
) raises:
    var source = Stage(filename)
    var base = Stage(String(directory, "/base.usda"), create=True)
    copy_conventions(base, source)
    base.define_prim("/World", "Xform")
    base.define_prim("/World/Asset", "Xform")
    base.add_reference("/World/Asset", filename, root)
    base.set_value(
        "/World/Asset", "runtime:gain", Value.floating("double", [Float64(1)])
    )
    base.set_default_prim("/World")
    base.save()
    var stage = Stage(String(directory, "/overlay.usda"), create=True)
    copy_conventions(stage, source)
    stage.add_sublayer("base.usda")
    override_prim(stage, "/World/Asset")
    stage.set_value(
        "/World/Asset", "runtime:gain", Value.floating("double", [Float64(2)])
    )
    stage.set_value(
        "/World/Asset",
        "runtime:label",
        Value.text("string", [String("reviewed")]),
    )
    var edited_drive = False
    var edited_color = False
    for path in stage.instance_paths():
        if (
            not edited_drive
            and stage.prim_type(path) == "PhysicsRevoluteJoint"
            and stage.has_schema(path, "PhysicsDriveAPI:angular")
        ):
            stage.set_value(
                path,
                "drive:angular:physics:targetPosition",
                Value.floating("float", [Float64(15)]),
            )
            assert_equal(
                read_joint(stage, path).drive.target_position, Float64(15)
            )
            print(String("EDIT_DRIVE\t", path))
            edited_drive = True
        if (
            not edited_color
            and stage.prim_type(path) == "Shader"
            and stage.has_authored_value(path, "info:id")
        ):
            if stage.read_text(path, "info:id") == "UsdPreviewSurface":
                stage.set_value(
                    path,
                    "inputs:diffuseColor",
                    Value.floating(
                        "color3f", [Float64(0.2), Float64(0.4), Float64(0.6)]
                    ),
                )
                set_connections(
                    stage, path, "inputs:diffuseColor", List[String]()
                )
                print(String("EDIT_COLOR\t", path))
                edited_color = True
    for i in range(3):
        set_values(
            stage,
            [
                AttributeEdit(
                    "/World/Asset",
                    "runtime:step",
                    Value.floating("double", [Float64(i)]),
                    TimeCode.at(Float64(i * 24)),
                )
            ],
        )
    stage.set_default_prim("/World")
    stage.save()
    var layer = Layer(stage)
    layer.export(String(directory, "/layer.usdc"))
    stage.export(String(directory, "/flat.usda"))
    stage.export(String(directory, "/flat.usdc"))
    if packageable:
        export_usdz(stage, String(directory, "/bundle.usdz"))
    else:
        var rejected = False
        try:
            export_usdz(stage, String(directory, "/bundle.usdz"))
        except error:
            assert_equal(error.kind, UsdErrorKind.not_found)
            rejected = True
        assert_true(rejected, "Unresolved dependencies must prevent packaging")
        print("PACKAGE_REJECTED unresolved external assets")
    # Every advertised source variant is selected through a session edit target.
    var session = Layer(stage, session=True)
    var target = EditTarget(stage, session)
    target.apply(stage)
    for name in stage.variant_sets("/World/Asset"):
        for variant in stage.variant_names("/World/Asset", name):
            stage.select_variant("/World/Asset", name, variant)
            assert_equal(len(stage.composition_errors()), 0)
            var count = 0
            for path in stage.instance_paths():
                if stage.prim_type(path) == "Mesh":
                    var mesh = stage.mesh_snapshot(path)
                    count += mesh.point_count()
            print(String("SELECT\t", name, "\t", variant, "\t", count))
    print("PASS layered application authoring and format exports")


def cycle(
    filename: String, root: String, output: String, iteration: Int
) raises:
    var stage = Stage(filename)
    var session = Layer(stage, session=True)
    var target = EditTarget(stage, session)
    target.apply(stage)
    stage.set_value(
        root, "runtime:cycle", Value.floating("double", [Float64(iteration)])
    )
    var frozen = SceneSnapshot(stage)
    stage.set_value(
        root, "runtime:cycle", Value.floating("double", [Float64(-1)])
    )
    assert_equal(
        frozen.value(root, "runtime:cycle").numbers[0], Float64(iteration)
    )
    assert_true(poll_changes(stage).generation > 0)
    frozen.export(output)
    # A separate open sees the last completed write while all source layers stay clean.
    var reopened = Stage(output)
    assert_equal(reopened.read_float(root, "runtime:cycle"), Float64(iteration))


def soak(filename: String, root: String, directory: String, rounds: Int) raises:
    var start = perf_counter_ns()
    for i in range(10):
        cycle(filename, root, String(directory, "/soak.usdc"), i)
    for i in range(rounds):
        cycle(filename, root, String(directory, "/soak.usdc"), 10 + i)
        if i % 5 == 0 or i == rounds - 1:
            print(
                "MEMORY",
                i,
                external_call["usdm_test_current_rss", Int64](),
                external_call["usdm_test_live_allocated", Int64](),
                external_call["usdm_test_peak_rss", Int64](),
            )
    print("DURATION", perf_counter_ns() - start)


def main() raises:
    var args = argv()
    if args[1] == "inspect":
        inspect(args[2], args[3], args[4] == "complete")
    elif args[1] == "author":
        author(args[2], args[3], args[4], args[5] == "complete")
    elif args[1] == "soak":
        soak(args[2], args[3], args[4], Int(args[5]))
    elif args[1] == "preserve":
        var stage = Stage(args[2])
        var layer = Layer(stage)
        layer.export(String(args[3], "/source.usdc"))
        var rejected = False
        try:
            stage.export(String(args[3], "/guarded.usdc"))
        except error:
            assert_equal(error.kind, UsdErrorKind.unsupported)
            rejected = True
        assert_true(rejected)
    else:
        raise Error("Unknown workload mode")
