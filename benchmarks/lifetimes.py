"""Separate stage recreation, flattening and bridge ownership in fresh processes."""

import argparse
import ctypes
import gc
import hashlib
import json
import math
import os
import platform
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from build import BUILD, build, lifetime_metrics
from evidence import source_hash

MODES = ('sdk-open', 'sdk-flatten', 'sdk-snapshot', 'bridge-snapshot', 'sdk-reuse', 'bridge-reuse')


def worker(args):
    from pxr import Sdf, Tf, Usd, UsdGeom

    bridge = ctypes.CDLL(str(args.bridge))
    metrics = ctypes.CDLL(str(args.metrics))
    for name, arguments, result in [
        ('usdm_stage_open', [ctypes.c_char_p, ctypes.c_int32], ctypes.c_uint64),
        ('usdm_stage_close', [ctypes.c_uint64], None),
        ('usdm_scene_snapshot', [ctypes.c_uint64, ctypes.c_double, ctypes.c_int32], ctypes.c_uint64),
        ('usdm_scene_close', [ctypes.c_uint64], None),
        ('usdm_scene_info', [ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64), ctypes.c_int64], ctypes.c_int32),
    ]:
        function = getattr(bridge, name)
        function.argtypes, function.restype = arguments, result
    for name in ('usdm_test_current_rss', 'usdm_test_live_allocated'):
        getattr(metrics, name).restype = ctypes.c_int64
    libc = ctypes.CDLL(None)

    def token_count():
        sys.stdout.flush()
        with tempfile.TemporaryFile() as output:
            saved = os.dup(1)
            try:
                os.dup2(output.fileno(), 1)
                Tf.DumpTokenStats()
                libc.fflush(None)
            finally:
                os.dup2(saved, 1)
                os.close(saved)
            output.seek(0)
            return sum(int(x) for x in re.findall(rb'^\d+ -- (\d+)$', output.read(), re.M))

    held = None
    if args.worker == 'sdk-reuse':
        held = Usd.Stage.Open(str(args.asset))
    elif args.worker == 'bridge-reuse':
        held = bridge.usdm_stage_open(os.fsencode(args.asset), 0)
        assert held

    def cycle():
        if args.worker.startswith('bridge'):
            stage = held or bridge.usdm_stage_open(os.fsencode(args.asset), 0)
            assert stage
            snapshot = 0
            try:
                snapshot = bridge.usdm_scene_snapshot(stage, 0.0, 1)
                assert snapshot
                data = (ctypes.c_uint64 * 3)()
                assert bridge.usdm_scene_info(snapshot, data, 3) == 0
                values = ctypes.cast(data[2], ctypes.POINTER(ctypes.c_double))
                return {'prims': data[1] // 16, 'matrix_sum': sum(values[i] for i in range(data[1]))}
            finally:
                if snapshot:
                    bridge.usdm_scene_close(snapshot)
                if not held:
                    bridge.usdm_stage_close(stage)
        stage = held or Usd.Stage.Open(str(args.asset))
        assert stage
        if args.worker == 'sdk-open':
            return {'prims': sum(1 for _ in stage.Traverse())}
        flat = stage.Flatten()
        assert flat
        if args.worker == 'sdk-flatten':
            return {'root_prims': len(flat.rootPrims)}
        frozen = Usd.Stage.Open(flat)
        cache = UsdGeom.XformCache()
        count, checksum = 0, 0.0
        for prim in frozen.Traverse():
            count += 1
            checksum += sum(value for row in cache.GetLocalToWorldTransform(prim) for value in row)
        return {'prims': count, 'matrix_sum': checksum}

    for _ in range(100):
        expected = cycle()
    samples = []
    checkpoints = {0, args.rounds // 4, args.rounds // 2, args.rounds}
    try:
        for i in range(args.rounds + 1):
            if i:
                assert cycle() == expected
            if i in checkpoints:
                gc.collect()
                tokens = token_count()
                samples.append({
                    'cycle': i, 'rss_bytes': metrics.usdm_test_current_rss(),
                    'allocator_live_bytes': metrics.usdm_test_live_allocated(),
                    'loaded_layers': len(Sdf.Layer.GetLoadedLayers()), 'tokens': tokens,
                })
    finally:
        if isinstance(held, int):
            bridge.usdm_stage_close(held)
        held = None
    gc.collect()
    print(json.dumps({'mode': args.worker, 'warmup_cycles': 100, 'samples': samples,
                      'result': expected, 'layers_after_close': len(Sdf.Layer.GetLoadedLayers())}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('asset', type=Path)
    parser.add_argument('--rounds', type=int, default=2000)
    parser.add_argument('--worker', choices=MODES)
    parser.add_argument('--bridge', type=Path)
    parser.add_argument('--metrics', type=Path)
    args = parser.parse_args()
    if not 100 <= args.rounds <= 10000:
        parser.error('Use 100..10000 measured cycles')
    args.asset = args.asset.resolve()
    if not args.asset.is_file():
        parser.error('Asset must be an existing USD file')
    if args.worker:
        worker(args)
        return
    bridge = build()
    directory = BUILD / 'lifetime-profile'
    directory.mkdir(parents=True, exist_ok=True)
    metrics = lifetime_metrics(directory, shared=True)
    report = {
        'completed': False, 'source_sha256': source_hash(ROOT),
        'asset_sha256': hashlib.sha256(args.asset.read_bytes()).hexdigest(),
        'bridge_sha256': hashlib.sha256(bridge.read_bytes()).hexdigest(),
        'system': sys.platform, 'machine': platform.machine(), 'openusd': '26.08',
        'scope': 'C ABI ownership versus independent Python SDK calls in fresh processes; not a native Mojo performance comparison. Allocator counters do not cover every allocator or establish unbounded stability.',
        'cases': {},
    }
    target = directory / 'profile.json'
    target.write_text(json.dumps(report, indent=2) + '\n')
    for mode in MODES:
        result = subprocess.run([
            sys.executable, __file__, str(args.asset), '--rounds', str(args.rounds),
            '--worker', mode, '--bridge', str(bridge), '--metrics', str(metrics),
        ], capture_output=True, text=True, timeout=300)
        (directory / (mode + '.stdout')).write_text(result.stdout)
        (directory / (mode + '.stderr')).write_text(result.stderr)
        result.check_returncode()
        row = json.loads(result.stdout)
        first, last = row['samples'][0], row['samples'][-1]
        row['growth'] = {key: last[key] - first[key] for key in (
            'rss_bytes', 'allocator_live_bytes', 'loaded_layers', 'tokens')}
        report['cases'][mode] = row
        target.write_text(json.dumps(report, indent=2) + '\n')
        print(mode, row['growth'], flush=True)
    baseline = report['cases']['sdk-snapshot']['result']
    for mode in ('bridge-snapshot', 'sdk-reuse', 'bridge-reuse'):
        actual = report['cases'][mode]['result']
        assert actual['prims'] == baseline['prims'], mode
        assert math.isclose(actual['matrix_sum'], baseline['matrix_sum'], rel_tol=2e-12, abs_tol=2e-10), mode
    for mode, row in report['cases'].items():
        assert row['growth']['loaded_layers'] == 0, mode
        # Flattening initializes schema layers that opening alone never loads.
        # Compare each process with its own warmed state, not another mode.
        assert row['layers_after_close'] <= row['samples'][0]['loaded_layers'], mode
    report['completed'] = True
    target.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
