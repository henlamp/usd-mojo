# SPDX-FileCopyrightText: 2026 henlamp
# SPDX-License-Identifier: MIT
"""Render output remains owned after closing the source stage."""
from std.sys import argv
from std.testing import assert_equal, assert_true
from usd_mojo import Stage, UsdErrorKind
from usd_mojo.imaging import RenderImage, RenderSession, renderer_plugins


def retained(filename: String) raises -> RenderImage:
    var stage = Stage(filename)
    var session = RenderSession(stage, 64, 64)
    print("RENDER_BACKEND", session.backend())
    print("RENDERER_PLUGIN", session.renderer())
    session.render("/Camera", lighting=False)
    return session.readback()


def main() raises:
    var filename = argv()[1]
    var stage = Stage(filename)
    assert_true(len(renderer_plugins()) > 0)
    var rejected = False
    try:
        var invalid = RenderImage(stage, "/Camera", 0, 64)
        _ = invalid
    except error:
        assert_equal(error.kind, UsdErrorKind.invalid_argument)
        rejected = True
    assert_true(rejected)
    var image = retained(filename)
    assert_equal(image.width, 64)
    assert_equal(image.height, 64)
    assert_true(image.converged)
    var one_shot = RenderImage(stage, "/Camera", 64, 64, lighting=False)
    for i in range(len(image.pixels())):
        assert_equal(one_shot.pixels()[i], image.pixels()[i])
    var pixels = image.pixels()
    assert_equal(len(pixels), 64 * 64 * 4)
    for i in range(64 * 64):
        print(
            "PIX",
            pixels[4 * i],
            pixels[4 * i + 1],
            pixels[4 * i + 2],
            pixels[4 * i + 3],
        )
    print("PASS optional Hydra rendering and image ownership")
