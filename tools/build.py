"""Build the small C ABI bridge against the SDK in the active Pixi prefix."""

import os
import re
import subprocess
import sys
from pathlib import Path

from generate import generate
from link import linker_flags

ROOT = Path(__file__).resolve().parents[1]
BUILD = (
    Path(os.environ.get("USD_MOJO_BUILD_DIR", ROOT / ".build")).expanduser().resolve()
)


def build(*, imaging: bool = False, materialx: bool = False) -> Path:
    generate(check=True)
    BUILD.mkdir(parents=True, exist_ok=True)
    sdk_prefix = Path(os.environ.get("USD_MOJO_SDK_PREFIX", sys.prefix)).resolve()
    prefixes = [str(sdk_prefix)]
    prefix = os.environ.get("USD_MOJO_MATERIALX_PREFIX")
    if materialx and not prefix:
        raise ValueError(
            "Set USD_MOJO_MATERIALX_PREFIX to the optional SDK installation"
        )
    if prefix:
        prefixes.append(str(Path(prefix).resolve()))
    subprocess.run(
        [
            "cmake",
            "-S",
            str(ROOT / "native"),
            "-B",
            str(BUILD / "native"),
            "-G",
            "Ninja",
            "-DCMAKE_PREFIX_PATH=" + ";".join(prefixes),
            f"-Dpxr_DIR={sdk_prefix}",
            *(
                [
                    "-DMaterialX_DIR="
                    + str(Path(prefix).resolve() / "lib/cmake/MaterialX")
                ]
                if prefix
                else []
            ),
            "-DCMAKE_BUILD_TYPE=Release",
            f"-DUSD_MOJO_IMAGING={'ON' if imaging else 'OFF'}",
            f"-DUSD_MOJO_MATERIALX={'ON' if materialx else 'OFF'}",
            f"-DUSD_MOJO_GL_TEST_CONTEXT={'ON' if os.environ.get('USD_MOJO_TEST_GL_CONTEXT') else 'OFF'}",
        ],
        check=True,
    )
    subprocess.run(
        ["cmake", "--build", str(BUILD / "native"), "--parallel", "2"], check=True
    )
    return (
        BUILD
        / "native"
        / (
            "libusd_mojo_bridge.dylib"
            if sys.platform == "darwin"
            else "libusd_mojo_bridge.so"
        )
    )


def compile_consumer(
    source: Path,
    binary: Path,
    imports: Path,
    *,
    bridge: Path | None = None,
    extra_flags: tuple[str, ...] = (),
) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            "mojo",
            "build",
            "--Werror",
            "-I",
            str(imports),
            *linker_flags(bridge if bridge is not None else BUILD / "native"),
            *extra_flags,
            str(source),
            "-o",
            str(binary),
        ],
        text=True,
        capture_output=True,
        check=False,
    )


def require_compile(
    source: Path,
    binary: Path,
    imports: Path,
    *,
    bridge: Path | None = None,
    extra_flags: tuple[str, ...] = (),
) -> None:
    result = compile_consumer(
        source, binary, imports, bridge=bridge, extra_flags=extra_flags
    )
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)


def require_rejection(
    source: Path,
    binary: Path,
    imports: Path,
    *,
    diagnostics: tuple[str, ...],
    extra_flags: tuple[str, ...] = (),
) -> None:
    """Require a semantic rejection, rather than any compiler or linker failure."""
    result = compile_consumer(source, binary, imports, extra_flags=extra_flags)
    if result.returncode == 0:
        raise RuntimeError(f"Invalid consumer unexpectedly compiled: {source}")
    errors = " ".join(re.findall(r": error: ([^\n]+)", result.stderr)).lower()
    if not any(word in errors for word in diagnostics):
        raise RuntimeError(
            f"Unexpected compiler failure for {source}:\n{result.stderr}"
        )


def lifetime_metrics(directory: Path, *, shared: bool = False) -> Path:
    suffix = (".dylib" if sys.platform == "darwin" else ".so") if shared else ".o"
    output = directory / ("lifetime_metrics" + suffix)
    flags = ["-shared", "-fPIC"] if shared else ["-c"]
    subprocess.run(
        [
            "c++",
            "-std=c++17",
            *flags,
            str(ROOT / "tests/lifetime_metrics.cpp"),
            "-o",
            str(output),
        ],
        check=True,
    )
    return output


if __name__ == "__main__":
    print(build())
