"""Native renderer environment, identity checks and pixel fixtures."""

import os
import struct
import subprocess
import sys
import zlib
from pathlib import Path

from build import BUILD


def renderer_environment(env=None):
    """Build the SDK environment for a native child process."""
    environment = {**os.environ, "PXR_WORK_THREAD_LIMIT": "2"}
    environment.update(env or {})
    sdk = Path(environment.get("USD_MOJO_SDK_PREFIX", sys.prefix)).resolve()
    prefixes = [sdk]
    if environment.get("USD_MOJO_MATERIALX_PREFIX"):
        prefixes.append(Path(environment["USD_MOJO_MATERIALX_PREFIX"]).resolve())
    prefixes.append(Path(sys.prefix).resolve())
    variable = "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"
    paths = [str(p / "lib") for p in prefixes]
    paths.extend(filter(None, environment.get(variable, "").split(":")))
    environment[variable] = ":".join(dict.fromkeys(paths))
    if "USD_MOJO_SDK_PREFIX" in environment:
        plugins = [str(sdk / "lib/usd")]
        plugins.extend(
            filter(None, environment.get("PXR_PLUGINPATH_NAME", "").split(":"))
        )
        environment["PXR_PLUGINPATH_NAME"] = ":".join(dict.fromkeys(plugins))
    if sys.platform == "linux" and environment.get("USD_MOJO_TEST_GL_CONTEXT"):
        environment["LD_PRELOAD"] = str(BUILD / "native/libusd_mojo_test_context.so")
    return environment


def render_metadata(output):
    """Require a consistent renderer identity from the consumer log."""

    def one(prefix):
        values = {
            line[len(prefix):].strip()
            for line in output.splitlines()
            if line.startswith(prefix)
        }
        if len(values) != 1 or not next(iter(values)):
            raise ValueError("Missing or inconsistent render metadata: " + prefix)
        return values.pop()

    api, renderer = one("RENDER_BACKEND "), one("RENDERER_PLUGIN ")
    result = {
        "backend": "Hydra/" + renderer + "/" + api,
        "hgi_api": api,
        "renderer_plugin": renderer,
    }
    for prefix, key in (("GPU_RENDERER ", "gpu_renderer"), ("GPU_VERSION ", "gpu_version")):
        if any(line.startswith(prefix) for line in output.splitlines()):
            result[key] = one(prefix)
    return result


def run_renderer(executable, scene, log, *, timeout=180, arguments=(), env=None):
    environment = renderer_environment(env)
    with log.open("w") as output:
        result = subprocess.run(
            [str(executable), str(scene), *map(str, arguments)],
            stdout=output,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            env=environment,
        )
    result.check_returncode()
    output = log.read_text()
    if "Failed to compile shader" in output or "Failed to link shader" in output:
        raise RuntimeError(f"Renderer used a fallback shader; see {log}")
    expected_gpu = environment.get("USD_MOJO_EXPECT_GPU")
    if expected_gpu:
        renderers = [
            line for line in output.splitlines() if line.startswith("GPU_RENDERER ")
        ]
        if not renderers or not all(
            expected_gpu.lower() in line.lower() for line in renderers
        ):
            raise RuntimeError(f"Requested GPU was not used; see {log}")
    return output


def named_pixels(output, names):
    frames = {name: [] for name in names}
    for line in output.splitlines():
        parts = line.split()
        if parts[:1] == ["PIX"]:
            _, name, *pixel = parts
            frames[name].append(tuple(map(float, pixel)))
    return frames


def image_pixels(output):
    return [
        tuple(map(float, line.split()[1:]))
        for line in output.splitlines()
        if line.startswith("PIX ")
    ]


def write_png(path, pixels, width, height):
    assert len(pixels) == width * height
    rows = [
        b"\0"
        + bytes(
            round(max(0, min(1, v)) * 255)
            for p in pixels[y * width : (y + 1) * width]
            for v in p
        )
        for y in range(height)
    ]

    def chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data))
        )

    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(b"".join(rows)))
        + chunk(b"IEND", b"")
    )


