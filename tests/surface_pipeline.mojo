# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
from std.sys import argv
from std.testing import assert_true, assert_equal
from usd_mojo import Stage, Value, Metadata, set_metadata, bound_material, UsdErrorKind
from usd_mojo.imaging import RenderSession, RenderImage
from usd_mojo.materialx import MaterialXDocument


def pixels(image: RenderImage, name: String):
    var p = image.pixels()
    for i in range(64 * 64):
        print("PIX", name, p[4*i], p[4*i+1], p[4*i+2], p[4*i+3])


def main() raises:
    var a = argv()
    var document = MaterialXDocument(a[1], a[4])
    assert_equal(len(document.validate()), 0)
    for target in [String("msl"), String("glsl")]:
        var shader = document.shader("paint", target=target)
        print("SOURCE_BEGIN_" + target)
        print(shader.source())
        print("SOURCE_END_" + target)
        var rejected = False
        try:
            var invalid = shader.render(8, 8)
            _ = invalid
        except error:
            assert_equal(error.kind, UsdErrorKind.unsupported)
            rejected = True
        assert_true(rejected)
    var source = Stage(a[1])
    var material_path = String("")
    for path in source.prim_paths():
        if material_path == "" and source.prim_type(path) == "Material":
            material_path = path.copy()
    assert_true(material_path != "")
    var stage = Stage(a[2], create=True)
    stage.define_prim("/Material", "Material")
    stage.add_reference("/Material", a[1], material_path)
    stage.define_prim("/Mesh", "Mesh")
    stage.set_value("/Mesh", "points", Value.floating("point3f[]", [-1,-1,0, 1,-1,0, 1,1,0, -1,1,0]))
    stage.set_value("/Mesh", "faceVertexCounts", Value.signed("int[]", [4]))
    stage.set_value("/Mesh", "faceVertexIndices", Value.signed("int[]", [0,1,2,3]))
    stage.set_value("/Mesh", "subdivisionScheme", Value.text("token", [String("none")]))
    stage.set_value("/Mesh", "normals", Value.floating("normal3f[]", [0,0,1, 0,0,1, 0,0,1, 0,0,1]))
    stage.set_value("/Mesh", "primvars:st", Value.floating("texCoord2f[]", [0,0, 1,0, 1,1, 0,1]))
    var vertex = Metadata(Value.text("token", [String("vertex")]))
    set_metadata(stage, "interpolation", vertex, path="/Mesh", attribute="primvars:st")
    set_metadata(stage, "interpolation", vertex, path="/Mesh", attribute="normals")
    stage.apply_schema("/Mesh", "MaterialBindingAPI")
    stage.add_relationship_target("/Mesh", "material:binding", "/Material")
    assert_equal(bound_material(stage, "/Mesh"), String("/Material"))
    stage.define_prim("/Light", "DistantLight")
    stage.set_float("/Light", "inputs:intensity", 2000)
    stage.define_prim("/Camera", "Camera")
    stage.set_value("/Camera", "xformOp:translate", Value.floating("double3", [0,0,5]))
    stage.set_value("/Camera", "xformOpOrder", Value.text("token[]", [String("xformOp:translate")]))
    stage.set_float("/Camera", "verticalAperture", 20)
    stage.set_float("/Camera", "horizontalAperture", 20)
    stage.set_float("/Camera", "focalLength", 50)
    var session = RenderSession(stage, 64, 64)
    print("RENDER_BACKEND", session.backend())
    print("RENDERER_PLUGIN", session.renderer())
    session.render("/Camera", max_iterations=32)
    var original = session.readback()
    assert_true(original.converged)
    pixels(original, "base")
    if a[3] == "lit":
        stage.set_float("/Light", "inputs:intensity", 0)
        session.render("/Camera", max_iterations=32)
        pixels(session.readback(), "dark")
        stage.set_float("/Light", "inputs:intensity", 2000)
        stage.set_value("/Material", "inputs:base_color", Value.floating("color3f", [0.9,0.1,0.1]))
        session.render("/Camera", max_iterations=32)
        pixels(session.readback(), "edited")
        stage.set_float("/Material", "inputs:specular_roughness", 0.9)
        session.render("/Camera", max_iterations=32)
        pixels(session.readback(), "rough")
    elif a[3] == "opacity":
        stage.set_value("/Material", "inputs:opacity", Value.floating("color3f", [1,1,1]))
        session.render("/Camera", max_iterations=32)
        pixels(session.readback(), "opaque")
    else:
        stage.set_value("/Mesh", "primvars:st", Value.floating("texCoord2f[]", [0.5,0, 1.5,0, 1.5,1, 0.5,1]))
        session.render("/Camera", max_iterations=32)
        pixels(session.readback(), "uv_shift")
    pixels(original, "retained")
    stage.save()
