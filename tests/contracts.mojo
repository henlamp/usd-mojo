"""Semantic composition, time, ownership and save/export acceptance."""
from std.sys import argv
from std.testing import assert_equal, assert_true
from usd_mojo import MeshData, Stage, TimeCode, sdk_version


def independent_mesh(var filename: String) raises -> MeshData:
    var stage = Stage(filename)
    var moved = stage^
    return moved.mesh("/World/Robot/Triangle")


def main() raises:
    var args = argv()
    var stage = Stage(args[1])
    var path = String("/World/Robot/Triangle")
    assert_equal(sdk_version(), 2608)
    assert_equal(stage.up_axis(), String("Z"))
    assert_equal(stage.meters_per_unit(), Float64(1))
    assert_equal(stage.time_codes_per_second(), Float64(60))
    var paths = stage.prim_paths()
    assert_equal(len(paths), 4)
    assert_equal(stage.prim_type(path), String("Mesh"))
    assert_equal(stage.read_text("/World/Robot", "colorLabel"), String("blue"))
    assert_equal(stage.read_text(path, "label"), String("Dreieck 🔥"))
    assert_true(stage.read_bool(path, "enabled"))
    assert_equal(stage.read_float(path, "gain"), Float64(1.5))
    assert_equal(stage.read_float(path, "gain", TimeCode.at(0)), Float64(2))
    # Referenced 24 fps asset is retimed into the root stage's 60 fps.
    assert_true(
        abs(stage.read_float(path, "gain", TimeCode.at(1)) - 2.4) < 1e-12
    )
    var matrix = stage.world_transform(path)
    assert_equal(matrix[12], Float64(11))
    assert_equal(matrix[13], Float64(2))
    assert_equal(matrix[14], Float64(3))
    var mesh = stage.mesh(path)
    assert_equal(mesh.point_count(), 3)
    assert_equal(mesh.face_count(), 1)
    assert_equal(mesh.face_vertex_counts[0], Int32(3))
    assert_equal(mesh.face_vertex_indices[2], Int32(2))
    var animated = stage.mesh(path, TimeCode.at(1))
    assert_equal(animated.points[2], Float32(0.4))
    var attrs = stage.attribute_names(path)
    assert_true(len(attrs) > 5)

    # Values outlive the stage; moving the owner does not duplicate it.
    var detached = independent_mesh(args[1])
    detached.points[0] = 42
    assert_equal(stage.mesh(path).points[0], Float32(0))

    var rejected = False
    try:
        var bad = stage.read_float(path, "label")
        _ = bad
    except:
        rejected = True
    assert_true(rejected)
    rejected = False
    try:
        var bad = stage.mesh("/World/Empty")
        _ = bad
    except:
        rejected = True
    assert_true(rejected)
    rejected = False
    try:
        var bad = stage.prim_type("relative/path")
        _ = bad
    except:
        rejected = True
    assert_true(rejected)
    rejected = False
    try:
        var bad = stage.read_float(path, "missing")
        _ = bad
    except:
        rejected = True
    assert_true(rejected)
    rejected = False
    try:
        stage.set_bool(path, "label", True)
    except:
        rejected = True
    assert_true(rejected)
    # Failed operations do not poison subsequent reads.
    assert_equal(stage.read_text(path, "label"), String("Dreieck 🔥"))

    var output = Stage(args[2], create=True)
    output.define_prim("/Saved", "Xform")
    output.set_float("/Saved", "gain", 2.5)
    output.set_float("/Saved", "gain", 8, TimeCode.at(0))
    output.set_float("/Saved", "gain", 10, TimeCode.at(2))
    output.set_bool("/Saved", "enabled", True)
    output.set_text("/Saved", "label", "Grüße 🔥")
    output.save()
    var reopened = Stage(args[2])
    assert_equal(reopened.read_float("/Saved", "gain"), Float64(2.5))
    assert_equal(
        reopened.read_float("/Saved", "gain", TimeCode.at(1)), Float64(9)
    )
    assert_equal(reopened.read_text("/Saved", "label"), String("Grüße 🔥"))
    assert_true(reopened.read_bool("/Saved", "enabled"))
    stage.export(args[3])
    var binary = Stage(args[3])
    assert_equal(binary.mesh(path).face_count(), 1)
    assert_equal(binary.read_text("/World/Robot", "colorLabel"), String("blue"))
    var moved = output^
    assert_true(moved.read_bool("/Saved", "enabled"))
    print(
        "PASS composition, variants, interpolation, ownership, edits, USDA/USDC"
    )
