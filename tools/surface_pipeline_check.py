"""Measure MaterialX lighting, texture coordinates, opacity and shader edits."""

import argparse
import hashlib
import json
import math
import os
import subprocess
from pathlib import Path

from build import BUILD, ROOT, build, require_compile
from evidence import source_hash
from render_support import named_pixels, run_renderer, write_png, render_metadata
from package import package, compile_installed


def fixtures(work):
    texture = [
        (1, 0, 0, 1) if x < 16 else (0, 1, 0, 1) for y in range(32) for x in range(32)
    ]
    write_png(work / "checker.png", texture, 32, 32)
    for name in ("lit", "opacity", "texture"):
        graph = ""
        if name == "texture":
            graph = '<image name="image" type="color3"><input name="file" type="filename" value="checker.png" colorspace="lin_rec709"/></image>'
            surface = '<surface_unlit name="surface" type="surfaceshader"><input name="emission" type="float" value="1"/><input name="emission_color" type="color3" nodename="image"/></surface_unlit>'
        else:
            opacity = "0.25, 0.25, 0.25" if name == "opacity" else "1, 1, 1"
            surface = (
                '<standard_surface name="surface" type="surfaceshader"><input name="base" type="float" value="1"/><input name="base_color" type="color3" value="0.1, 0.8, 0.2"/><input name="specular_roughness" type="float" value="0.2"/><input name="opacity" type="color3" value="'
                + opacity
                + '"/></standard_surface>'
            )
        (work / (name + ".mtlx")).write_text(
            '<?xml version="1.0"?><materialx version="1.39">'
            + graph
            + surface
            + '<surfacematerial name="paint" type="material"><input name="surfaceshader" type="surfaceshader" nodename="surface"/></surfacematerial></materialx>'
        )


def inspect(raw, name):
    names = (
        ("base", "dark", "edited", "rough", "retained")
        if name == "lit"
        else ("base", "opaque" if name == "opacity" else "uv_shift", "retained")
    )
    frames = named_pixels(raw, names)
    for label, pixels in frames.items():
        assert len(pixels) == 4096 and all(
            len(p) == 4 and all(math.isfinite(c) for c in p) for p in pixels
        ), label
    assert frames["retained"] == frames["base"]
    center = 32 * 64 + 32
    if name == "lit":
        base, dark, edited, rough = (
            frames[k][center] for k in ("base", "dark", "edited", "rough")
        )
        assert base[1] > base[0] and max(base[:3]) > 0.1
        assert max(abs(v) for v in dark[:3]) < 1e-6
        assert edited[0] > edited[1] and abs(edited[0] - base[0]) > 0.01
        assert abs(rough[0] - edited[0]) > 0.05
    elif name == "opacity":
        base, opaque = frames["base"][center], frames["opaque"][center]
        assert abs(base[3] - 0.25) < 1e-6 and abs(opaque[3] - 1) < 1e-6
        assert all(abs(base[i] * 4 - opaque[i]) < 2e-3 for i in range(3))
    else:
        for x, channel in ((16, 0), (48, 1)):
            base, shifted = frames["base"][32 * 64 + x], frames["uv_shift"][32 * 64 + x]
            assert base[channel] > 0.95 and shifted[1 - channel] > 0.95
    return frames


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--oracle-python", type=Path, required=True)
    args = parser.parse_args()
    initial = source_hash(ROOT)
    sdk = Path(os.environ["USD_MOJO_SDK_PREFIX"]).resolve()
    mx = Path(os.environ["USD_MOJO_MATERIALX_PREFIX"]).resolve()
    build(imaging=True, materialx=True)
    work = BUILD / "surface-pipeline"
    work.mkdir(parents=True, exist_ok=True)
    fixtures(work)
    binary = work / "render"
    require_compile(
        ROOT / "tests/surface_pipeline.mojo",
        binary,
        ROOT / "src",
        extra_flags=(
            "-Xlinker",
            "-lusd_mojo_imaging",
            "-Xlinker",
            "-lusd_mojo_materialx",
        ),
    )
    reports = {}
    all_frames = {}
    metadata = None
    for name in ("lit", "opacity", "texture"):
        scene = work / (name + ".usda")
        scene.unlink(missing_ok=True)
        raw = run_renderer(
            binary,
            work / (name + ".mtlx"),
            work / (name + ".log"),
            arguments=(scene, name, mx),
        )
        actual = render_metadata(raw)
        if metadata is not None:
            assert actual == metadata
        metadata = actual
        frames = inspect(raw, name)
        all_frames[name] = frames
        oracle = work / (name + "-oracle.json")
        subprocess.run(
            [
                str(args.oracle_python),
                str(ROOT / "tools/materialx_oracle.py"),
                str(work / (name + ".mtlx")),
                str(mx),
                str(oracle),
                "paint",
            ],
            check=True,
        )
        expected = json.loads(oracle.read_text())
        for target in ("msl", "glsl"):
            actual = (
                raw.split("SOURCE_BEGIN_" + target + "\n", 1)[1]
                .split("SOURCE_END_" + target, 1)[0]
                .strip()
            )
            assert actual == expected[target].strip(), (name, target)
        for label, pixels in frames.items():
            write_png(work / (name + "-" + label + ".png"), pixels, 64, 64)
        reports[name] = {
            "frames": list(frames),
            "center_rgba": {k: v[32 * 64 + 32] for k, v in frames.items()},
        }
        print(name, json.dumps(reports[name]), flush=True)
    installed = package(imaging=True, materialx=True)
    consumer = work / "installed"
    compile_installed(
        installed, ROOT / "tests/surface_pipeline.mojo", consumer,
        imaging=True, materialx=True, sdk_prefix=sdk, materialx_prefix=mx,
    )
    for name in reports:
        scene = work / (name + "-installed.usda")
        scene.unlink(missing_ok=True)
        raw = run_renderer(
            consumer,
            work / (name + ".mtlx"),
            work / (name + "-installed.log"),
            arguments=(scene, name, mx),
        )
        assert render_metadata(raw) == metadata
        assert inspect(raw, name) == all_frames[name], name
    missing = work / "missing.mtlx"
    missing.write_text(
        (work / "texture.mtlx").read_text().replace("checker.png", "missing.png")
    )
    scene = work / "missing.usda"
    scene.unlink(missing_ok=True)
    try:
        run_renderer(
            binary,
            missing,
            work / "missing.log",
            arguments=(scene, "texture", mx),
        )
    except subprocess.CalledProcessError:
        assert "missing.png" in (work / "missing.log").read_text()
    else:
        raise AssertionError("Missing texture silently produced a fallback image")
    assert source_hash(ROOT) == initial
    (work / "verification.json").write_text(
        json.dumps(
            {
                "status": "passed",
                **metadata,
                "source_sha256": initial,
                "cases": reports,
                "independent_shader_sources": ["glsl", "msl"],
                "installed_consumer": "passed",
                "missing_texture_rejected": True,
                "sdk_identity": hashlib.sha256(
                    (sdk / "usd-mojo-sdk.json").read_bytes()
                ).hexdigest(),
                "scope": "Lit standard-surface, opacity, texture/UV edits and installed-archive parity.",
            },
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    main()
