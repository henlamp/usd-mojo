"""Qualify actual MaterialX surface shading with the explicitly selected SDK."""

import json
import os
import subprocess
import sys
from pathlib import Path

from build import BUILD, ROOT, build, require_compile
from evidence import source_hash
from render_support import named_pixels, run_renderer, write_png, render_metadata
from package import package, compile_installed


def inspect(raw):
    frames = named_pixels(raw, ("material", "edited"))
    for name, pixels in frames.items():
        assert len(pixels) == 4096
        expected = (0.1, 0.8, 0.2) if name == "material" else (0.2, 0.3, 0.9)
        foreground = [(i, p) for i, p in enumerate(pixels) if p[3] > 0.5]
        assert foreground and pixels[0][3] < 0.01
        assert abs(len(foreground) ** 0.5 - 64 * 50 / (20 * 4.5)) < 2
        center = pixels[32 * 64 + 32]
        assert center[3] > 0.99 and all(
            abs(a - b) <= 2 / 255 for a, b in zip(center[:3], expected, strict=True)
        ), (name, center, expected)
        assert (
            all(p[1] > p[0] for i, p in foreground)
            if name == "material"
            else all(p[2] > p[0] for i, p in foreground)
        )
    return frames


def main():
    sdk = Path(os.environ["USD_MOJO_SDK_PREFIX"]).resolve()
    mx = Path(os.environ["USD_MOJO_MATERIALX_PREFIX"]).resolve()
    version = json.loads((ROOT / "tools/optional_sdks.json").read_text())
    if sdk == Path(sys.prefix).resolve():
        raise ValueError("Use the separately built MaterialX-enabled SDK")
    initial = source_hash(ROOT)
    build(imaging=True)
    work = BUILD / "hydra-materialx"
    work.mkdir(parents=True, exist_ok=True)
    fixture = ROOT / "tests/fixtures/materialx-unlit.mtlx"
    original = fixture.read_bytes()
    binary = work / "render"
    require_compile(
        ROOT / "tests/hydra_materialx.mojo",
        binary,
        ROOT / "src",
        extra_flags=("-Xlinker", "-lusd_mojo_imaging"),
    )
    metadata = None

    def run(program, label):
        nonlocal metadata
        raw = run_renderer(program, fixture, work / (label + ".log"),
                           arguments=(work / (label + ".usda"),))
        actual = render_metadata(raw)
        if metadata is not None:
            assert actual == metadata
        metadata = actual
        return inspect(raw)

    frames = run(binary, "source")
    for name, pixels in frames.items():
        write_png(work / (name + ".png"), pixels, 64, 64)
    installed = package(imaging=True)
    consumer = work / "installed"
    wrong_sdk = subprocess.run(
        [
            sys.executable,
            str(installed / "compile.py"),
            "--imaging",
            "--sdk-prefix",
            sys.prefix,
            str(ROOT / "tests/hydra_materialx.mojo"),
            "-o",
            str(work / "wrong-sdk"),
        ],
        capture_output=True,
        text=True,
    )
    assert wrong_sdk.returncode == 2 and "MaterialX-enabled" in wrong_sdk.stderr
    compile_installed(
        installed, ROOT / "tests/hydra_materialx.mojo", consumer,
        imaging=True, sdk_prefix=sdk, materialx_prefix=mx,
    )
    assert run(consumer, "installed") == frames
    assert fixture.read_bytes() == original and source_hash(ROOT) == initial
    report = {
        "status": "passed",
        "source_sha256": initial,
        "openusd": version["openusd"],
        "materialx": version["materialx"],
        **metadata,
        "width": 64,
        "height": 64,
        "frames": list(frames),
        "installed_consumer": "passed",
        "source_unchanged": True,
        "scope": "Unlit MaterialX import, binding, input edits and installed-archive parity.",
    }
    (work / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
