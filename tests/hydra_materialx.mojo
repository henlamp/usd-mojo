# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
from std.sys import argv
from std.testing import assert_true, assert_equal
from usd_mojo import Stage, Value, bound_material
from usd_mojo.imaging import RenderSession


def main() raises:
    var a = argv()
    var material = Stage(a[1])
    var path = String("")
    for candidate in material.prim_paths():
        print("MATERIAL_PRIM", candidate, material.prim_type(candidate))
        if path == "" and material.prim_type(candidate) == "Material":
            path = candidate.copy()
    assert_true(path != "")
    var stage = Stage(a[2], create=True)
    stage.define_prim("/Material", "Material")
    stage.add_reference("/Material", a[1], path)
    stage.define_prim("/Cube", "Cube")
    stage.set_value("/Cube", "size", Value.floating("double", [Float64(1)]))
    stage.set_value(
        "/Cube", "primvars:displayColor", Value.floating("color3f[]", [0.9, 0.1, 0.1])
    )
    stage.apply_schema("/Cube", "MaterialBindingAPI")
    stage.add_relationship_target("/Cube", "material:binding", "/Material")
    assert_equal(bound_material(stage, "/Cube"), String("/Material"))
    stage.define_prim("/Camera", "Camera")
    stage.set_value(
        "/Camera", "xformOp:translate", Value.floating("double3", [0, 0, 5])
    )
    stage.set_value(
        "/Camera", "xformOpOrder", Value.text("token[]", [String("xformOp:translate")])
    )
    stage.set_value(
        "/Camera", "verticalAperture", Value.floating("float", [Float64(20)])
    )
    stage.set_value("/Camera", "focalLength", Value.floating("float", [Float64(50)]))
    var session = RenderSession(stage, 64, 64)
    print("RENDER_BACKEND", session.backend())
    print("RENDERER_PLUGIN", session.renderer())
    session.render("/Camera", max_iterations=16)
    var image = session.readback()
    assert_true(image.converged)
    for i in range(64 * 64):
        var p = image.pixels()
        print("PIX", "material", p[4 * i], p[4 * i + 1], p[4 * i + 2], p[4 * i + 3])
    assert_true(stage.has_attribute("/Material", "inputs:emission_color"))
    stage.set_value(
        "/Material",
        "inputs:emission_color",
        Value.floating(
            stage.attribute_type("/Material", "inputs:emission_color"), [0.2, 0.3, 0.9]
        ),
    )
    session.render("/Camera", max_iterations=16)
    var changed = session.readback()
    assert_true(changed.converged)
    for i in range(64 * 64):
        var p = changed.pixels()
        print("PIX", "edited", p[4 * i], p[4 * i + 1], p[4 * i + 2], p[4 * i + 3])
    assert_true(image.pixels()[4 * (32 * 64 + 32) + 1] > Float32(0.7))
    print(
        "PASS MaterialX file format, USD reference, binding, Hydra shading and"
        " input edits"
    )
