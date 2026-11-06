# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Animated camera/scene updates, independent readbacks and caller-buffer reuse."""
from std.collections import ImmSpan, MutSpan
from std.ffi import external_call
from std.sys import argv
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns
from usd_mojo import Stage, TimeCode, Value, UsdErrorKind, remove_prim, ArraySnapshot, set_array
from usd_mojo.imaging import RenderSession, RenderImage


def retained(filename: String) raises -> RenderSession:
    var stage = Stage(filename)
    return RenderSession(stage, 96, 64)


def emit(name: String, mut session: RenderSession) raises:
    var image = session.readback()
    assert_true(image.converged)
    for i in range(image.width * image.height):
        var pixels = image.pixels()
        print("PIX", name, pixels[4*i], pixels[4*i+1], pixels[4*i+2], pixels[4*i+3])


def centroid(pixels: List[Float32]) -> Float64:
    var weighted = Float64(0)
    var area = Float64(0)
    for j in range(len(pixels) // 4):
        var alpha = Float64(pixels[4*j+3])
        weighted += Float64(j % 96) * alpha
        area += alpha
    return weighted / area


def main() raises:
    var filename = argv()[1]
    var detached = retained(filename)
    detached.render("/Camera", TimeCode.at(0), lighting=False)
    assert_true(detached.converged)
    var detached_image = detached.readback()
    assert_equal(detached_image.width, 96)

    var stage = Stage(filename)
    var session = RenderSession(stage, 96, 64)
    print("RENDER_BACKEND", session.backend())
    print("RENDERER_PLUGIN", session.renderer())
    var rejected = False
    try:
        var invalid = session.readback()
        _ = invalid
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_argument)
        rejected = True
    assert_true(rejected)
    session.render("/Camera", TimeCode.at(0), lighting=False)
    assert_equal(session.frame, UInt64(1))
    emit("base", session)
    var first = session.readback()
    var checksum = Float64(0)
    for value in first.pixels():
        checksum += Float64(value)
    var output = List[Float32](length=96*64*4, fill=-77)
    session.read_into(MutSpan(output))
    for i in range(len(output)):
        assert_equal(output[i], first.pixels()[i])
    var short = List[Float32](length=3, fill=-77)
    rejected = False
    try:
        session.read_into(MutSpan(short))
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_argument)
        rejected = True
    assert_true(rejected)
    for value in short:
        assert_equal(value, Float32(-77))

    session.render("/Camera", TimeCode.at(1), lighting=False)
    emit("animated", session)
    stage.set_value("/Cube", "primvars:displayColor", Value.floating("color3f[]", [0.1, 0.8, 0.2]))
    session.render("/Camera", TimeCode.at(1), lighting=False)
    emit("color", session)
    session.render("/Camera2", TimeCode.at(1), lighting=False)
    emit("camera", session)
    remove_prim(stage, "/Cube")
    session.render("/Camera", lighting=False)
    emit("removed", session)
    stage.define_prim("/Cube", "Cube")
    stage.set_value("/Cube", "size", Value.floating("double", [1.0]))
    stage.set_value("/Cube", "primvars:displayColor", Value.floating("color3f[]", [0.2, 0.3, 0.9]))
    session.render("/Camera", lighting=False)
    emit("restored", session)
    stage.set_value("/Camera", "clippingPlanes", Value.floating("float4[]", [1.0, 0, 0, 0]))
    session.render("/Camera", lighting=False)
    emit("clipped", session)
    stage.set_value("/Camera", "xformOp:translate", Value.floating("double3", [0.25, 0, 5]))
    session.render("/Camera", lighting=False)
    emit("clip_moved", session)
    session.render("/ClipCamera", lighting=False)
    emit("clip_rotated", session)
    stage.set_value("/Camera", "xformOp:translate", Value.floating("double3", [0.0, 0, 5]))
    stage.set_value("/Camera", "clippingPlanes", Value.floating("float4[]", List[Float64]()))
    session.render("/Camera", lighting=False)
    emit("clip_cleared", session)
    stage.set_value("/Cube", "visibility", Value.text("token", [String("invisible")]))
    stage.set_value("/Mesh", "visibility", Value.text("token", [String("inherited")]))
    var old_points = ArraySnapshot(stage, "/Mesh", "points")
    session.render("/Camera", lighting=False)
    emit("mesh_before", session)
    var changed_points = List[Float32](length=12, fill=0)
    for i in range(12):
        changed_points[i] = old_points.view[DType.float32]()[i]
        if i % 3 == 0:
            changed_points[i] += 1.1
    set_array(stage, "/Mesh", "points", "point3f[]", ImmSpan(changed_points))
    changed_points[0] = 999
    session.render("/Camera", lighting=False)
    emit("mesh_after", session)
    assert_equal(old_points.view[DType.float32]()[0], Float32(-1.05))
    stage.set_value("/Mesh", "visibility", Value.text("token", [String("invisible")]))
    stage.set_value("/Cube", "visibility", Value.text("token", [String("inherited")]))
    var unchanged = Float64(0)
    for value in first.pixels():
        unchanged += Float64(value)
    assert_equal(unchanged, checksum)

    rejected = False
    var frame_before = session.frame
    try:
        session.render("/MissingCamera", lighting=False)
    except error:
        assert_equal(error.kind, UsdErrorKind.not_found)
        rejected = True
    assert_true(rejected)
    assert_equal(session.frame, frame_before)
    rejected = False
    try:
        session.read_into(MutSpan(output))
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_argument)
        rejected = True
    assert_true(rejected)
    var moved = session^
    for _ in range(5):
        moved.render("/Camera", lighting=False)
        moved.read_into(MutSpan(output))
    var rss_before = external_call["usdm_test_current_rss", Int64]()
    var live_before = external_call["usdm_test_live_allocated", Int64]()
    for i in range(30):
        stage.set_value("/Camera", "xformOp:translate", Value.floating("double3", [Float64(i % 2) * 0.1, 0, 5]))
        var start = perf_counter_ns()
        moved.render("/Camera", lighting=False)
        var rendered = perf_counter_ns()
        moved.read_into(MutSpan(output))
        var end = perf_counter_ns()
        assert_true(moved.converged)
        print("TIMING", "retained", i, rendered-start, end-rendered, end-start)
        print("CENTROID", "retained", i, centroid(output))
    print("MEMORY", rss_before, external_call["usdm_test_current_rss", Int64](), live_before, external_call["usdm_test_live_allocated", Int64]())
    for i in range(10):
        stage.set_value("/Camera", "xformOp:translate", Value.floating("double3", [Float64(i % 2) * 0.1, 0, 5]))
        var start = perf_counter_ns()
        var fresh = RenderSession(stage, 96, 64)
        var opened = perf_counter_ns()
        fresh.render("/Camera", lighting=False)
        var rendered = perf_counter_ns()
        fresh.read_into(MutSpan(output))
        var end = perf_counter_ns()
        print("TIMING", "new", i, rendered-opened, end-rendered, end-start, opened-start)
        print("CENTROID", "new", i, centroid(output))
    print("PASS persistent rendering, stage/image ownership, updates, rejected reads and reusable buffers")
