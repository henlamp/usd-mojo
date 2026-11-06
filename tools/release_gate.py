"""Require matching successful native acceptance for both supported platforms/compilers."""

import argparse
import hashlib
import json
from pathlib import Path

from build import BUILD, ROOT
from evidence import source_hash
from acceptance import EXPECTED_CHECKS
from config import pins


def gate(paths):
    current = source_hash(ROOT)
    versions = pins()
    required = {
        (system, machine, versions[compiler])
        for system, machine in (("darwin", "arm64"), ("linux", "x86_64"))
        for compiler in ("mojo", "nightly")
    }
    accepted, emulated, missing_corpus = set(), [], []

    def require(condition, message):
        if not condition:
            raise ValueError(message)

    for path in paths:
        report = json.loads(path.read_text())
        require(report.get("completed") is True, f"{path}: incomplete acceptance")
        require(report.get("source_sha256") == current, f"{path}: stale acceptance")
        require(
            set(report["checks"]) == set(EXPECTED_CHECKS)
            and all(row["exit_code"] == 0 for row in report["checks"].values()),
            f"{path}: missing or failed checks",
        )
        for name, row in report["checks"].items():
            require(
                row["artifact"] == EXPECTED_CHECKS[name],
                f"{path}: wrong artifact for {name}",
            )
            artifact = (path.parent / row["artifact"]).resolve()
            require(
                artifact.is_relative_to(path.parent.resolve()),
                f"{path}: escaped artifact",
            )
            require(
                hashlib.sha256(artifact.read_bytes()).hexdigest()
                == row["artifact_sha256"],
                f"{artifact}: changed evidence",
            )
            log = path.parent / (name + ".log")
            require(
                hashlib.sha256(log.read_bytes()).hexdigest() == row["log_sha256"],
                f"{log}: changed log",
            )
            data = json.loads(artifact.read_text())
            require(
                data.get("status") == "passed" or data.get("completed") is True,
                f"{artifact}: incomplete evidence",
            )
            identity = data.get(
                "source_sha256", data.get("manifest", {}).get("source_sha256")
            )
            require(identity == current, f"{artifact}: stale evidence")
        key = (report["system"], report["machine"], report["compiler"].split()[1])
        workload = json.loads((path.parent / EXPECTED_CHECKS["workloads"]).read_text())
        require(
            workload.get("installed_source_sha256") == current,
            f"{path}: wrong installed library source",
        )
        if not workload.get("external_corpus_checked"):
            missing_corpus.append(key)
            continue
        if report["execution_kind"] == "native":
            accepted.add(key)
        else:
            require(
                report["execution_kind"] == "rosetta", f"{path}: unknown execution kind"
            )
            emulated.append(key)
    missing = sorted(required - accepted)
    return {
        "status": "blocked" if missing else "passed",
        "source_sha256": current,
        "accepted_native": sorted(accepted),
        "verified_emulated": sorted(emulated),
        "missing_native": missing,
        "missing_external_corpus": sorted(missing_corpus),
        "reason": "Native Linux/x86 acceptance is required; Rosetta results do not satisfy it."
        if missing
        else "All supported platform/compiler configurations passed at the current source identity.",
    }


def require_release_acceptance(directory):
    """Recheck the full downloaded evidence, never trust a summary alone."""
    if directory is None:
        raise ValueError(
            "Release requires --acceptance-root with all four native reports"
        )
    paths = [
        directory / ("usd-mojo-acceptance-" + system) / environment / "acceptance.json"
        for system in ("macOS", "Linux")
        for environment in ("default", "nightly")
    ]
    report = gate(paths)
    if report["status"] != "passed":
        raise ValueError("Release acceptance is blocked: " + report["reason"])
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("reports", type=Path, nargs="*")
    parser.add_argument("--release-root", type=Path)
    args = parser.parse_args()
    if bool(args.reports) == bool(args.release_root):
        parser.error("Provide report paths or --release-root")
    report = (
        require_release_acceptance(args.release_root)
        if args.release_root
        else gate(args.reports)
    )
    BUILD.mkdir(parents=True, exist_ok=True)
    (BUILD / "release-gate.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["status"] == "passed" else 1)
