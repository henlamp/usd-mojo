"""Reject mismatched release refs and changed or incomplete package artifacts."""

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from release_workflow import validate_request, verify_packages


class ReleaseRequest(unittest.TestCase):
    def test_validation_from_branch_does_not_request_publication(self):
        validate_request("v0.2.0", "refs/heads/main", "false", "42189435215")

    def test_publication_from_exact_tag(self):
        validate_request("v0.2.0", "refs/tags/v0.2.0", "true", "")

    def test_invalid_requests_are_rejected(self):
        for tag, ref, publish, reuse in [
            ("v0.2.0", "refs/heads/main", "true", ""),
            ("v0.2.0", "refs/tags/v0.1.0", "true", ""),
            ("main", "refs/heads/main", "false", ""),
            ("v0.2.0", "refs/heads/main", "yes", ""),
            ("v0.2.0", "refs/heads/main", "false", "../123"),
            ("v0.2.0", "refs/heads/main", "false", "0"),
        ]:
            with self.subTest(tag=tag, ref=ref, publish=publish, reuse=reuse):
                with self.assertRaises(ValueError):
                    validate_request(tag, ref, publish, reuse)


class DownloadedPackages(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "source"
        recipe = self.source / "conda.recipe/recipe.yaml"
        recipe.parent.mkdir(parents=True)
        recipe.write_text(json.dumps({"package": {"name": "usd-mojo", "version": "0.2.0"}}))
        self.artifacts = self.root / "artifacts"
        self.directories = []
        for system, subdir in [("Linux", "linux-64"), ("macOS", "osx-arm64")]:
            directory = self.artifacts / ("usd-mojo-release-" + system)
            (directory / subdir).mkdir(parents=True)
            package = directory / subdir / "usd-mojo-0.2.0-mojo120_18.conda"
            package.write_bytes(b"qualified package " + system.encode())
            digest = hashlib.sha256(package.read_bytes()).hexdigest()
            report = {
                "source_commit": "a" * 40,
                "recipe_sha256": hashlib.sha256(recipe.read_bytes()).hexdigest(),
                "name": "usd-mojo", "version": "0.2.0", "subdir": subdir,
                "artifact": package.name, "sha256": digest,
                "installed_tests": "passed", "privacy_scan": "passed", "licenses": "unchanged",
            }
            installed = {
                "source_commit": "a" * 40, "sha256": digest,
                "status": "passed", "fresh_environment": True,
            }
            (directory / "release.json").write_text(json.dumps(report))
            (directory / "installed.json").write_text(json.dumps(installed))
            self.directories.append(directory)
        mock = patch("release_workflow.subprocess.check_output", return_value="a" * 40)
        mock.start()
        self.addCleanup(mock.stop)

    def verify(self):
        verify_packages(self.artifacts, self.source, "v0.2.0")

    def test_matching_packages(self):
        self.verify()

    def test_rejects_tag_version_mismatch(self):
        with self.assertRaisesRegex(ValueError, "tag and package"):
            verify_packages(self.artifacts, self.source, "v0.1.0")

    def test_rejects_changed_reports_on_either_platform(self):
        for directory in self.directories:
            for filename, field, value in [
                ("release.json", "source_commit", "old"),
                ("installed.json", "source_commit", "old"),
                ("release.json", "recipe_sha256", "old"),
                ("release.json", "name", "another-package"),
                ("release.json", "version", "0.1.0"),
                ("release.json", "subdir", "wrong"),
                ("release.json", "artifact", "../outside.conda"),
                ("release.json", "privacy_scan", "failed"),
                ("release.json", "installed_tests", "failed"),
                ("release.json", "licenses", "changed"),
                ("installed.json", "fresh_environment", False),
                ("installed.json", "status", "failed"),
                ("installed.json", "sha256", "b" * 64),
                ("release.json", "sha256", "b" * 64),
            ]:
                with self.subTest(platform=directory.name, filename=filename, field=field):
                    path = directory / filename
                    original = path.read_text()
                    report = json.loads(original)
                    report[field] = value
                    path.write_text(json.dumps(report))
                    with self.assertRaises(ValueError):
                        self.verify()
                    path.write_text(original)

    def test_rejects_changed_package(self):
        package = next(self.directories[0].rglob("*.conda"))
        package.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.verify()

    def test_rejects_symlinked_package(self):
        package = next(self.directories[0].rglob("*.conda"))
        outside = self.root / "outside.conda"
        package.rename(outside)
        package.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "escapes"):
            self.verify()

    def test_rejects_missing_consumer_receipt(self):
        (self.directories[1] / "installed.json").unlink()
        with self.assertRaises(FileNotFoundError):
            self.verify()


if __name__ == "__main__":
    unittest.main()
