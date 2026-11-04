"""Build checksum-pinned optional SDKs locally, with at most two compiler workers."""

import argparse
import hashlib
import json
import subprocess
import sys
import tarfile
import urllib.request

from config import ROOT, pins


def source(name):
    row = json.loads((ROOT / "tools/optional_sdks.json").read_text())[name]
    cache = ROOT / ".local/dependencies"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / (name + "-" + row["version"] + ".tar.gz")
    if (
        not archive.exists()
        or hashlib.sha256(archive.read_bytes()).hexdigest() != row["sha256"]
    ):
        temporary = archive.with_suffix(".download")
        with (
            urllib.request.urlopen(row["url"], timeout=60) as response,
            temporary.open("wb") as out,
        ):
            total = 0
            while block := response.read(1024 * 1024):
                total += len(block)
                if total > 256 * 1024 * 1024:
                    raise ValueError("SDK archive exceeds size limit")
                out.write(block)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != row["sha256"]:
            raise ValueError("SDK source checksum mismatch")
        temporary.replace(archive)
    target = cache / row["source"]
    receipt = target / ".usd-mojo-extracted"
    if not receipt.exists() or receipt.read_text() != row["sha256"]:
        with tarfile.open(archive) as snapshot:
            snapshot.extractall(cache, filter="data")
        receipt.write_text(row["sha256"])
    return target, row


def build(openusd=False):
    src, row = source("materialx")
    prefix = ROOT / ".local/materialx" / row["version"]
    directory = ROOT / ".build/materialx-sdk"

    def run(command):
        subprocess.run(list(map(str, command)), check=True)

    flags = [
        "-DMATERIALX_BUILD_SHARED_LIBS=ON",
        "-DMATERIALX_BUILD_GEN_OSL=OFF",
        "-DMATERIALX_BUILD_GEN_MDL=OFF",
        "-DMATERIALX_BUILD_GEN_SLANG=OFF",
        "-DMATERIALX_BUILD_PYTHON=OFF",
    ]
    run(
        [
            "cmake",
            "-S",
            src,
            "-B",
            directory,
            "-G",
            "Ninja",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_INSTALL_PREFIX=" + str(prefix),
            *flags,
        ]
    )
    run(["cmake", "--build", directory, "--parallel", "2"])
    run(["cmake", "--install", directory])
    if openusd:
        src, row = source("openusd")
        if row["version"] != pins()["openusd"]:
            raise ValueError(
                "Review the optional OpenUSD source pin for this toolchain"
            )
        apply_patches(src, row)
        directory = ROOT / ".build/openusd-materialx"
        sdk = ROOT / ".local/openusd-materialx" / row["version"]
        options = [
            "-DPXR_ENABLE_MATERIALX_SUPPORT=ON",
            "-DPXR_BUILD_TESTS=OFF",
            "-DPXR_BUILD_EXAMPLES=OFF",
            "-DPXR_BUILD_TUTORIALS=OFF",
            "-DPXR_BUILD_USD_TOOLS=OFF",
            "-DPXR_BUILD_USDVIEW=OFF",
            "-DPXR_ENABLE_PYTHON_SUPPORT=ON",
        ]
        run(
            [
                "cmake",
                "-S",
                src,
                "-B",
                directory,
                "-G",
                "Ninja",
                "-DCMAKE_BUILD_TYPE=Release",
                "-DCMAKE_INSTALL_PREFIX=" + str(sdk),
                "-DCMAKE_PREFIX_PATH=" + sys.prefix + ";" + str(prefix),
                "-DPython3_EXECUTABLE=" + sys.executable,
                *options,
            ]
        )
        run(["cmake", "--build", directory, "--parallel", "2"])
        run(["cmake", "--install", directory])
        record_identity(sdk)
    print("MaterialX prefix:", prefix)
    if openusd:
        print("OpenUSD MaterialX prefix:", sdk)


def apply_patches(directory, row):
    for patch in row.get("patches", []):
        change = ROOT / patch["patch"]
        if hashlib.sha256(change.read_bytes()).hexdigest() != patch["patch_sha256"]:
            raise ValueError("SDK patch checksum mismatch")
        target = directory / patch["file"]
        current = hashlib.sha256(target.read_bytes()).hexdigest()
        if current == patch["after_sha256"]:
            continue
        if current != patch["before_sha256"]:
            raise ValueError(
                "SDK patch target differs from the reviewed upstream source"
            )
        subprocess.run(
            ["patch", "--batch", "--forward", "-p1", "-i", str(change)],
            cwd=directory,
            check=True,
        )
        if hashlib.sha256(target.read_bytes()).hexdigest() != patch["after_sha256"]:
            raise ValueError("SDK patch result checksum mismatch")


def record_identity(prefix):
    data = json.loads((ROOT / "tools/optional_sdks.json").read_text())
    (prefix / "usd-mojo-sdk.json").write_text(
        json.dumps(data, sort_keys=True, indent=2) + "\n"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openusd", action="store_true")
    build(parser.parse_args().openusd)
