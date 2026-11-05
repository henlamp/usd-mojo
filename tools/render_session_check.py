"""Compare persistent frame sequences with camera geometry and installed consumers."""

import json
import math
import platform
import statistics
import subprocess
import sys

from pxr import Gf, Usd, UsdGeom
from build import BUILD, ROOT, build, lifetime_metrics, require_compile, require_rejection
from evidence import source_hash
from render_support import named_pixels, run_renderer, write_png, render_metadata, renderer_environment
from package import package

WIDTH, HEIGHT = 96, 64
NAMES = ('base', 'animated', 'color', 'camera', 'removed', 'restored',
         'clipped', 'clip_moved', 'clip_rotated', 'clip_cleared', 'mesh_before', 'mesh_after')



def fixture(filename):
    stage = Usd.Stage.CreateNew(str(filename))
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
    UsdGeom.SetStageMetersPerUnit(stage, 1)
    cube = UsdGeom.Cube.Define(stage, '/Cube')
    cube.CreateSizeAttr(1)
    cube.CreateDisplayColorAttr([(0.8, 0.2, 0.1)])
    translation = cube.AddTranslateOp()
    translation.Set(Gf.Vec3d(-0.55, 0, 0), 0)
    translation.Set(Gf.Vec3d(0.55, 0, 0), 1)
    mesh = UsdGeom.Mesh.Define(stage, '/Mesh')
    mesh.CreatePointsAttr([(-1.05,-0.5,0),(-0.05,-0.5,0),(-0.05,0.5,0),(-1.05,0.5,0)])
    mesh.CreateFaceVertexCountsAttr([4])
    mesh.CreateFaceVertexIndicesAttr([0,1,2,3])
    mesh.CreateSubdivisionSchemeAttr('none')
    mesh.CreateDisplayColorAttr([(0.9,0.8,0.1)])
    mesh.CreateVisibilityAttr('invisible')
    for name, offset in [('Camera', 0), ('Camera2', 0.45)]:
        camera = UsdGeom.Camera.Define(stage, '/'+name)
        camera.AddTranslateOp().Set(Gf.Vec3d(offset, 0, 5))
        camera.CreateVerticalApertureAttr(20)
        camera.CreateFocalLengthAttr(50)
    camera = UsdGeom.Camera.Define(stage, '/ClipCamera')
    camera.AddTranslateOp().Set(Gf.Vec3d(0, 0, 5))
    camera.AddRotateZOp().Set(90)
    camera.CreateVerticalApertureAttr(20)
    camera.CreateFocalLengthAttr(50)
    camera.CreateClippingPlanesAttr([(1, 0, 0, 0)])
    stage.GetRootLayer().Save()


def inspect_frames(output):
    frames = named_pixels(output, NAMES)
    timing = {'retained': [], 'new': []}
    motion = {'retained': [], 'new': []}
    memory = None
    for line in output.splitlines():
        parts = line.split()
        if parts[:1] == ['TIMING']:
            timing[parts[1]].append(list(map(int, parts[3:])))
        elif parts[:1] == ['CENTROID']:
            motion[parts[1]].append(float(parts[3]))
        elif parts[:1] == ['MEMORY']:
            memory = list(map(int, parts[1:]))
    observations = {}
    # Project all eight corners independently of the renderer and its matrices.
    for name, translation, camera_x, dominant in [
        ('base', -0.55, 0, 0), ('animated', 0.55, 0, 0),
        ('color', 0.55, 0, 1), ('camera', 0.55, 0.45, 1), ('restored', 0, 0, 2),
        ('mesh_before', -0.55, 0, 0), ('mesh_after', 0.55, 0, 0),
    ]:
        pixels = frames[name]
        assert len(pixels) == WIDTH*HEIGHT and all(math.isfinite(v) for p in pixels for v in p)
        foreground = [(i % WIDTH, i // WIDTH) for i,p in enumerate(pixels) if p[3] > 0.5]
        assert foreground and pixels[0][3] < 0.01, (name, len(foreground), pixels[0])
        left, right = min(x for x,y in foreground), max(x for x,y in foreground)
        depths = (0,) if name.startswith('mesh_') else (-0.5, 0.5)
        projected = [WIDTH/2+(translation+dx-camera_x)*HEIGHT*50/(20*(5-dz))
                     for dx in (-0.5, 0.5) for dz in depths]
        assert abs(left-min(projected)) <= 2 and abs(right-max(projected)) <= 2, (name, left, right, projected)
        for x,y in foreground:
            rgb = pixels[y*WIDTH+x][:3]
            assert rgb[dominant] > max(v for i,v in enumerate(rgb) if i != dominant), (name, rgb)
        colors = {'base': (0.8,0.2,0.1), 'animated': (0.8,0.2,0.1),
                  'color': (0.1,0.8,0.2), 'camera': (0.1,0.8,0.2),
                  'restored': (0.2,0.3,0.9), 'mesh_before': (0.9,0.8,0.1), 'mesh_after': (0.9,0.8,0.1)}
        center = pixels[(HEIGHT//2)*WIDTH+(left+right)//2]
        assert center[3] > 0.99 and all(abs(a-b) <= 2/255 for a,b in zip(center[:3], colors[name])), (name, center)
        observations[name] = {'foreground_pixels': len(foreground), 'x_bounds': [left, right],
                              'expected_x_bounds': [min(projected), max(projected)], 'dominant_rgb': dominant}
    assert len(frames['removed']) == WIDTH*HEIGHT and all(p[3] < 0.01 for p in frames['removed'])
    assert frames['clip_cleared'] == frames['restored'], 'Removed clip planes remained active'
    observations['clip_cleared'] = observations['restored'].copy()
    # The plane x_camera >= 0 cuts at the image centre even after translation
    # and a 90-degree camera roll. A world-space plane would cut the wrong axis.
    for name, camera_x in [('clipped', 0), ('clip_moved', 0.25), ('clip_rotated', 0)]:
        pixels = frames[name]
        assert len(pixels) == WIDTH*HEIGHT and all(math.isfinite(v) for p in pixels for v in p)
        foreground = [(i % WIDTH, i // WIDTH) for i,p in enumerate(pixels) if p[3] > 0.5]
        assert foreground
        left, right = min(x for x,y in foreground), max(x for x,y in foreground)
        bottom, top = min(y for x,y in foreground), max(y for x,y in foreground)
        expected_right = WIDTH/2 + (0.5-camera_x)*HEIGHT*50/(20*4.5)
        assert abs(left-WIDTH/2) <= 1 and abs(right-expected_right) <= 2, (name,left,right)
        assert abs((bottom+top)/2-HEIGHT/2) <= 1 and top-bottom > 30, (name,bottom,top)
        assert all(pixels[y*WIDTH+x][2] > pixels[y*WIDTH+x][0] for x,y in foreground)
        if camera_x == 0:
            assert abs(len(foreground)*2-observations['restored']['foreground_pixels']) <= HEIGHT
        observations[name] = {'foreground_pixels':len(foreground), 'x_bounds':[left,right],
                              'y_bounds':[bottom,top], 'expected_right':expected_right}
    assert len(timing['retained']) == 30 and len(timing['new']) == 10
    assert len(motion['retained']) == 30 and len(motion['new']) == 10
    for name, samples in motion.items():
        assert all(abs(samples[i]-samples[i-1]) > 2 for i in range(1, len(samples))), name
    assert motion['new'] == motion['retained'][:10], 'Timing paths rendered different camera frames'
    observations['timed_camera_centroids'] = motion
    assert memory and memory[1]-memory[0] < 64*1024*1024
    assert memory[2] < 0 or memory[3]-memory[2] < 32*1024*1024
    return frames, observations, timing, memory


def main():
    work = BUILD / 'render-session'
    work.mkdir(parents=True, exist_ok=True)
    report = {'completed': False, 'source_sha256': source_hash(ROOT), 'platform': platform.platform()}
    target = work / 'verification.json'
    target.write_text(json.dumps(report, indent=2)+'\n')
    bridge = build(imaging=True)
    filename = work / 'sequence.usda'
    filename.unlink(missing_ok=True)
    fixture(filename)
    original = filename.read_bytes()
    metrics = lifetime_metrics(work)
    binary = work / 'sequence'
    require_compile(ROOT/'tests/render_session.mojo', binary, ROOT/'src',
                    extra_flags=('-Xlinker', '-lusd_mojo_imaging', '-Xlinker', str(metrics)))

    output = run_renderer(binary, filename, work / 'source.log')
    frames, observations, timing, memory = inspect_frames(output)
    for name, pixels in frames.items():
        write_png(work/(name+'.png'), pixels, WIDTH, HEIGHT)
    rows = (len(NAMES)+2)//3
    sheet = [frames[NAMES[row*3+column]][y*WIDTH+x] if row*3+column < len(NAMES) else (0,0,0,0)
             for row in range(rows) for y in range(HEIGHT) for column in range(3) for x in range(WIDTH)]
    write_png(work/'sequence.png', sheet, WIDTH*3, HEIGHT*rows)
    report['rendering'] = render_metadata(output)
    native = subprocess.check_output(
        [sys.executable, str(ROOT / 'tools/render_session_native.py'), str(bridge), str(filename)],
        env=renderer_environment(), text=True, timeout=180,
    )
    report['native_boundaries'] = json.loads(native)
    for name in ('copy', 'move'):
        require_rejection(
            ROOT/f'tests/reject_render_session_{name}.mojo', work/'rejected', ROOT/'src',
            diagnostics=('copy', 'uninitialized', 'move'),
            extra_flags=('-Xlinker', '-lusd_mojo_imaging'),
        )
    installed = package(imaging=True)
    manifest = json.loads((installed/'manifest.json').read_text())
    assert manifest['source_sha256'] == report['source_sha256']
    packaged_binary = work/'packaged-sequence'
    require_compile(
        ROOT/'tests/render_session.mojo', packaged_binary, installed/'include',
        bridge=installed/'lib',
        extra_flags=('-Xlinker', '-lusd_mojo_imaging', '-Xlinker', str(metrics)),
    )
    installed_raw = run_renderer(packaged_binary, filename, work / 'installed.log')
    assert render_metadata(installed_raw) == report['rendering']
    installed_frames, _, _, _ = inspect_frames(installed_raw)
    assert installed_frames == frames, 'Installed module changed sequence pixels'
    assert filename.read_bytes() == original and source_hash(ROOT) == report['source_sha256']
    report.update({'completed': True, 'width': WIDTH, 'height': HEIGHT,
                   'frames': observations, 'timing_ns': timing, 'memory_bytes': memory,
                   'median_retained_render_readback_ns': statistics.median(x[2] for x in timing['retained']),
                   'median_new_session_render_readback_ns': statistics.median(x[2] for x in timing['new']),
                   'installed_consumer': 'passed', 'source_scene_unchanged': True,
                   'scope': 'Moving-camera frames with warm caches; render-call CPU time and synchronized readback, not GPU timestamps.'})
    target.write_text(json.dumps(report, indent=2,allow_nan=False)+'\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
