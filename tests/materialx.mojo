# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
from std.sys import argv
from std.testing import assert_equal, assert_true
from usd_mojo import UsdErrorKind
from usd_mojo.materialx import MaterialXDocument, MaterialXShader, MaterialXImage


def detached(filename: String, library: String) raises -> MaterialXShader:
    var document = MaterialXDocument(filename, library)
    return document.shader("out")


def emit(name: String, image: MaterialXImage):
    var pixels = image.pixels()
    for i in range(image.width * image.height):
        print(
            "PIX",
            name,
            pixels[4 * i],
            pixels[4 * i + 1],
            pixels[4 * i + 2],
            pixels[4 * i + 3],
        )


def main() raises:
    var a = argv()
    var failed = False
    try:
        var absent = MaterialXDocument(a[1] + ".missing", a[2])
        _ = absent
    except error:
        assert_equal(error.kind, UsdErrorKind.io)
        failed = True
    assert_true(failed)
    failed = False
    try:
        var malformed = MaterialXDocument(a[1] + ".malformed", a[2])
        _ = malformed
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_data)
        failed = True
    assert_true(failed)
    var document = MaterialXDocument(a[1], a[2])
    assert_equal(len(document.validate()), 0)
    assert_equal(document.renderables()[0], String("out"))
    var original = document.content()
    var shader = document.shader("out")
    print("SOURCE_BEGIN_MSL")
    print(shader.source())
    print("SOURCE_END_MSL")
    var glsl = document.shader("out", target="glsl")
    print("SOURCE_BEGIN_GLSL")
    print(glsl.source())
    print("SOURCE_END_GLSL")
    var first = shader.render(32, 24)
    emit("original", first)
    document.set_input("combine", "in2", "float", "0.1")
    assert_equal(len(document.validate()), 0)
    var next = document.shader("out")
    var second = next.render(32, 24)
    emit("edited", second)
    var repeated = shader.render(32, 24)
    emit("retained", repeated)
    var before = document.content()
    failed = False
    try:
        document.set_input("combine", "in2", "color3", "0,1,0")
    except error:
        assert_equal(error.kind, UsdErrorKind.type_mismatch)
        failed = True
    assert_true(failed)
    assert_equal(document.content(), before)
    failed = False
    try:
        var missing = document.shader("missing")
        _ = missing
    except error:
        assert_equal(error.kind, UsdErrorKind.not_found)
        failed = True
    assert_true(failed)
    failed = False
    try:
        document.save(a[3] + "/missing/output.mtlx")
    except error:
        assert_equal(error.kind, UsdErrorKind.io)
        failed = True
    assert_true(failed)
    failed = False
    try:
        var invalid = document.shader("out", target="invalid")
        _ = invalid
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_argument)
        failed = True
    assert_true(failed)
    document.save(a[3])
    var roundtrip = MaterialXDocument(a[3], a[2])
    assert_equal(roundtrip.content(), document.content())
    var held = detached(a[1], a[2])
    var independent = held.render(32, 24)
    emit("detached", independent)
    emit("old_image", first)
    assert_true(original != document.content())
    print(
        "PASS native MaterialX documents, shader sources, Metal pixels, ownership and"
        " errors"
    )
