"""Build a relocatable compiler/platform-matched package; the SDK remains external."""

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tomllib
from pathlib import Path

from build import BUILD, ROOT, build
from config import sdk_identity
from evidence import SCOPE, source_hash


def copy_documentation(destination):
    for filename in ("LICENSE", "THIRD_PARTY_NOTICES.md", "CHANGELOG.md"):
        shutil.copy2(ROOT / filename, destination / filename)
    shutil.copytree(ROOT / "licenses", destination / "licenses")
    shutil.copytree(
        ROOT / "docs", destination / "docs",
        ignore=shutil.ignore_patterns("evidence", "PACKAGE_README.md"),
    )


def compile_installed(
    directory, source, binary, *, imaging=False, materialx=False,
    sdk_prefix=None, materialx_prefix=None, includes=(),
):
    command = [sys.executable, str(directory / "compile.py")]
    if imaging:
        command.append("--imaging")
    if materialx:
        command.append("--materialx")
    for flag, prefix in (
        ("--sdk-prefix", sdk_prefix),
        ("--materialx-prefix", materialx_prefix),
    ):
        if prefix is not None:
            command.extend((flag, str(prefix)))
    for include in includes:
        command.extend(("-I", str(include)))
    subprocess.run(command + [str(source), "-o", str(binary)], check=True)


def package(*, imaging: bool = False, materialx: bool = False):
    build(imaging=imaging, materialx=materialx)
    version = tomllib.loads((ROOT / "pixi.toml").read_text())["workspace"]["version"]
    compiler = subprocess.check_output(["mojo", "--version"], text=True).strip()
    compiler_version = compiler.split()[1]
    name = (
        f"usd-mojo-{version}-{sys.platform}-{platform.machine()}-mojo{compiler_version}"
    )
    if imaging:
        name += "-imaging"
    if materialx:
        name += "-materialx"
    destination = BUILD / "packages" / name
    if destination.exists():
        shutil.rmtree(destination)
    (destination / "include").mkdir(parents=True)
    subprocess.run(
        ["cmake", "--install", str(BUILD / "native"), "--prefix", str(destination)],
        check=True,
    )
    subprocess.run(
        [
            "mojo",
            "precompile",
            "--Werror",
            str(ROOT / "src/usd_mojo"),
            "-o",
            str(destination / "include/usd_mojo.mojoc"),
        ],
        check=True,
    )
    shutil.copy2(ROOT / "tools/package_compile.py", destination / "compile.py")
    copy_documentation(destination)
    shutil.copy2(ROOT / "docs/PACKAGE_README.md", destination / "README.md")
    for path in destination.rglob("*"):
        if path.is_file() and re.search(
            rb"/(?:Users|home)/[A-Za-z0-9_.-]+/", path.read_bytes()
        ):
            raise RuntimeError(
                f"Local user path in package component: {path.relative_to(destination)}"
            )
    manifest = {
        "format": 1,
        "source_sha256": source_hash(ROOT),
        "source_hash_scope": SCOPE,
        "version": version,
        "compiler": compiler,
        "system": sys.platform,
        "machine": platform.machine(),
        **sdk_identity(Path(os.environ.get("USD_MOJO_SDK_PREFIX", sys.prefix))),
        "bridge_abi": 2,
        "sdk_bundled": False,
        "imaging": imaging,
        "materialx": "1.39.5" if materialx else None,
        "files_sha256": {
            str(p.relative_to(destination)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(destination.rglob("*"))
            if p.is_file()
        },
    }
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    archive = destination.parent / (name + ".tar.gz")
    with tarfile.open(archive, "w:gz") as output:
        output.add(destination, arcname=name)
    archive.with_name(archive.name + ".sha256").write_text(
        hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + archive.name + "\n"
    )
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--imaging", action="store_true")
    parser.add_argument("--materialx", action="store_true")
    args = parser.parse_args()
    print(package(imaging=args.imaging, materialx=args.materialx))
