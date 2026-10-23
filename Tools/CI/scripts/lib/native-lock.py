#!/usr/bin/env python3
"""Run one command while holding a repository-scoped build or engine lock."""

from __future__ import annotations

import fcntl
import pathlib
import subprocess
import sys


def main() -> int:
    if len(sys.argv) < 4 or sys.argv[2] != "--":
        print("usage: native-lock.py <lock-file> -- <command> [args...]", file=sys.stderr)
        return 64
    lock_path = pathlib.Path(sys.argv[1])
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return subprocess.run(sys.argv[3:], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
