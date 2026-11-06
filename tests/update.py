"""Toolchain proposals must preserve exact pins, build identity and failed inputs."""

import json, shutil, sys, tempfile, unittest
import hashlib
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from config import ROOT, pins
from update import apply
import generate
from bootstrap_optional import apply_patches


class Updates(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "conda.recipe").mkdir()
        for name in ("pixi.toml", "conda.recipe/recipe.yaml"):
            shutil.copy2(ROOT / name, self.root / name)

    def test_unchanged(self):
        before = (self.root / "conda.recipe/recipe.yaml").read_bytes()
        report = apply({}, self.root)
        self.assertEqual(report["before"], report["after"])
        self.assertEqual(before, (self.root / "conda.recipe/recipe.yaml").read_bytes())

    def test_changed_exact_versions(self):
        old = json.loads((self.root / "conda.recipe/recipe.yaml").read_text())
        apply(
            {"openusd": "26.11", "mojo": "1.2.0", "nightly": "1.3.0.dev20261101"},
            self.root,
        )
        self.assertEqual(
            pins(self.root),
            {"openusd": "26.11", "mojo": "1.2.0", "nightly": "1.3.0.dev20261101"},
        )
        new = json.loads((self.root / "conda.recipe/recipe.yaml").read_text())
        self.assertEqual(new["build"]["number"], old["build"]["number"] + 1)
        self.assertEqual(new["package"], old["package"])
        self.assertIn("mojo-compiler ==1.2.0", new["requirements"]["host"])

    def test_colliding_versions_do_not_cascade(self):
        old = pins(self.root)
        apply({"mojo": old["nightly"], "nightly": "1.5.0.dev20261102"}, self.root)
        self.assertEqual(pins(self.root)["mojo"], old["nightly"])

    def test_shell_input_rejected_before_write(self):
        before = (self.root / "pixi.toml").read_bytes()
        with self.assertRaises(ValueError):
            apply({"mojo": "1.2.0; touch /tmp/forbidden"}, self.root)
        self.assertEqual((self.root / "pixi.toml").read_bytes(), before)

    def test_generated_sdk_pin_matches_proposal(self):
        for name in ("native", "src/usd_mojo", "tools"):
            (self.root / name).mkdir(parents=True, exist_ok=True)
        shutil.copy2(
            ROOT / "tools/value_types.json", self.root / "tools/value_types.json"
        )
        with patch.object(generate, "ROOT", self.root):
            generate.generate()
            generate.generate(check=True)
            apply({"openusd": "26.11"}, self.root)
            with self.assertRaises(ValueError):
                generate.generate(check=True)
            generate.generate()
            self.assertIn("2611", (self.root / "native/sdk_pin.h").read_text())
            generate.generate(check=True)

    def test_sdk_patch_idempotence_and_tamper_rejection(self):
        target = self.root / "target.cpp"
        target.write_text("before\n")
        change = self.root / "fix.patch"
        change.write_text(
            "--- a/target.cpp\n+++ b/target.cpp\n@@ -1 +1 @@\n-before\n+after\n"
        )
        digest = lambda text: hashlib.sha256(text.encode()).hexdigest()
        row = {
            "patches": [
                {
                    "patch": str(change),
                    "file": "target.cpp",
                    "patch_sha256": digest(change.read_text()),
                    "before_sha256": digest("before\n"),
                    "after_sha256": digest("after\n"),
                }
            ]
        }
        apply_patches(self.root, row)
        apply_patches(self.root, row)
        self.assertEqual(target.read_text(), "after\n")
        target.write_text("unexpected\n")
        with self.assertRaises(ValueError):
            apply_patches(self.root, row)
        self.assertEqual(target.read_text(), "unexpected\n")


if __name__ == "__main__":
    unittest.main()
