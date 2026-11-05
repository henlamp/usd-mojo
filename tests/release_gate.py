"""Negative evidence must never satisfy the release gate."""

import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from acceptance import EXPECTED_CHECKS
from build import BUILD, ROOT
from evidence import source_hash
from release_gate import gate, require_release_acceptance
import release
from config import pins


class ReleaseEvidence(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.paths = []
        versions = pins()
        for system, machine, artifact_system in [("darwin", "arm64", "macOS"), ("linux", "x86_64", "Linux")]:
            for compiler, environment in [(versions['mojo'], "default"), (versions['nightly'], "nightly")]:
                directory = Path(self.scratch.name) / ("usd-mojo-acceptance-" + artifact_system) / environment
                directory.mkdir(parents=True)
                report = {
                    "completed": True,
                    "source_sha256": "fixture",
                    "system": system,
                    "machine": machine,
                    "compiler": "Mojo " + compiler,
                    "execution_kind": "native",
                    "checks": {},
                }
                for name, relative in EXPECTED_CHECKS.items():
                    artifact = directory / relative
                    artifact.parent.mkdir(exist_ok=True)
                    artifact.write_text(
                        json.dumps(
                            {
                                "completed": True,
                                "source_sha256": "fixture",
                                "installed_source_sha256": "fixture",
                                "external_corpus_checked": True,
                            }
                        )
                    )
                    log = directory / (name + ".log")
                    log.write_text("successful test log\n")
                    report["checks"][name] = {
                        "exit_code": 0,
                        "artifact": relative,
                        "artifact_sha256": self.digest(artifact),
                        "log_sha256": self.digest(log),
                    }
                target = directory / "acceptance.json"
                target.write_text(json.dumps(report))
                self.paths.append(target)
        self.mock_hash = patch("release_gate.source_hash", return_value="fixture")
        self.mock_hash.start()
        self.addCleanup(self.mock_hash.stop)

    @staticmethod
    def digest(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def change(self, transform):
        path = self.paths[0]
        report = json.loads(path.read_text())
        transform(report)
        path.write_text(json.dumps(report))

    def test_complete_matrix(self):
        self.assertEqual(gate(self.paths)["status"], "passed")

    def test_missing_linux(self):
        self.assertEqual(len(gate(self.paths[:2])["missing_native"]), 2)

    def test_emulated_not_native(self):
        self.change(lambda r: r.update(execution_kind="rosetta"))
        self.assertEqual(gate(self.paths)["status"], "blocked")

    def test_stale(self):
        self.change(lambda r: r.update(source_sha256="old"))
        with self.assertRaisesRegex(ValueError, "stale"):
            gate(self.paths)

    def test_missing_new_check(self):
        self.change(lambda r: r["checks"].pop("mutation_array_benchmark"))
        with self.assertRaisesRegex(ValueError, "missing or failed"):
            gate(self.paths)

    def test_failed(self):
        self.change(lambda r: r["checks"]["sdk"].update(exit_code=1))
        with self.assertRaisesRegex(ValueError, "missing or failed"):
            gate(self.paths)

    def test_changed_artifact(self):
        (self.paths[0].parent / "verification.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "changed evidence"):
            gate(self.paths)

    def test_changed_log(self):
        (self.paths[0].parent / "sdk.log").write_text("failed test")
        with self.assertRaisesRegex(ValueError, "changed log"):
            gate(self.paths)

    def test_escaping_artifact(self):
        self.change(
            lambda r: r["checks"]["sdk"].update(artifact="../verification.json")
        )
        with self.assertRaisesRegex(ValueError, "wrong artifact"):
            gate(self.paths)

    def alter_workload(self, changes):
        path = self.paths[0].parent / EXPECTED_CHECKS["workloads"]
        report = json.loads(path.read_text())
        report.update(changes)
        path.write_text(json.dumps(report))
        self.change(
            lambda r: r["checks"]["workloads"].update(artifact_sha256=self.digest(path))
        )

    def test_generated_only_is_insufficient(self):
        self.alter_workload({"external_corpus_checked": False})
        self.assertEqual(gate(self.paths)["status"], "blocked")

    def test_incomplete_artifact_with_success_exit(self):
        self.alter_workload({"completed": False})
        with self.assertRaisesRegex(ValueError, "incomplete evidence"):
            gate(self.paths)

    def test_wrong_installed_library(self):
        self.alter_workload({"installed_source_sha256": "older"})
        with self.assertRaisesRegex(ValueError, "wrong installed library source"):
            gate(self.paths)

    def test_release_download_layout(self):
        self.assertEqual(require_release_acceptance(Path(self.scratch.name))["status"], "passed")

    def upload(self):
        with patch.object(release, "checked_artifact", return_value=(Path("checked.conda"), {"name": "usd-mojo"})), \
             patch.dict(os.environ, {"GITHUB_REPOSITORY": "henlamp/usd-mojo"}):
            return release.publish("v0.2.0", Path(self.scratch.name), "rattler-build")

    def test_publish_rechecks_complete_evidence(self):
        with patch.object(release.subprocess, "run") as upload:
            self.upload()
            upload.assert_called_once()
            self.assertEqual(upload.call_args.args[0][:3], ["rattler-build", "upload", "prefix"])

    def test_publish_refuses_missing_linux_without_upload(self):
        self.paths[-1].unlink()
        self.assert_upload_rejected(FileNotFoundError)

    def assert_upload_rejected(self, error, message=".*"):
        with patch.object(release.subprocess, "run") as upload:
            with self.assertRaisesRegex(error, message):
                self.upload()
            upload.assert_not_called()

    def test_publish_refuses_stale_evidence_without_upload(self):
        self.change(lambda r: r.update(source_sha256="old"))
        self.assert_upload_rejected(ValueError, "stale")

    def test_publish_refuses_failed_check_without_upload(self):
        self.change(lambda r: r["checks"]["sdk"].update(exit_code=1))
        self.assert_upload_rejected(ValueError, "missing or failed")

    def test_publish_refuses_generated_only_without_upload(self):
        self.alter_workload({"external_corpus_checked": False})
        self.assert_upload_rejected(ValueError, "blocked")

    def test_publish_refuses_tampered_log_without_upload(self):
        (self.paths[0].parent / "sdk.log").write_text("failed")
        self.assert_upload_rejected(ValueError, "changed log")

    def test_missing_release_evidence(self):
        with self.assertRaisesRegex(ValueError, "acceptance-root"):
            require_release_acceptance(None)


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(ReleaseEvidence)
    )
    BUILD.mkdir(parents=True, exist_ok=True)
    (BUILD / "release-gate-tests.json").write_text(
        json.dumps(
            {
                "completed": result.wasSuccessful(),
                "source_sha256": source_hash(ROOT),
                "tests": result.testsRun,
            },
            indent=2,
        )
        + "\n"
    )
    raise SystemExit(0 if result.wasSuccessful() else 1)
