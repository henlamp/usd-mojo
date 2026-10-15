"""A foreign project consumes an installed package, then relocates and runs it."""

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from build import BUILD, ROOT
from package import package


def main():
    installed = package()
    # Documentation advertised by the package must be usable after extraction.
    for relative in (
        "README.md",
        "docs/API.md",
        "docs/VALIDATION.md",
        "CHANGELOG.md",
        "licenses/OpenUSD-LICENSE.txt",
        "licenses/OpenUSD-NOTICE.txt",
    ):
        assert (installed / relative).is_file(), relative
    with tempfile.TemporaryDirectory(prefix="foreign-project-", dir=BUILD) as temp:
        parent = Path(temp)
        project = parent / "original"
        shutil.copytree(installed, project / "vendor/usd-mojo")
        source = project / "consumer.mojo"
        source.write_text("""from std.sys import argv
from std.testing import assert_equal
from usd_mojo import Stage

def main() raises:
    var args = argv()
    var stage = Stage(args[1])
    assert_equal(stage.mesh("/World/Robot/Triangle").point_count(), 3)
    print("PASS independent relocated package")
""")
        for path in (ROOT / "tests/fixtures").glob("*.usda"):
            shutil.copy2(path, project / path.name)
        compiler = project / "vendor/usd-mojo/compile.py"
        subprocess.run(
            [
                sys.executable,
                str(compiler),
                str(source),
                "-o",
                str(project / "bin/consumer"),
            ],
            check=True,
        )
        subprocess.run(
            [str(project / "bin/consumer"), str(project / "composed.usda")], check=True
        )
        moved = parent / "relocated project with spaces"
        project.rename(moved)
        subprocess.run(
            [str(moved / "bin/consumer"), str(moved / "composed.usda")], check=True
        )
        bad = parent / "invalid-package"
        shutil.copytree(installed, bad)
        manifest = json.loads((bad / "manifest.json").read_text())
        manifest["compiler"] = "unsupported-compiler"
        (bad / "manifest.json").write_text(json.dumps(manifest))
        result = subprocess.run(
            [
                sys.executable,
                str(bad / "compile.py"),
                str(moved / "consumer.mojo"),
                "-o",
                str(parent / "bad"),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        assert result.returncode == 2 and "Compiler mismatch" in result.stderr, result
        shutil.copy2(installed / "manifest.json", bad / "manifest.json")
        with (bad / "include/usd_mojo.mojoc").open("ab") as output:
            output.write(b"corruption")
        result = subprocess.run(
            [
                sys.executable,
                str(bad / "compile.py"),
                str(moved / "consumer.mojo"),
                "-o",
                str(parent / "bad"),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        assert result.returncode == 2 and "integrity mismatch" in result.stderr, result
    report = {
        "status": "passed",
        "package": installed.name,
        "manifest": json.loads((installed / "manifest.json").read_text()),
        "checks": [
            "packaged-api-and-license-documents",
            "foreign-project-no-source-imports",
            "run-before-and-after-relocation",
            "spaces-in-package-path",
            "compiler-mismatch-rejection",
            "integrity-rejection",
        ],
        "scope": "SDK and matching compiler are supplied separately by the locked environment",
    }
    (BUILD / "package-verification.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
