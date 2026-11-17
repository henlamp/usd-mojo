"""Validate release requests and the identity of downloaded package artifacts."""

import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path


def validate_request(tag, ref, publish, reuse_run):
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError("Expected a version tag such as v0.2.0")
    if publish not in {"true", "false"}:
        raise ValueError("Publishing must be explicitly enabled or disabled")
    if publish == "true" and ref != "refs/tags/" + tag:
        raise ValueError("Publishing requires the matching version-tag workflow ref")
    if reuse_run and not re.fullmatch(r"[1-9]\d*", reuse_run):
        raise ValueError("Artifact reuse requires a positive workflow run ID")


def verify_packages(root, source, tag):
    commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=source, text=True
    ).strip()
    recipe_path = source / "conda.recipe/recipe.yaml"
    recipe = json.loads(recipe_path.read_text())
    if tag != "v" + recipe["package"]["version"]:
        raise ValueError("Release tag and package version differ")
    recipe_hash = hashlib.sha256(recipe_path.read_bytes()).hexdigest()
    for system, subdir in [("Linux", "linux-64"), ("macOS", "osx-arm64")]:
        directory = root / ("usd-mojo-release-" + system)
        report = json.loads((directory / "release.json").read_text())
        installed = json.loads((directory / "installed.json").read_text())
        if report["source_commit"] != commit or installed["source_commit"] != commit:
            raise ValueError("Package or installed consumer has the wrong source commit")
        if report["recipe_sha256"] != recipe_hash:
            raise ValueError("Package recipe differs from the release tag")
        if (report["name"], report["version"], report["subdir"]) != (
            recipe["package"]["name"], recipe["package"]["version"], subdir
        ):
            raise ValueError("Package name, version or platform mismatch")
        if any(report.get(key) != expected for key, expected in [
            ("installed_tests", "passed"),
            ("privacy_scan", "passed"),
            ("licenses", "unchanged"),
        ]):
            raise ValueError("Package checks did not pass")
        if installed.get("status") != "passed" or installed.get("fresh_environment") is not True:
            raise ValueError("Fresh installed consumer did not pass")
        name = report["artifact"]
        if Path(name).name != name or not name.endswith(".conda"):
            raise ValueError("Invalid package filename")
        package = directory / subdir / name
        if package.is_symlink() or not package.resolve().is_relative_to(directory.resolve()):
            raise ValueError("Package path escapes its artifact directory")
        digest = hashlib.sha256(package.read_bytes()).hexdigest()
        if digest != report["sha256"] or digest != installed["sha256"]:
            raise ValueError("Package or installed consumer checksum mismatch")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["request", "packages"])
    parser.add_argument("--root", type=Path)
    args = parser.parse_args()
    if args.command == "request":
        validate_request(
            os.environ["RELEASE_TAG"], os.environ["GITHUB_REF"],
            os.environ["REQUEST_PUBLISH"], os.environ.get("REUSE_RUN", ""),
        )
    elif args.root is None:
        parser.error("packages requires --root")
    else:
        verify_packages(args.root, Path.cwd(), os.environ["RELEASE_TAG"])
