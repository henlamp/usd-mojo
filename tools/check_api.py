"""Compare the documented public source surface with an explicitly reviewed baseline."""

import argparse
import json
import re

from build import BUILD, ROOT
from evidence import source_hash


def snapshot(root=ROOT):
    declarations = {}
    magic = {"__init__", "__deinit__", "__eq__", "__ne__", "write_to"}

    def public(name):
        return not name.startswith("_") or name in magic

    for path in sorted((root / "src/usd_mojo").glob("*.mojo")):
        lines = path.read_text().splitlines()
        owner = ""
        i = 0
        while i < len(lines):
            line = lines[i]
            stripped = line.strip()
            indent = len(line) - len(line.lstrip())
            type_match = re.match(r"struct (\w+)", stripped)
            function = re.match(r"def (\w+)", stripped)
            if indent == 0 and type_match:
                owner = type_match[1]
            if indent == 0 and function:
                owner = ""
            match = type_match if indent == 0 and type_match else function
            if (
                match
                and indent in {0, 4}
                and public(match[1])
                and (not owner or public(owner))
            ):
                decorators = []
                previous = i - 1
                while previous >= 0 and lines[previous].strip().startswith("@"):
                    decorators.insert(0, lines[previous].strip())
                    previous -= 1
                signature = [stripped]
                while not signature[-1].endswith(":"):
                    i += 1
                    signature.append(lines[i].strip())
                name = ".".join(
                    x for x in (path.stem, owner, match[1] if function else "") if x
                )
                declarations.setdefault(name, []).append(
                    " ".join(decorators + signature)[:-1]
                )
            elif indent == 4 and owner and public(owner):
                field = re.match(r"(?:var|comptime) (\w+)\s*[:=]", stripped)
                if field and public(field[1]):
                    declarations.setdefault(
                        f"{path.stem}.{owner}.{field[1]}", []
                    ).append(stripped)
            i += 1
    init = (root / "src/usd_mojo/__init__.mojo").read_text()
    imports = re.findall(
        r"from\s+\.[\w]+\s+import\s+(\([^)]*\)|[^\n]+)", init, re.DOTALL
    )
    exports = sorted(
        {
            name.strip()
            for entry in imports
            for name in entry.strip("()").split(",")
            if name.strip()
        }
    )
    return {
        "api_version": "0.1",
        "exports": exports,
        "declarations": {k: sorted(v) for k, v in sorted(declarations.items())},
    }


def canonical(declarations):
    # Whitespace outside quoted strings does not change a source signature.
    tokens = r'"(?:\\.|[^"\\])*"|\w+|[^\w\s]'
    return {
        key: sorted(tuple(re.findall(tokens, value)) for value in values)
        for key, values in declarations.items()
    }


def check():
    actual = snapshot()
    expected = json.loads((ROOT / "tests/api/usd_mojo.json").read_text())
    if actual["exports"] != expected["exports"] or canonical(
        actual["declarations"]
    ) != canonical(expected["declarations"]):
        changed = sorted(
            k
            for k in set(actual["declarations"]) | set(expected["declarations"])
            if canonical(actual["declarations"]).get(k)
            != canonical(expected["declarations"]).get(k)
        )
        raise RuntimeError(
            f"Public API differs: {changed}; review the compatibility impact before changing the baseline"
        )
    report = {
        "status": "passed",
        "public_exports": len(actual["exports"]),
        "public_declarations": len(actual["declarations"]),
        "source_sha256": source_hash(ROOT),
    }
    BUILD.mkdir(parents=True, exist_ok=True)
    (BUILD / "api-verification.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--record",
        action="store_true",
        help="Record a manually reviewed API revision; never used in CI",
    )
    if parser.parse_args().record:
        path = ROOT / "tests/api/usd_mojo.json"
        path.parent.mkdir(exist_ok=True)
        path.write_text(json.dumps(snapshot(), indent=2) + "\n")
    print(json.dumps(check(), indent=2))
