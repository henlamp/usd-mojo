"""Install the pinned USD source build into a relocatable Conda prefix."""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


def main():
    root = Path.cwd()
    prefix = Path(os.environ["PREFIX"])
    compiler = subprocess.check_output(["mojo", "--version"], text=True).strip()
    if compiler != "Mojo 1.1.0 (8189361e)":
        raise RuntimeError(f"Unexpected compiler: {compiler}")
    native = root / "native-build"
    command = [
        "cmake",
        "-S",
        "native",
        "-B",
        str(native),
        "-G",
        "Ninja",
        f"-DCMAKE_PREFIX_PATH={prefix}",
        "-DCMAKE_BUILD_TYPE=Release",
    ]
    if sys.platform == "darwin":
        command.append("-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0")
    subprocess.run(command, check=True)
    subprocess.run(["cmake", "--build", str(native), "--parallel", "2"], check=True)
    subprocess.run(
        ["cmake", "--install", str(native), "--prefix", str(prefix)], check=True
    )
    modules = prefix / "lib/mojo"
    modules.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "mojo",
            "precompile",
            "--Werror",
            "src/usd_mojo",
            "-o",
            str(modules / "usd_mojo.mojoc"),
        ],
        check=True,
    )
    share = prefix / "share/usd-mojo"
    share.mkdir(parents=True, exist_ok=True)
    for name in ["LICENSE", "THIRD_PARTY_NOTICES.md", "CHANGELOG.md"]:
        shutil.copy2(root / name, share / name)
    shutil.copytree(root / "licenses", share / "licenses")
    shutil.copytree(
        root / "docs",
        share / "docs",
        ignore=shutil.ignore_patterns("evidence", "PACKAGE_README.md"),
    )
    shutil.copy2(root / "tools/package_compile.py", share / "compile.py")
    executable = prefix / "bin/usd-mojo-build"
    executable.parent.mkdir(exist_ok=True)
    executable.write_text("""#!/usr/bin/env python3
from pathlib import Path
import runpy

runpy.run_path(str(Path(__file__).resolve().parents[1] / "share/usd-mojo/compile.py"), run_name="__main__")
""")
    executable.chmod(0o755)
    bridge = (
        prefix
        / "lib"
        / (
            "libusd_mojo_bridge.dylib"
            if sys.platform == "darwin"
            else "libusd_mojo_bridge.so"
        )
    )
    if sys.platform == "darwin":
        loads = subprocess.check_output(["otool", "-l", str(bridge)], text=True)
        for rpath in re.findall(
            r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset", loads
        ):
            if rpath.startswith("/"):
                subprocess.run(
                    ["install_name_tool", "-delete_rpath", rpath, str(bridge)],
                    check=True,
                )
        linked = subprocess.check_output(["otool", "-L", str(bridge)], text=True)
        for dependency in re.findall(
            r"^\s+(\S+) \(compatibility", linked, re.MULTILINE
        ):
            if dependency.startswith("/") and not dependency.startswith(
                ("/usr/lib/", "/System/Library/")
            ):
                subprocess.run(
                    [
                        "install_name_tool",
                        "-change",
                        dependency,
                        "@rpath/" + Path(dependency).name,
                        str(bridge),
                    ],
                    check=True,
                )
        subprocess.run(["codesign", "--force", "--sign", "-", str(bridge)], check=True)
    owned = [modules / "usd_mojo.mojoc", bridge]
    owned.extend(p for p in share.rglob("*") if p.is_file())
    for path in owned:
        if re.search(rb"/(?:Users|home)/[A-Za-z0-9_.-]+/", path.read_bytes()):
            raise RuntimeError(f"Personal build path in {path.relative_to(prefix)}")
    manifest = {
        "format": 1,
        "layout": "conda",
        "version": "0.1.0",
        "compiler": compiler,
        "system": sys.platform,
        "machine": "arm64" if sys.platform == "darwin" else "x86_64",
        "sdk_version": 2608,
        "bridge_abi": 2,
        "sdk_bundled": False,
        "files_sha256": {
            str(p.relative_to(prefix)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(owned)
        },
    }
    (share / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
