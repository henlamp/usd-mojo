"""Exercise native Hydra boundaries without loading the Python reference SDK."""
import ctypes
import hashlib
import json
import os
import sys
import threading
from pathlib import Path

WIDTH, HEIGHT = 96, 64

def native_checks(bridge, filename):
    core = ctypes.CDLL(str(bridge))
    image = ctypes.CDLL(str(bridge.with_name('libusd_mojo_imaging' + bridge.suffix)))
    u64, i32, i64 = ctypes.c_uint64, ctypes.c_int32, ctypes.c_int64
    ptr, text = ctypes.POINTER(ctypes.c_float), ctypes.c_char_p
    declarations = [
        (core, 'usdm_stage_open', [text, i32], u64),
        (core, 'usdm_stage_close', [u64], None),
        (image, 'usdm_render_session_open', [u64, text, i32, i32], u64),
        (image, 'usdm_render_session_close', [u64], None),
        (image, 'usdm_render_session_render', [u64, text, ctypes.c_double, i32, i32, i32], i32),
        (image, 'usdm_render_session_info', [u64, ctypes.POINTER(u64), i64], i32),
        (image, 'usdm_render_session_read_into', [u64, ptr, i64], i32),
        (image, 'usdm_render_session_readback', [u64], u64),
        (image, 'usdm_image_render', [u64,text,text,i32,i32,ctypes.c_double,i32,i32,i32], u64),
        (image, 'usdm_image_info', [u64, ctypes.POINTER(u64), i64], i32),
        (image, 'usdm_image_close', [u64], None),
        (image, 'usdm_image_error_kind', [], i32),
    ]
    for lib, name, arguments, result in declarations:
        function = getattr(lib, name)
        function.argtypes, function.restype = arguments, result
    stage = core.usdm_stage_open(os.fsencode(filename), 0)
    session = owned = 0
    output = (ctypes.c_float * (WIDTH * HEIGHT * 4))(*([-77] * (WIDTH * HEIGHT * 4)))
    sentinel = bytes(output)
    try:
        assert image.usdm_render_session_open(0, b'', WIDTH, HEIGHT) == 0
        assert image.usdm_image_error_kind() == 1
        legacy = image.usdm_image_render(stage, b'/Camera', b'', WIDTH, HEIGHT, 0, 0, 8, 0)
        assert legacy
        image.usdm_image_close(legacy)
        session = image.usdm_render_session_open(stage, b'', WIDTH, HEIGHT)
        assert session
        core.usdm_stage_close(stage)
        stage = 0
        assert image.usdm_render_session_read_into(session, output, len(output)) == -1
        assert image.usdm_image_error_kind() == 1
        assert bytes(output) == sentinel
        assert image.usdm_render_session_render(session, b'/Camera', 0, 0, 8, 0) == 0
        for destination, length in [(output, 3), (output, len(output)+1), (None, len(output))]:
            assert image.usdm_render_session_read_into(session, destination, length) == -1
            assert bytes(output) == sentinel
        assert image.usdm_render_session_read_into(session, output, len(output)) == 0
        assert any(output[i] > 0.5 for i in range(3, len(output), 4))
        info = (u64 * 5)(*[999]*5)
        results = []
        def wrong_thread():
            status = image.usdm_render_session_info(session, info, 5)
            results.append((status, image.usdm_image_error_kind()))
        thread = threading.Thread(target=wrong_thread)
        thread.start()
        thread.join(timeout=10)
        assert not thread.is_alive() and results == [(-1, 1)] and list(info) == [999]*5
        for path, kind in [(b'/MissingCamera', 2), (b'/Cube', 3), (b'Camera', 1)]:
            assert image.usdm_render_session_render(session, path, 0, 0, 8, 0) == -1
            assert image.usdm_image_error_kind() == kind
        assert image.usdm_render_session_render(session, b'/Camera', 0, 0, 8, 0) == 0
        assert image.usdm_render_session_render(session, b'/Camera', 0, 2, 8, 0) == -1
        assert image.usdm_render_session_info(session, info, 5) == 0
        assert list(info)[2:] == [2, 0, 0]
        assert image.usdm_render_session_read_into(session, output, len(output)) == -1
        assert image.usdm_render_session_render(session, b'/Camera', 1, 0, 8, 0) == 0
        owned = image.usdm_render_session_readback(session)
        assert owned
        metadata = (u64 * 5)()
        assert image.usdm_image_info(owned, metadata, 5) == 0
        before = hashlib.sha256(ctypes.string_at(metadata[4], metadata[3]*4)).hexdigest()
        image.usdm_render_session_close(session)
        session = 0
        after = hashlib.sha256(ctypes.string_at(metadata[4], metadata[3]*4)).hexdigest()
        assert before == after
    finally:
        if owned:
            image.usdm_image_close(owned)
        if session:
            image.usdm_render_session_close(session)
        if stage:
            core.usdm_stage_close(stage)
    return ['legacy-image-abi', 'stage-owner-retained', 'read-before-render-rejected', 'wrong-extents-and-null-preserve-output',
            'thread-affinity', 'failed-render-invalidates-readback', 'image-outlives-session', 'typed-error-contract']



if __name__ == "__main__":
    print(json.dumps(native_checks(Path(sys.argv[1]), Path(sys.argv[2]))))
