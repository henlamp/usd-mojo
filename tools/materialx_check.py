"""Native MaterialX shader parity, actual Metal pixels and an installed consumer."""

import argparse
import hashlib
import json
import math
import os
import subprocess
from pathlib import Path

from build import BUILD, ROOT, build, require_compile, require_rejection
from evidence import source_hash
from render_support import named_pixels, run_renderer, write_png
from package import package, compile_installed


def inspect(raw):
    sources = {}
    for name in ("MSL", "GLSL"):
        sources[name.lower()] = (
            raw.split("SOURCE_BEGIN_" + name + "\n", 1)[1]
            .split("SOURCE_END_" + name, 1)[0]
            .strip()
        )
    frames = named_pixels(
        raw, ("original", "edited", "retained", "detached", "old_image")
    )
    for name, pixels in frames.items():
        assert len(pixels) == 32 * 24
        for index, pixel in enumerate(pixels):
            expected = (
                (index % 32 + 0.5) / 32,
                0.1 if name == "edited" else 0.4,
                0.8,
                1,
            )
            assert all(
                math.isfinite(a) and abs(a - b) < 2e-6
                for a, b in zip(pixel, expected, strict=True)
            ), (name, index, pixel, expected)
    assert all(
        frames[name] == frames["original"]
        for name in ("retained", "detached", "old_image")
    )
    return sources, frames


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--oracle-python", type=Path, required=True)
    args = parser.parse_args()
    prefix = Path(os.environ["USD_MOJO_MATERIALX_PREFIX"]).resolve()
    initial = source_hash(ROOT)
    build(materialx=True)
    work = BUILD / "materialx"
    work.mkdir(parents=True, exist_ok=True)
    fixture = ROOT / "tests/fixtures/materialx-gradient.mtlx"
    before = fixture.read_bytes()
    # Keep failure fixtures in the build directory, not beside tracked sources.
    local_fixture = work / fixture.name
    local_fixture.write_bytes(before)
    local_fixture.with_name(local_fixture.name + ".malformed").write_text("<materialx><broken>")
    binary = work / "materialx"
    require_compile(
        ROOT / "tests/materialx.mojo",
        binary,
        ROOT / "src",
        extra_flags=("-Xlinker", "-lusd_mojo_materialx"),
    )

    def run(executable, name):
        return inspect(
            run_renderer(
                executable,
                local_fixture,
                work / (name + ".log"),
                timeout=120,
                arguments=(prefix, work / (name + "-edited.mtlx")),
            )
        )

    sources, frames = run(binary, "source")
    for name, pixels in frames.items():
        write_png(work / (name + ".png"), pixels, 32, 24)
    oracle = work / "oracle.json"
    subprocess.run(
        [
            str(args.oracle_python),
            str(ROOT / "tools/materialx_oracle.py"),
            str(fixture),
            str(prefix),
            str(oracle),
        ],
        check=True,
    )
    expected = json.loads(oracle.read_text())
    assert expected["version"] == "1.39.5" and expected["renderables"] == ["out"]
    for target in ("msl", "glsl"):
        assert sources[target] == expected[target].strip(), (
            target + " source differs from independent SDK"
        )
    require_rejection(
        ROOT / "tests/reject_materialx_escape.mojo",
        work / "rejected",
        ROOT / "src",
        diagnostics=("origin", "lifetime", "escape"),
        extra_flags=("-Xlinker", "-lusd_mojo_materialx"),
    )
    installed = package(materialx=True)
    packaged = work / "packaged"
    compile_installed(
        installed, ROOT / "tests/materialx.mojo", packaged,
        materialx=True, materialx_prefix=prefix,
    )
    installed_sources, installed_frames = run(packaged, "installed")
    assert (
        installed_sources == sources
        and installed_frames == frames
        and fixture.read_bytes() == before
        and source_hash(ROOT) == initial
    )
    report = {
        "status": "passed",
        "source_sha256": initial,
        "materialx": "1.39.5",
        "native_document_validation": True,
        "independent_shader_sources": ["glsl", "msl"],
        "rendered_frames": list(frames),
        "width": 32,
        "height": 24,
        "installed_consumer": "passed",
        "source_unchanged": True,
        "pixel_sha256": {
            k: hashlib.sha256(json.dumps(v).encode()).hexdigest()
            for k, v in frames.items()
        },
        "scope": "Metal texture-space pixels, GLSL/MSL source parity and installed-archive parity.",
    }
    (work / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
