"""Check a Hydra cube render against projected geometry and an installed archive."""

import json
import platform

from pxr import Gf, Usd, UsdGeom
from build import BUILD, ROOT, build, require_compile
from evidence import source_hash
from package import package, compile_installed
from render_support import image_pixels, render_metadata, run_renderer, write_png


def main():
    initial = source_hash(ROOT)
    build(imaging=True)
    work = BUILD / "imaging"
    work.mkdir(parents=True, exist_ok=True)
    filename = work / "cube.usda"
    filename.unlink(missing_ok=True)
    stage = Usd.Stage.CreateNew(str(filename))
    cube = UsdGeom.Cube.Define(stage, "/Cube")
    cube.CreateSizeAttr(1)
    UsdGeom.Gprim(cube).CreateDisplayColorAttr([(0.8, 0.2, 0.1)])
    camera = UsdGeom.Camera.Define(stage, "/Camera")
    camera.AddTranslateOp().Set(Gf.Vec3d(0, 0, 5))
    camera.CreateVerticalApertureAttr(20)
    camera.CreateFocalLengthAttr(50)
    stage.GetRootLayer().Save()
    del stage
    binary = work / "render"
    require_compile(
        ROOT / "tests/imaging.mojo",
        binary,
        ROOT / "src",
        extra_flags=("-Xlinker", "-lusd_mojo_imaging"),
    )
    raw = run_renderer(binary, filename, work / "render.log", timeout=90)
    metadata = render_metadata(raw)
    pixels = image_pixels(raw)
    assert len(pixels) == 4096, len(pixels)
    center = pixels[32 * 64 + 32]
    assert center[0] > center[1] > center[2] and center[3] > 0.9, center
    assert pixels[0][3] < 0.01, pixels[0]
    foreground = sum(pixel[3] > 0.5 for pixel in pixels)
    # Nearest cube face is 4.5 units from the pinhole. Rasterization can change
    # each projected edge by one pixel; this expectation is camera geometry.
    projected_width = 64 * 50 / (20 * 4.5)
    assert abs(foreground**0.5 - projected_width) <= 2, (foreground, projected_width)
    write_png(work / "cube.png", pixels, 64, 64)
    installed = package(imaging=True)
    packaged_binary = work / "packaged-render"
    compile_installed(
        installed, ROOT / "tests/imaging.mojo", packaged_binary, imaging=True
    )
    packaged_raw = run_renderer(packaged_binary, filename, work / "packaged-render.log", timeout=90)
    assert render_metadata(packaged_raw) == metadata
    packaged_pixels = image_pixels(packaged_raw)
    assert packaged_pixels == pixels, (
        "Installed imaging package changed rendered pixels"
    )
    assert source_hash(ROOT) == initial, "Source changed during imaging checks"
    report = {
        "status": "passed",
        "source_sha256": initial,
        "machine": platform.machine(),
        **metadata,
        "width": 64,
        "height": 64,
        "foreground_pixels": foreground,
        "center_rgba": center,
        "installed_imaging_package": "passed",
        "scope": "Cube silhouette/color and source/installed CPU readback.",
    }
    (work / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
