"""Bounded malformed-input corpus, large owned data and native lifetime stress.

SDK parsing is performed in isolated child processes. Accepted mutations are
recorded; this is regression coverage, not a proof of sandbox-safe USD parsing.
"""

import hashlib
import json
import platform
import struct
import subprocess

from build import BUILD, ROOT, build
from check import require_compile
from evidence import SCOPE, source_hash
from link import linker_flags


def main():
    from pxr import Gf, Sdf, Usd, UsdGeom, Vt

    build()
    directory = BUILD / "hardening"
    directory.mkdir(exist_ok=True)

    def mesh_file(count):
        path = directory / f"mesh-{count}.usdc"
        path.unlink(missing_ok=True)
        stage = Usd.Stage.CreateNew(str(path))
        m = UsdGeom.Mesh.Define(stage, "/World/Mesh")
        m.CreatePointsAttr(
            Vt.Vec3fArray(
                [Gf.Vec3f(i % 997, (i // 997) % 997, i % 3) for i in range(count)]
            )
        )
        m.CreateFaceVertexCountsAttr([3] * (count // 3))
        m.CreateFaceVertexIndicesAttr(list(range(count)))
        stage.GetRootLayer().Save()
        return path

    large = mesh_file(300000)
    small = mesh_file(30000)
    valid = mesh_file(3)
    nul = directory / "nul-text.usdc"
    nul.unlink(missing_ok=True)
    s = Usd.Stage.CreateNew(str(nul))
    s.DefinePrim("/World").CreateAttribute("label", Sdf.ValueTypeNames.String).Set(
        "prefix\x00suffix"
    )
    s.GetRootLayer().Save()
    del s
    binary = directory / "stress"
    require_compile(ROOT / "tests/stress.mojo", binary, ROOT / "src")
    subprocess.run([str(binary), str(large), str(nul)], check=True, timeout=180)
    metrics = directory / "lifetime_metrics.o"
    subprocess.run(
        [
            "c++",
            "-std=c++17",
            "-c",
            str(ROOT / "tests/lifetime_metrics.cpp"),
            "-o",
            str(metrics),
        ],
        check=True,
    )
    worker = directory / "lifetime"
    subprocess.run(
        [
            "mojo",
            "build",
            "--Werror",
            "-I",
            str(ROOT / "src"),
            *linker_flags(BUILD / "native"),
            "-Xlinker",
            str(metrics),
            str(ROOT / "tests/lifetime.mojo"),
            "-o",
            str(worker),
        ],
        check=True,
    )
    process = subprocess.run(
        [str(worker), "stress", str(small)],
        text=True,
        capture_output=True,
        timeout=240,
        check=True,
    )
    lifetime = json.loads(process.stdout)
    data = valid.read_bytes()
    corpus = []
    for size in (0, 1, 7, 16, 32, len(data) // 2, len(data) - 1):
        corpus.append((f"truncated-{size}.usdc", data[:size], None))
    for position in (0, 1, 8, 16, len(data) // 3, len(data) // 2, len(data) - 8):
        mutation = bytearray(data)
        mutation[position] ^= 0xFF
        corpus.append((f"mutated-{position}.usdc", bytes(mutation), None))
    directory_offset = struct.unpack_from("<Q", data, 16)[0]
    for name, position in (
        ("directory-offset", 16),
        ("section-count", directory_offset),
        ("section-start", directory_offset + 8 + 16),
        ("section-size", directory_offset + 8 + 24),
    ):
        mutation = bytearray(data)
        struct.pack_into("<Q", mutation, position, (1 << 64) - 1)
        corpus.append((name + ".usdc", bytes(mutation), False))
    corpus += [
        ("invalid.usda", b'#usda 1.0\ndef Mesh "Broken" {', False),
        (
            "invalid-topology.usda",
            b'#usda 1.0\ndef Mesh "Bad" {\n point3f[] points=[(0,0,0)]\n int[] faceVertexCounts=[3]\n int[] faceVertexIndices=[0,1,2]\n}',
            True,
        ),
        ("invalid-magic.usdc", b"NOTUSD00" + data[8:], False),
    ]
    results = []
    for name, payload, expected in corpus:
        path = directory / name
        path.write_bytes(payload)
        process = subprocess.run(
            [str(worker), "open", str(path)],
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )
        (directory / (name + ".stderr.txt")).write_text(process.stderr)
        assert process.returncode == 0, (
            name,
            process.returncode,
            process.stderr[-2000:],
        )
        opened = json.loads(process.stdout)["opened"]
        if expected is not None:
            assert opened == expected, (name, opened)
        results.append(
            {
                "fixture": name,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "bytes": len(payload),
                "opened": opened,
                "process_exit": process.returncode,
                "diagnostics_sha256": hashlib.sha256(
                    process.stderr.encode()
                ).hexdigest(),
            }
        )
    report = {
        "status": "passed",
        "source_sha256": source_hash(ROOT),
        "source_hash_scope": SCOPE,
        "platform": platform.platform(),
        "compiler": subprocess.check_output(["mojo", "--version"], text=True).strip(),
        "large_mesh_points": 300000,
        "mojo_read_close_cycles": 100,
        "native_lifetime": lifetime,
        "malformed_corpus": results,
        "limitations": f"{len(corpus)} bounded malformed cases, not exhaustive fuzzing or untrusted-file isolation; actual parser is OpenUSD",
    }
    (BUILD / "hardening.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
