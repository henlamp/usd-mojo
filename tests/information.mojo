# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
from std.sys import argv
from std.testing import assert_equal, assert_true
from usd_mojo import Stage, TimeCode, Value, read_primvar, read_normals


def emit(tag: String, values: List[String]):
    for value in values:
        print(tag, value)


def main() raises:
    var args = argv()
    var stage = Stage(args[1], load_payloads=False)
    var info = stage.stage_info()
    print(
        "TIME",
        info.start_time,
        info.end_time,
        info.time_codes_per_second,
        info.frames_per_second,
        Int(info.has_authored_range),
    )
    emit("PATH", stage.prim_paths())
    emit("EXPANDED", stage.instance_paths())
    emit("ALL", stage.all_prim_paths())
    emit("LOADABLE", stage.loadable_paths())
    emit("LOADED", stage.loaded_paths())
    print("LAYERS", len(stage.layer_identifiers()))
    print("PROTOTYPES", len(stage.prototype_paths()))
    var prim = stage.prim_info("/World/Instance")
    print(
        "INSTANCE",
        prim.type_name,
        Int(prim.instance),
        Int(prim.loaded),
        Int(prim.has_payload),
        Int(prim.prototype_path.byte_length() > 0),
    )
    var proxy = stage.prim_info("/World/Instance/Mesh")
    print(
        "PROXY",
        Int(proxy.instance_proxy),
        Int(proxy.prototype_path.byte_length() > 0),
    )
    emit("VSETS", stage.variant_sets("/World"))
    emit("VARIANTS", stage.variant_names("/World", "mode"))
    print("CHOICE", stage.variant_selection("/World", "mode"))
    print("TYPE", stage.attribute_type("/World/Instance/Mesh", "points"))
    for time in stage.time_samples("/World/Instance/Mesh", "gain"):
        print("SAMPLE", time)
    for index in range(2):
        var asset = stage.asset_path(
            "/World/Instance/Mesh", "textures", index=index
        )
        print(
            "ASSET",
            index,
            asset.authored,
            asset.evaluated if asset.evaluated.byte_length() else "EMPTY",
            asset.resolved if asset.resolved.byte_length() else "EMPTY",
        )
    var animated = stage.asset_path(
        "/World/Instance/Mesh", "texture", TimeCode.at(5)
    )
    print("ANIMATED_ASSET", animated.authored)
    emit("CONNECTION", stage.connections("/World", "input"))
    emit("NO_CONNECTION", stage.connections("/World", "gain"))
    emit("META_STAGE", stage.metadata_names())
    emit("META_PRIM", stage.metadata_names("/World"))
    emit("META_ATTR", stage.metadata_names("/World", "input"))
    emit("KEY", stage.metadata_dictionary_keys("customData", "/World"))
    emit(
        "NESTED_KEY",
        stage.metadata_dictionary_keys(
            "customData", "/World", dictionary="nested"
        ),
    )
    var leaf = stage.read_metadata(
        "customData", "/World", dictionary="nested:label"
    )
    print("LEAF", leaf.type_name, leaf.texts[0])
    var layer = stage.read_metadata("customLayerData", dictionary="revision")
    print("LAYER_LEAF", layer.integers[0])
    var doc = stage.read_metadata("documentation", "/World", "input")
    print("DOC", doc.texts[0])
    var uv = read_primvar(stage, "/World/Instance/Mesh", "st")
    print(
        "PRIMVAR",
        uv.interpolation,
        uv.element_size,
        uv.unauthored_values_index,
        len(uv.indices),
    )
    var fallback = read_primvar(stage, "/World/Instance/Mesh", "fallback")
    print(
        "FALLBACK",
        fallback.interpolation,
        fallback.element_size,
        fallback.unauthored_values_index,
    )
    var normals = read_normals(stage, "/World/Instance/Mesh")
    print("NORMALS", normals.interpolation)
    stage.set_payload_loaded("/World/Payload", True)
    emit("LOADED_AFTER", stage.loaded_paths())
    assert_true(stage.prim_info("/World/Payload").loaded)
    assert_equal(stage.mesh("/World/Payload/Mesh").point_count(), 3)
    stage.set_payload_loaded("/World/Payload", False)
    assert_true(not stage.prim_info("/World/Payload").loaded)
    stage.set_instanceable("/World/Instance", False)
    assert_true(not stage.prim_info("/World/Instance").instance)
    stage.set_time_range(1, 10, 60, 30)
    assert_equal(stage.stage_info().frames_per_second, 30.0)
    var failed = False
    try:
        stage.set_time_range(10, 1)
    except:
        failed = True
    assert_true(failed)
    assert_equal(stage.stage_info().start_time, 1.0)
    failed = False
    try:
        _ = stage.asset_path("/World/Instance/Mesh", "textures", index=2)
    except:
        failed = True
    assert_true(failed)
    failed = False
    try:
        _ = stage.variant_names("/World", "missing")
    except:
        failed = True
    assert_true(failed)
    failed = False
    try:
        _ = stage.read_metadata("customData", "/World")
    except:
        failed = True
    assert_true(failed)
    var output = Stage(args[2], create=True)
    output.define_prim("/Imported", "Xform")
    output.add_payload("/Imported", args[3], "/Asset")
    assert_equal(output.mesh("/Imported/Mesh").point_count(), 3)
    output.save()
    var broken = Stage(args[4])
    assert_true(len(broken.composition_errors()) > 0)
    print("PASS_INFO")
