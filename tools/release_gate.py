"""Require matching successful native acceptance for both supported platforms/compilers."""

import argparse
import hashlib
import json
from pathlib import Path

from build import BUILD, ROOT
from evidence import source_hash


def gate(paths):
    current = source_hash(ROOT)
    required = {
        ("darwin", "arm64", "1.1.0"),
        ("darwin", "arm64", "1.2.0.dev2026100905"),
        ("linux", "x86_64", "1.1.0"),
        ("linux", "x86_64", "1.2.0.dev2026100905"),
    }
    accepted, emulated = set(), []
    checks = {
        "sdk",
        "hardening",
        "applications",
        "native_benchmark",
        "sdk_benchmark",
        "package",
    }
    for path in paths:
        report = json.loads(path.read_text())
        assert report.get("completed"), (path, "incomplete acceptance")
        assert report.get("source_sha256") == current, (path, "stale acceptance")
        assert set(report["checks"]) == checks and all(
            row["exit_code"] == 0 for row in report["checks"].values()
        )
        for row in report["checks"].values():
            artifact = path.parent / row["artifact"]
            assert (
                hashlib.sha256(artifact.read_bytes()).hexdigest()
                == row["artifact_sha256"]
            ), (artifact, "changed evidence")
        key = (report["system"], report["machine"], report["compiler"].split()[1])
        if report["execution_kind"] == "native":
            accepted.add(key)
        else:
            emulated.append(key)
    missing = sorted(required - accepted)
    return {
        "status": "blocked" if missing else "passed",
        "source_sha256": current,
        "accepted_native": sorted(accepted),
        "verified_emulated": sorted(emulated),
        "missing_native": missing,
        "reason": "Native Linux/x86 acceptance is required; Rosetta results do not satisfy it."
        if missing
        else "All supported platform/compiler configurations passed at the current source identity.",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("reports", type=Path, nargs="+")
    args = parser.parse_args()
    report = gate(args.reports)
    BUILD.mkdir(parents=True, exist_ok=True)
    (BUILD / "release-gate.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["status"] == "passed" else 1)
