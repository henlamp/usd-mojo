"""Prepare pinned toolchain changes; generate and test them before opening a draft PR."""

import argparse
import json
import re
import urllib.request
from config import ROOT, pins


def latest():
    def read(url):
        request = urllib.request.Request(
            url, headers={"User-Agent": "usd-mojo-updates"}
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

    return {
        "openusd": read(
            "https://api.github.com/repos/PixarAnimationStudios/OpenUSD/releases/latest"
        )["tag_name"].removeprefix("v"),
        "mojo": read("https://pypi.org/pypi/mojo/json")["info"]["version"],
    }


def apply(versions, root=ROOT):
    old = pins(root)
    new = dict(old, **{k: v for k, v in versions.items() if v})
    for name, value in new.items():
        if not re.fullmatch(r"[0-9]+(?:\.[0-9A-Za-z]+)+", value):
            raise ValueError("Invalid " + name + " version")
    if new["mojo"] == new["nightly"]:
        raise ValueError("Stable and nightly qualification require distinct pins")
    lines = []
    section = ""
    for line in (root / "pixi.toml").read_text().splitlines():
        if line.startswith("["):
            section = line
        if line.startswith("openusd = "):
            line = 'openusd = "==' + new["openusd"] + '"'
        if line.startswith("mojo = "):
            key = (
                "nightly"
                if section == "[feature.nightly.pypi-dependencies]"
                else "mojo"
            )
            line = 'mojo = "==' + new[key] + '"'
        lines.append(line)
    text = "\n".join(lines) + "\n"
    recipe = json.loads((root / "conda.recipe/recipe.yaml").read_text())

    def replace(value):
        if isinstance(value, dict):
            return {k: replace(v) for k, v in value.items()}
        if isinstance(value, list):
            return [replace(v) for v in value]
        if isinstance(value, str):
            return value.replace(
                "openusd ==" + old["openusd"], "openusd ==" + new["openusd"]
            ).replace(
                "mojo-compiler ==" + old["mojo"], "mojo-compiler ==" + new["mojo"]
            )
        return value

    recipe = replace(recipe)
    if new != old:
        number = recipe["build"]["number"] + 1
        recipe["build"]["number"] = number
        recipe["build"]["string"] = (
            "mojo" + "".join(new["mojo"].split(".")) + "_" + str(number)
        )
    # Finish validation before changing either file.
    import tomllib

    tomllib.loads(text)
    (root / "pixi.toml").write_text(text)
    (root / "conda.recipe/recipe.yaml").write_text(json.dumps(recipe, indent=2) + "\n")
    return {
        "before": old,
        "after": new,
        "requires": [
            "pixi lock",
            "generated dispatch check",
            "native acceptance",
            "fresh installed package",
        ],
        "release_authorized": False,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("openusd", "mojo", "nightly"):
        parser.add_argument("--" + option)
    parser.add_argument("--detect", action="store_true")
    parser.add_argument("--latest", action="store_true")
    args = parser.parse_args()
    if args.detect:
        print(json.dumps(latest(), indent=2))
    else:
        versions = latest() if args.latest else {}
        versions.update(
            {
                k: getattr(args, k)
                for k in ("openusd", "mojo", "nightly")
                if getattr(args, k)
            }
        )
        print(json.dumps(apply(versions), indent=2))
