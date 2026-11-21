"""Regression tests for local installation without using the real HOME or App."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parent.parent
INSTALLER = REPO / "scripts/install-local.py"
SKILL = REPO / "skills/gemini-task-cli/SKILL.md"


class InstallLocalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gemini-install-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.binary = self.root / "candidate"
        self.binary.write_bytes(b"#!/bin/sh\nprintf 'fake candidate\\n'\n")
        self.binary.chmod(0o755)
        self.shared = self.home / ".local/share/gemini-task/bin/gemini-task"
        self.backup_root = self.home / ".local/share/gemini-task/backups"
        self.skills = [self.home / ".codex/skills/gemini-task-cli",
                       self.home / ".gemini/config/skills/gemini-task-cli"]
        self.links = [self.home / ".local/bin/gemini-task",
                      self.home / ".local/bin/gemini-task-cli",
                      *(directory / "bin/gemini-task" for directory in self.skills)]
        self.env = os.environ.copy()
        self.env["HOME"] = str(self.home)

    def install(self):
        result = subprocess.run(
            [sys.executable, str(INSTALLER), "--binary", str(self.binary)],
            env=self.env, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def assert_installed(self):
        self.assertEqual(self.shared.read_bytes(), self.binary.read_bytes())
        self.assertTrue(os.access(self.shared, os.X_OK))
        for directory in self.skills:
            self.assertEqual((directory / "SKILL.md").read_bytes(), SKILL.read_bytes())
        for link in self.links:
            self.assertTrue(link.is_symlink(), str(link))
            self.assertEqual(link.resolve(), self.shared.resolve())

    def test_first_install_and_repeat_are_idempotent(self):
        self.install()
        self.assert_installed()
        self.assertFalse(self.backup_root.exists())
        before = {p: p.lstat().st_mtime_ns for p in [self.shared, *self.links,
                  *(d / "SKILL.md" for d in self.skills)]}
        self.install()
        self.assert_installed()
        self.assertFalse(self.backup_root.exists())
        self.assertEqual(before, {p: p.lstat().st_mtime_ns for p in before})

    def test_migrates_old_backups_and_preserves_replaced_targets(self):
        self.install()
        expected = {}
        for index, directory in enumerate(self.skills):
            skill_backup = directory / "SKILL.md.backup-20261120-194425"
            content = f"old skill {index}\n".encode()
            skill_backup.write_bytes(content)
            expected[skill_backup] = ("file", content)

            binary_backup = directory / "bin/gemini-task.backup-20261120-194425"
            if index == 0:
                content = b"old binary\x00contents\n"
                binary_backup.write_bytes(content)
                expected[binary_backup] = ("file", content)
            else:
                binary_backup.symlink_to("../old-candidate")
                expected[binary_backup] = ("symlink", "../old-candidate")
            (directory / "unrelated.backup-20261120").write_bytes(b"untouched")

        replaced_skill = self.skills[0] / "SKILL.md"
        replaced_skill.write_bytes(b"previous active skill\n")
        expected[replaced_skill] = ("file", b"previous active skill\n")
        replaced_link = self.links[0]
        replaced_link.unlink()
        replaced_link.symlink_to("/old/target")
        expected[replaced_link] = ("symlink", "/old/target")

        self.install()
        self.assert_installed()
        batches = list(self.backup_root.iterdir())
        self.assertEqual(len(batches), 1)
        batch = batches[0]
        manifest = json.loads((batch / "manifest.json").read_text())
        self.assertEqual(manifest["home"], str(self.home))
        entries = {entry["original"]: entry for entry in manifest["entries"]}
        self.assertEqual(set(entries), {str(path.relative_to(self.home)) for path in expected})
        for original, (kind, value) in expected.items():
            relative = str(original.relative_to(self.home))
            entry = entries[relative]
            self.assertEqual(entry["type"], kind)
            self.assertEqual(entry["backup"], relative)
            saved = batch / entry["backup"]
            if kind == "file":
                self.assertFalse(saved.is_symlink())
                self.assertEqual(saved.read_bytes(), value)
            else:
                self.assertTrue(saved.is_symlink())
                self.assertEqual(os.readlink(saved), value)
                self.assertEqual(entry["link_target"], value)
        for directory in self.skills:
            self.assertEqual((directory / "unrelated.backup-20261120").read_bytes(), b"untouched")
            self.assertFalse(list(directory.glob("SKILL.md.backup-*")))
            self.assertFalse(list((directory / "bin").glob("gemini-task.backup-*")))
        self.install()
        self.assertEqual(list(self.backup_root.iterdir()), batches)


if __name__ == "__main__":
    unittest.main()
