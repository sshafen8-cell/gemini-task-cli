#!/usr/bin/env python3
"""Install the local CLI and its skills without touching unrelated files."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime


REPO = Path(__file__).resolve().parent.parent


def backup_existing(path: Path) -> None:
    if not path.is_symlink() and not path.exists():
        return
    if path.is_dir() and not path.is_symlink():
        raise RuntimeError(f"Refusing to replace a directory: {path}")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = path.with_name(f"{path.name}.backup-{stamp}")
    suffix = 1
    while backup.exists() or backup.is_symlink():
        backup = path.with_name(f"{path.name}.backup-{stamp}-{suffix}")
        suffix += 1
    path.rename(backup)
    print(f"Backed up {path} -> {backup}")


def install_file(source: Path, target: Path, executable: bool = False) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=target.parent, prefix=".gemini-task-", delete=False) as temp:
        staged = Path(temp.name)
    try:
        shutil.copyfile(source, staged)
        staged.chmod(0o755 if executable else 0o644)
        backup_existing(target)
        staged.replace(target)
    finally:
        staged.unlink(missing_ok=True)
    print(f"Installed {target}")


def install_link(target: Path, destination: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    backup_existing(target)
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

    with tempfile.TemporaryDirectory(prefix="gemini-task-build-") as tempdir:
        staged_binary = Path(tempdir) / "gemini-task"
        if binary is None:
            subprocess.run(["swiftc", "-O", str(source), "-o", str(staged_binary)], check=True)
        else:
            shutil.copyfile(binary, staged_binary)
        install_file(staged_binary, shared_binary, executable=True)
        for directory in skill_dirs:
            install_file(skill, directory / "SKILL.md")
        for link in links:
            install_link(link, shared_binary)
    print("Installed. Ensure ~/.local/bin is on PATH. Existing sessions must read the updated skill explicitly.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Installation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
