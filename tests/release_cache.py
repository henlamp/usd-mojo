"""Exercise install failures, stale receipts and package identity across retries."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import release
from conda_install import ENTRYPOINT_SCRIPT


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name) / 'output'
        self.output.mkdir()
        self.report = {
            'name': 'usd-mojo', 'version': '0.2.0',
            'source_commit': 'a' * 40, 'sha256': 'b' * 64,
        }
        self.calls = []
        self.projects = set()
        self.failures = 0
        self.installed_sha = self.report['sha256']
        self.cached = None
        for target, value in [
            ('OUTPUT', self.output),
            ('checked_artifact', lambda tag: (None, self.report)),
            ('spec', lambda: {'build': {'string': 'mojo110_3'}, 'tests': [{'script': ['consumer scene.usda']}]}),
        ]:
            mock = patch.object(release, target, value)
            mock.start()
            self.addCleanup(mock.stop)
        mock = patch.dict(os.environ, {
            'PIXI_CACHE_DIR': str(Path(self.directory.name) / 'caller/pixi'),
            'RATTLER_CACHE_DIR': str(Path(self.directory.name) / 'caller/rattler'),
        })
        mock.start()
        self.addCleanup(mock.stop)
        for target, value in [('subprocess.run', self.fake_run), ('time.sleep', lambda _: None)]:
            mock = patch('release.' + target, value)
            mock.start()
            self.addCleanup(mock.stop)

    def fake_run(self, command, *, cwd, env, check):
        project = Path(cwd)
        self.calls.append((command, dict(env)))
        if command[1] == 'init':
            self.assertEqual(list(project.iterdir()), [])
            self.projects.add(project)
        if command[1] == 'add':
            cache = Path(env['RATTLER_CACHE_DIR']) / 'pkgs/dependency'
            cache.parent.mkdir(parents=True, exist_ok=True)
            cache.write_text('immutable cached dependency')
            self.cached = cache
            if self.failures:
                self.failures -= 1
                return subprocess.CompletedProcess(command, 1)
            meta = project / '.pixi/envs/default/conda-meta'
            meta.mkdir(parents=True)
            (meta / 'usd-mojo.json').write_text(json.dumps({
                'name': 'usd-mojo', 'sha256': self.installed_sha,
            }))
        if command[1:3] == ['clean', 'cache']:
            self.assertTrue(self.cached.is_file())
            self.assertIn('--repodata', command)
            self.assertNotIn('--conda', command)
        return subprocess.CompletedProcess(command, 0)

    def receipt(self):
        return json.loads((self.output / 'installed.json').read_text())

    def test_local_install_uses_new_environment_and_existing_dependency_cache(self):
        release.installed('file:///local-channel')
        self.assertEqual(len(self.projects), 1)
        for _, env in self.calls:
            self.assertEqual(env['RATTLER_CACHE_DIR'], os.environ['RATTLER_CACHE_DIR'])
        self.assertTrue(self.cached.is_file())
        self.assertTrue(self.receipt()['fresh_environment'])
        self.assertEqual(self.receipt()['sha256'], self.report['sha256'])
        self.assertEqual(self.receipt()['package_cache'], 'shared')
        self.assertTrue(all(not p.exists() for p in self.projects))

    def test_remote_retry_refreshes_metadata_and_keeps_downloaded_dependencies(self):
        self.failures = 1
        release.installed('https://example.invalid/channel')
        adds = [env for command, env in self.calls if command[1] == 'add']
        self.assertEqual(len(adds), 2)
        self.assertEqual(adds[0]['RATTLER_CACHE_DIR'], adds[1]['RATTLER_CACHE_DIR'])
        self.assertNotEqual(adds[0]['RATTLER_CACHE_DIR'], os.environ['RATTLER_CACHE_DIR'])
        self.assertEqual(self.receipt()['install_attempts'], 2)
        self.assertEqual(self.receipt()['package_cache'], 'isolated')
        self.assertTrue(all(not p.exists() for p in self.projects))

    def test_package_checksum_mismatch_removes_old_success(self):
        (self.output / 'installed.json').write_text('{"status":"passed"}')
        self.installed_sha = 'c' * 64
        with self.assertRaisesRegex(ValueError, 'differs from the checked artifact'):
            release.installed('file:///local-channel')
        self.assertFalse((self.output / 'installed.json').exists())
        self.assertFalse(any(command[1] == 'run' for command, _ in self.calls))

    def test_local_failure_is_not_retried(self):
        self.failures = 1
        with self.assertRaisesRegex(RuntimeError, 'after 1 attempts'):
            release.installed('file:///local-channel')
        self.assertEqual(sum(command[1] == 'add' for command, _ in self.calls), 1)
        self.assertFalse((self.output / 'installed.json').exists())

    def test_remote_retry_limit_fails_without_success_receipt(self):
        self.failures = 6
        with self.assertRaisesRegex(RuntimeError, 'after 6 attempts'):
            release.installed('https://example.invalid/channel')
        self.assertEqual(sum(command[1] == 'add' for command, _ in self.calls), 6)
        self.assertEqual(sum(command[1] == 'clean' for command, _ in self.calls), 5)
        self.assertFalse((self.output / 'installed.json').exists())


class InstalledEntrypoint(unittest.TestCase):
    def test_installed_entrypoint_needs_no_checkout_modules(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        prefix = Path(temporary.name) / 'isolated prefix'
        executable = prefix / 'bin/usd-mojo-build'
        compiler = prefix / 'share/usd-mojo/compile.py'
        executable.parent.mkdir(parents=True)
        compiler.parent.mkdir(parents=True)
        executable.write_text(ENTRYPOINT_SCRIPT)
        compiler.write_text('import sys\nprint("|".join(sys.argv[1:]))\n')
        # Run the actual generated launcher with Python's isolated search path.
        result = subprocess.check_output(
            [sys.executable, '-I', str(executable), 'scene with spaces.mojo', '-o', 'consumer'],
            text=True,
        )
        self.assertEqual(result.strip(), 'scene with spaces.mojo|-o|consumer')


if __name__ == '__main__':
    unittest.main()
