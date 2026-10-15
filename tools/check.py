"""Verify real USD semantics, C ABI boundaries and a precompiled consumer."""

import ctypes
import hashlib
import json
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from build import BUILD, ROOT, build
from check_api import check as check_api
from evidence import SCOPE, source_hash
from information_checks import check_information
from link import linker_flags
from pxr import Usd, UsdGeom
from value_checks import check_graphics, check_values


def compile_consumer(
    source: Path, binary: Path, imports: Path
) -> subprocess.CompletedProcess:
    bridge = BUILD / "native"
    return subprocess.run(
        [
            "mojo",
            "build",
            "--Werror",
            "-I",
            str(imports),
            *linker_flags(bridge),
            str(source),
            "-o",
            str(binary),
        ],
        text=True,
        capture_output=True,
        check=False,
    )


def require_compile(source: Path, binary: Path, imports: Path) -> None:
    result = compile_consumer(source, binary, imports)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)


def sdk_comparison(binary: Path, fixture: Path) -> int:
    stage = Usd.Stage.Open(str(fixture))
    prim = stage.GetPrimAtPath("/World/Robot/Triangle")
    geom = UsdGeom.Mesh(prim)
    expected = []
    for item in stage.Traverse():
        expected.append(("PATH", str(item.GetPath()), str(item.GetTypeName())))
    for frame in range(3):
        expected.append(("GAIN", frame, prim.GetAttribute("gain").Get(frame)))
        points = [float(v) for p in geom.GetPointsAttr().Get(frame) for v in p]
        counts = geom.GetFaceVertexCountsAttr().Get(frame)
        indices = geom.GetFaceVertexIndicesAttr().Get(frame)
        for name, values in (("POINT", points), ("COUNT", counts), ("INDEX", indices)):
            expected.extend((name, frame, i, v) for i, v in enumerate(values))
        matrix = UsdGeom.XformCache(frame).GetLocalToWorldTransform(prim)
        expected.extend(
            ("MATRIX", frame, r * 4 + c, matrix[r][c])
            for r in range(4)
            for c in range(4)
        )
    output = subprocess.check_output([str(binary), str(fixture)], text=True)
    actual = [tuple(line.split()) for line in output.splitlines()]
    assert len(actual) == len(expected), (len(actual), len(expected))
    for observed, wanted in zip(actual, expected, strict=True):
        assert len(observed) == len(wanted)
        for value, reference in zip(observed, wanted, strict=True):
            if isinstance(reference, (int, float)):
                assert abs(float(value) - reference) <= 1e-6, (observed, wanted)
            else:
                assert value == reference, (observed, wanted)
    return len(expected)


def abi_boundaries(library: Path, fixture: Path, directory: Path) -> None:
    lib = ctypes.CDLL(str(library))
    handle = ctypes.c_uint64
    i32, i64, text = ctypes.c_int32, ctypes.c_int64, ctypes.c_char_p
    lib.usdm_stage_open.argtypes = [text, i32]
    lib.usdm_stage_open.restype = handle
    lib.usdm_stage_close.argtypes = [handle]
    lib.usdm_stage_close.restype = None
    lib.usdm_text.argtypes = [
        handle,
        text,
        i32,
        text,
        ctypes.c_double,
        i32,
        ctypes.c_void_p,
        i64,
    ]
    lib.usdm_text.restype = i64
    lib.usdm_mesh_snapshot.argtypes = [handle, text, ctypes.c_double, i32]
    lib.usdm_mesh_snapshot.restype = handle
    lib.usdm_mesh_copy.argtypes = [
        handle,
        ctypes.c_void_p,
        i64,
        ctypes.c_void_p,
        i64,
        ctypes.c_void_p,
        i64,
    ]
    lib.usdm_mesh_copy.restype = i32
    lib.usdm_mesh_close.argtypes = [handle]
    lib.usdm_mesh_close.restype = None
    lib.usdm_mesh_data.argtypes = [handle, i32]
    lib.usdm_mesh_data.restype = handle
    lib.usdm_error_kind.restype = i32
    stage = lib.usdm_stage_open(str(fixture).encode(), 0)
    assert stage
    try:
        # Too-small buffers must fail before touching caller storage.
        guard = ctypes.create_string_buffer(b"sentinel")
        assert lib.usdm_text(stage, b"", 0, b"", 0, 1, guard, 1) == -1
        assert guard.value == b"sentinel"
        assert lib.usdm_text(stage, b"", 0, b"", 0, 1, None, -1) == -1
        snapshot = lib.usdm_mesh_snapshot(stage, b"/World/Robot/Triangle", 0, 1)
        assert snapshot
        try:
            assert lib.usdm_mesh_copy(snapshot, guard, 1, None, 0, None, 0) == -1
            assert guard.value == b"sentinel"
            # Foreign spans can bypass compiler alias tracking; reject all writes.
            cells = (ctypes.c_int32 * 12)(*([123] * 12))
            indices = (ctypes.c_int32 * 3)(123, 123, 123)
            assert lib.usdm_mesh_copy(snapshot, cells, 9, cells, 1, indices, 3) == -1
            assert list(cells) == [123] * 12 and list(indices) == [123] * 3
            counts = (ctypes.c_int32 * 1)(123)
            address = lib.usdm_mesh_data(snapshot, 0)
            assert address
            assert lib.usdm_mesh_copy(snapshot, address, 9, counts, 1, indices, 3) == -1
            assert lib.usdm_error_kind() == 1
            assert list(counts) == [123] and list(indices) == [123] * 3
            assert ctypes.c_float.from_address(address).value == 0
        finally:
            lib.usdm_mesh_close(snapshot)
    finally:
        lib.usdm_stage_close(stage)
    invalid = directory / "invalid.usda"
    invalid.write_text("""#usda 1.0
def Mesh "Bad" {
 point3f[] points = [(0,0,0)]
 int[] faceVertexCounts = [3]
 int[] faceVertexIndices = [0,1,2]
}
""")
    stage = lib.usdm_stage_open(str(invalid).encode(), 0)
    assert stage
    try:
        assert lib.usdm_mesh_snapshot(stage, b"/Bad", 0, 1) == 0
    finally:
        lib.usdm_stage_close(stage)


def main() -> None:
    api_report = check_api()
    library = build()
    subprocess.run(
        [
            "cmake",
            "-S",
            str(ROOT / "native"),
            "-B",
            str(BUILD / "native"),
            "-DUSD_MOJO_TESTS=ON",
            f"-DCMAKE_PREFIX_PATH={sys.prefix}",
        ],
        check=True,
    )
    subprocess.run(
        ["cmake", "--build", str(BUILD / "native"), "--target", "diagnostic_ownership"],
        check=True,
    )
    subprocess.run([str(BUILD / "native" / "diagnostic_ownership")], check=True)
    with tempfile.TemporaryDirectory(prefix="acceptance-", dir=BUILD) as temp:
        directory = Path(temp)
        # Author only copies of fixtures: tests must not dirty source assets.
        for item in (ROOT / "tests" / "fixtures").glob("*.usda"):
            shutil.copy2(item, directory / item.name)
        fixture = directory / "composed.usda"
        contracts = directory / "contracts"
        require_compile(ROOT / "tests" / "contracts.mojo", contracts, ROOT / "src")
        subprocess.run(
            [
                str(contracts),
                str(fixture),
                str(directory / "saved.usda"),
                str(directory / "scene.usdc"),
            ],
            check=True,
        )
        # Open Mojo-authored files with the reference SDK, in a separate process runtime.
        authored = Usd.Stage.Open(str(directory / "saved.usda"))
        saved = authored.GetPrimAtPath("/Saved")
        assert saved.GetAttribute("label").Get() == "Grüße 🔥"
        assert saved.GetAttribute("gain").Get(1) == 9.0
        exported = Usd.Stage.Open(str(directory / "scene.usdc"))
        assert exported.GetPrimAtPath("/World/Robot/Triangle")
        root = Usd.Stage.Open(str(fixture))
        assert (
            root.GetRootLayer()
            .GetPrimAtPath("/World/Robot")
            .referenceList.prependedItems
        )
        require_compile(ROOT / "tests/errors.mojo", directory / "errors", ROOT / "src")
        subprocess.run(
            [str(directory / "errors"), str(fixture), str(directory)], check=True
        )
        require_compile(
            ROOT / "tests/mesh_snapshot.mojo", directory / "snapshot", ROOT / "src"
        )
        subprocess.run(
            [str(directory / "snapshot"), str(fixture), str(directory / "empty.usda")],
            check=True,
        )
        for name in ("escape", "mutation", "move", "copy"):
            rejected = compile_consumer(
                ROOT / f"tests/reject_snapshot_{name}.mojo",
                directory / "rejected",
                ROOT / "src",
            )
            assert rejected.returncode != 0, name
            errors = " ".join(re.findall(r": error: ([^\n]+)", rejected.stderr)).lower()
            assert any(
                word in errors
                for word in (
                    "origin",
                    "lifetime",
                    "mutable",
                    "immutable",
                    "move",
                    "uninitialized",
                    "copy",
                    "mutation",
                )
            ), rejected.stderr
        probe = directory / "probe"
        require_compile(ROOT / "tests" / "probe.mojo", probe, ROOT / "src")
        comparisons = sdk_comparison(probe, fixture)
        abi_boundaries(library, fixture, directory)
        result = compile_consumer(
            ROOT / "tests" / "reject_stage_copy.mojo",
            directory / "invalid-copy",
            ROOT / "src",
        )
        assert result.returncode != 0, "Stage copying unexpectedly compiled"
        assert "copy" in result.stderr.lower(), result.stderr
        # Consumer sees only the precompiled artifact, with no source import path.
        packages = directory / "packages"
        packages.mkdir()
        subprocess.run(
            [
                "mojo",
                "precompile",
                "--Werror",
                str(ROOT / "src" / "usd_mojo"),
                "-o",
                str(packages / "usd_mojo.mojoc"),
            ],
            check=True,
        )
        require_compile(
            ROOT / "tests" / "contracts.mojo", directory / "packaged", packages
        )
        subprocess.run(
            [
                str(directory / "packaged"),
                str(fixture),
                str(directory / "packaged.usda"),
                str(directory / "packaged.usdc"),
            ],
            check=True,
        )
        require_compile(
            ROOT / "examples" / "inspect.mojo", directory / "inspect", packages
        )
        subprocess.run([str(directory / "inspect"), str(fixture)], check=True)
        require_compile(
            ROOT / "tests" / "physics_contracts.mojo", directory / "physics", packages
        )
        subprocess.run([str(directory / "physics"), str(directory)], check=True)
        value_report = check_values(directory, require_compile, ROOT, packages, library)
        graphics_report = check_graphics(directory, require_compile, ROOT, packages)
        information_report = check_information(
            directory, require_compile, ROOT, packages
        )
    report = {
        "status": "passed",
        "api": api_report,
        "typed_values": value_report,
        "graphics": graphics_report,
        "general_information": information_report,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "mojo": subprocess.check_output(["mojo", "--version"], text=True).strip(),
        "openusd": "26.08",
        "sdk_comparison_rows": comparisons,
        "source_sha256": source_hash(ROOT),
        "bridge_sha256": hashlib.sha256(library.read_bytes()).hexdigest(),
        "source_hash_scope": SCOPE,
        "groups": [
            "composition-and-variants",
            "time-interpolation",
            "owned-mesh-and-move-only-stage",
            "typed-attribute-errors",
            "stable-error-categories-and-recovery",
            "owned-snapshot-and-immutable-tracked-views",
            "snapshot-escape-move-copy-mutation-rejection",
            "usda-usdc-roundtrips",
            "c-abi-buffer-boundaries",
            "sdk-diagnostic-owner-cleanup",
            "invalid-topology",
            "copy-rejection",
            "precompiled-consumer",
            "documented-example",
            "typed-numeric-values",
            "physics-schema-and-materials",
            "joint-relationships-and-drives",
            "distance-and-mass-units",
            "all-basic-types-and-arrays",
            "exact-64-bit-integers",
            "reference-and-sublayer-authoring",
            "variant-edit-targets",
            "primvars-normals-materials-camera",
            "api-schema-authoring",
        ],
    }
    (BUILD / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
