"""Build a relocatable compiler/platform-matched package; the SDK remains external."""

import hashlib
import json
import platform
import re
import shutil
import subprocess
import sys
import tarfile

import tomllib
from build import BUILD, ROOT, build
from evidence import SCOPE, source_hash


def package():
    build()
    version = tomllib.loads((ROOT / "pixi.toml").read_text())["workspace"]["version"]
    compiler = subprocess.check_output(["mojo", "--version"], text=True).strip()
    compiler_version = compiler.split()[1]
    name = (
        f"usd-mojo-{version}-{sys.platform}-{platform.machine()}-mojo{compiler_version}"
    )
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
    for filename in ("LICENSE", "THIRD_PARTY_NOTICES.md", "CHANGELOG.md"):
        shutil.copy2(ROOT / filename, destination / filename)
    shutil.copy2(ROOT / "docs/PACKAGE_README.md", destination / "README.md")
    shutil.copytree(ROOT / "docs", destination / "docs")
    shutil.copytree(ROOT / "licenses", destination / "licenses")
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
        "sdk_version": 2608,
        "bridge_abi": 2,
        "sdk_bundled": False,
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
    print(package())
