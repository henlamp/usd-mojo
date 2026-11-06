"""Compile a foreign Mojo project using only this installed package and SDK.

Invoke with the matching Mojo/OpenUSD environment active. No repository import,
Pixi installation, network access, or Python USD module is needed here.
"""

import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
from pathlib import Path


def validate(root: Path, prefix: Path, manifest):
    if manifest["format"] != 1:
        raise ValueError("Unsupported package manifest format")
    compiler = subprocess.check_output(["mojo", "--version"], text=True).strip()
    if compiler != manifest["compiler"]:
        raise ValueError(
            f"Compiler mismatch: package requires {manifest['compiler']}; active {compiler}"
        )
    if (sys.platform, platform.machine()) != (manifest["system"], manifest["machine"]):
        raise ValueError("Package platform mismatch; use a package built for this host")
    for relative, wanted in manifest["files_sha256"].items():
        path = (root / relative).resolve()
        if not path.is_relative_to(root.resolve()):
            raise ValueError("Package manifest path escapes its directory")
        if hashlib.sha256(path.read_bytes()).hexdigest() != wanted:
            raise ValueError(f"Package integrity mismatch: {relative}")
    header = prefix / "include/pxr/pxr.h"
    version = re.search(r"#define\s+PXR_VERSION\s+(\d+)", header.read_text())
    if not version or int(version[1]) != manifest["sdk_version"]:
        raise ValueError(
            f"SDK mismatch: package requires OpenUSD {manifest['sdk_version']}"
        )
    if manifest.get("sdk_materialx") and not any(
        (prefix / "lib" / ("libusd_usdMtlx" + extension)).is_file()
        for extension in (".dylib", ".so")
    ):
        raise ValueError("This archive requires a MaterialX-enabled OpenUSD SDK")
    if manifest.get("optional_sdk_sha256"):
        identity = prefix / "usd-mojo-sdk.json"
        if (
            not identity.is_file()
            or hashlib.sha256(identity.read_bytes()).hexdigest()
            != manifest["optional_sdk_sha256"]
        ):
            raise ValueError("Optional SDK source/patch identity mismatch")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("-o", "--output", type=Path, required=True)
    parser.add_argument("--materialx", action="store_true")
    parser.add_argument(
        "--materialx-prefix",
        type=Path,
        default=Path(os.environ["USD_MOJO_MATERIALX_PREFIX"])
        if "USD_MOJO_MATERIALX_PREFIX" in os.environ
        else None,
    )
    parser.add_argument(
        "--imaging", action="store_true", help="Link an optional Hydra-enabled package"
    )
    parser.add_argument(
        "--sdk-prefix",
        type=Path,
        default=Path(os.environ.get("USD_MOJO_SDK_PREFIX", sys.prefix)),
    )
    parser.add_argument(
        "-I",
        "--include",
        type=Path,
        action="append",
        default=[],
        help="Additional compiled Mojo dependency directory; repeat for multiple libraries",
    )
    args = parser.parse_args()
    location = Path(__file__).resolve().parent
    try:
        manifest = json.loads((location / "manifest.json").read_text())
        conda = manifest.get("layout") == "conda"
        root = location.parents[1] if conda else location
        validate(root, args.sdk_prefix, manifest)
        if args.imaging and not manifest.get("imaging", False):
            raise ValueError("This package was built without optional Hydra imaging")
        if args.materialx:
            if manifest.get("materialx") != "1.39.5" or args.materialx_prefix is None:
                raise ValueError(
                    "Use a MaterialX-enabled archive and --materialx-prefix"
                )
            version = args.materialx_prefix / "include/MaterialXCore/Generated.h"
            actual = (
                re.findall(
                    r"#define MATERIALX_(?:MAJOR|MINOR|BUILD)_VERSION (\d+)",
                    version.read_text(),
                )
                if version.is_file()
                else []
            )
            if actual != ["1", "39", "5"]:
                raise ValueError("MaterialX SDK version mismatch")
        for include in args.include:
            if not include.is_dir():
                raise ValueError(
                    f"Dependency include directory does not exist: {include}"
                )
        output = args.output.resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        relative = os.path.relpath(root / "lib", output.parent)
        origin = "@executable_path" if sys.platform == "darwin" else "$ORIGIN"
        command = [
            "mojo",
            "build",
            "--Werror",
            "-O3",
            "-I",
            str(root / ("lib/mojo" if conda else "include")),
            "-Xlinker",
            f"-L{root / 'lib'}",
            "-Xlinker",
            "-lusd_mojo_bridge",
            "-Xlinker",
            f"-L{args.sdk_prefix.resolve() / 'lib'}",
        ]
        if args.materialx:
            command += ["-Xlinker", "-lusd_mojo_materialx"]
        if args.imaging:
            command += ["-Xlinker", "-lusd_mojo_imaging"]
        if sys.platform != "darwin":
            # DT_RPATH propagates to the separately supplied SDK's dependencies.
            command += ["-Xlinker", "--disable-new-dtags"]
        rpaths = [
            f"{origin}/{relative}",
            str(args.sdk_prefix.resolve() / "lib"),
            str(Path(sys.prefix).resolve() / "lib"),
        ]
        if args.materialx_prefix:
            rpaths.append(str(args.materialx_prefix.resolve() / "lib"))
        for rpath in dict.fromkeys(rpaths):
            command += ["-Xlinker", "-rpath", "-Xlinker", rpath]
        for include in args.include:
            command += ["-I", str(include.resolve())]
        subprocess.run(command + [str(args.source), "-o", str(output)], check=True)
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as error:
        parser.exit(2, f"usd-mojo: {error}\n")


if __name__ == "__main__":
    main()
