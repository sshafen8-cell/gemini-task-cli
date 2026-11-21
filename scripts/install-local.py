#!/usr/bin/env python3
"""Install the local CLI and its skills without touching unrelated files."""

import argparse
import filecmp
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime


REPO = Path(__file__).resolve().parent.parent


class Backups:
    def __init__(self, home: Path) -> None:
        self.home = home
        self.root = None
        self.entries = []

    def move(self, path: Path) -> None:
        if not path.is_symlink() and not path.exists():
            return
        if path.is_dir() and not path.is_symlink():
            raise RuntimeError(f"Refusing to replace a directory: {path}")
        if self.root is None:
            parent = self.home / ".local/share/gemini-task/backups"
            parent.mkdir(parents=True, exist_ok=True)
            stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            suffix = 0
            while True:
                candidate = parent / (stamp if suffix == 0 else f"{stamp}-{suffix}")
                try:
                    candidate.mkdir()
                    self.root = candidate
                    break
                except FileExistsError:
                    suffix += 1
        relative = path.relative_to(self.home)
        backup = self.root / relative
        backup.parent.mkdir(parents=True, exist_ok=True)
        entry = {"original": str(relative), "backup": str(relative),
                 "type": "symlink" if path.is_symlink() else "file"}
        if path.is_symlink():
            entry["link_target"] = os.readlink(path)
        path.rename(backup)
        self.entries.append(entry)
        manifest = self.root / "manifest.json"
        manifest.write_text(json.dumps({"home": str(self.home), "entries": self.entries},
                                       ensure_ascii=False, indent=2) + "\n")
        print(f"Backed up {path} -> {backup}")


def install_file(source: Path, target: Path, backups: Backups, executable: bool = False) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_file() and not target.is_symlink() and filecmp.cmp(source, target, shallow=False):
        mode = 0o755 if executable else 0o644
        if stat.S_IMODE(target.stat().st_mode) != mode:
            target.chmod(mode)
        print(f"Unchanged {target}")
        return
    with tempfile.NamedTemporaryFile(dir=target.parent, prefix=".gemini-task-", delete=False) as temp:
        staged = Path(temp.name)
    try:
        shutil.copyfile(source, staged)
        staged.chmod(0o755 if executable else 0o644)
        backups.move(target)
        staged.replace(target)
    finally:
        staged.unlink(missing_ok=True)
    print(f"Installed {target}")


def install_link(target: Path, destination: Path, backups: Backups) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_symlink() and target.resolve() == destination.resolve():
        print(f"Unchanged {target}")
        return
    backups.move(target)
    target.symlink_to(destination)
    print(f"Linked {target} -> {destination}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Install gemini-task for this macOS user and register both skills.")
    parser.add_argument("--binary", metavar="ABS", help="absolute path to a compiled executable; otherwise compile GeminiTask.swift")
    args = parser.parse_args()

    source = REPO / "GeminiTask.swift"
    skill = REPO / "skills" / "gemini-task-cli" / "SKILL.md"
    if not source.is_file() or not skill.is_file():
        parser.error("The repository source or skill file is missing.")
    if args.binary:
        binary = Path(args.binary)
        if not binary.is_absolute() or not binary.is_file() or not os.access(binary, os.X_OK):
            parser.error("--binary must be an absolute path to an existing executable file.")
    else:
        binary = None

    home = Path.home()
    shared_binary = home / ".local/share/gemini-task/bin/gemini-task"
    skill_dirs = [home / ".codex/skills/gemini-task-cli", home / ".gemini/config/skills/gemini-task-cli"]
    links = [home / ".local/bin/gemini-task", home / ".local/bin/gemini-task-cli"]
    links.extend(directory / "bin/gemini-task" for directory in skill_dirs)
    targets = [shared_binary, *(directory / "SKILL.md" for directory in skill_dirs), *links]
    for target in targets:
        if target.is_dir() and not target.is_symlink():
            raise RuntimeError(f"Refusing to replace a directory: {target}")

    backups = Backups(home)
    for directory in skill_dirs:
        # Only migrate backups of the two files installed by this project.
        for pattern in ("SKILL.md.backup-*", "bin/gemini-task.backup-*"):
            for old_backup in sorted(directory.glob(pattern)):
                if old_backup.is_symlink() or old_backup.is_file():
                    backups.move(old_backup)

    with tempfile.TemporaryDirectory(prefix="gemini-task-build-") as tempdir:
        staged_binary = Path(tempdir) / "gemini-task"
        if binary is None:
            subprocess.run(["swiftc", "-O", str(source), "-o", str(staged_binary)], check=True)
        else:
            shutil.copyfile(binary, staged_binary)
        install_file(staged_binary, shared_binary, backups, executable=True)
        for directory in skill_dirs:
            install_file(skill, directory / "SKILL.md", backups)
        for link in links:
            install_link(link, shared_binary, backups)
    print("Installed. Ensure ~/.local/bin is on PATH. Existing sessions must read the updated skill explicitly.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Installation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
