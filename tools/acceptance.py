"""Execute a complete candidate acceptance without concealing failed or emulated runs."""

import argparse
import hashlib
import json
import platform
import subprocess
import sys
from pathlib import Path

from build import BUILD, ROOT
from evidence import source_hash


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--execution-kind", choices=["native", "rosetta"], required=True
    )
    parser.add_argument("--asset", type=Path, action="append", default=[])
    args = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    initial = source_hash(ROOT)
    report = {
        "completed": False,
        "source_sha256": initial,
        "execution_kind": args.execution_kind,
        "system": sys.platform,
        "machine": platform.machine(),
        "compiler": subprocess.check_output(["mojo", "--version"], text=True).strip(),
        "checks": {},
    }
    target = BUILD / "acceptance.json"

    def save():
        target.write_text(json.dumps(report, indent=2) + "\n")

    save()
    commands = [
        ("sdk", ["tools/check.py"], "verification.json"),
        ("hardening", ["tools/hardening.py"], "hardening.json"),
        (
            "applications",
            [
                "tools/applications_check.py",
                *[item for path in args.asset for item in ["--asset", str(path)]],
            ],
            "applications/acceptance.json",
        ),
        (
            "native_benchmark",
            ["benchmarks/native_views.py"],
            "native-benchmarks/benchmark.json",
        ),
        (
            "sdk_benchmark",
            ["benchmarks/run.py", "--build-dir", str(BUILD / "benchmarks"), "--small"],
            "benchmarks/benchmark.json",
        ),
        ("package", ["tools/package_check.py"], "package-verification.json"),
    ]
    try:
        for name, command, artifact in commands:
            log = BUILD / f"{name}.log"
            with log.open("w") as output:
                result = subprocess.run(
                    [sys.executable, *command],
                    cwd=ROOT,
                    stdout=output,
                    stderr=subprocess.STDOUT,
                    check=False,
                )
            entry = {
                "exit_code": result.returncode,
                "log_sha256": hashlib.sha256(log.read_bytes()).hexdigest(),
            }
            report["checks"][name] = entry
            save()
            if result.returncode:
                raise RuntimeError(f"{name} failed: {log}")
            data = json.loads((BUILD / artifact).read_text())
            assert data.get("status") == "passed" or data.get("completed") is True, (
                name,
                "incomplete report",
            )
            digest = data.get(
                "source_sha256", data.get("manifest", {}).get("source_sha256")
            )
            assert digest == initial, (
                name,
                "source identity mismatch",
                digest,
                initial,
            )
            entry["artifact"] = artifact
            entry["artifact_sha256"] = hashlib.sha256(
                (BUILD / artifact).read_bytes()
            ).hexdigest()
            print(name + ": passed", flush=True)
        assert source_hash(ROOT) == initial, (
            "Source/config/checks changed during acceptance"
        )
        report["completed"] = True
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        save()


if __name__ == "__main__":
    main()
