#!/usr/bin/env python3
"""Desktop smoke test: duplicate copies are blocked and crash recovery releases the lock.

Run with no other Swoosh instance open. Only processes started by this script are stopped.
"""
import fcntl
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

app = Path(sys.argv[1] if len(sys.argv) > 1 else "build/Swoosh.app").resolve()
lock_path = "/tmp/dev.swoosh.launcher.instance"
with open(lock_path, "a") as check:
    try:
        fcntl.flock(check, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit("Close the running Swoosh instance before this smoke test.")
    fcntl.flock(check, fcntl.LOCK_UN)

children = []
with tempfile.TemporaryDirectory(prefix="swoosh-smoke-") as temp:
    root = Path(temp)
    copy = root / "Another Swoosh.app"
    shutil.copytree(app, copy)
    environment = dict(os.environ, SWOOSH_LIBRARY=str(root / "library"), SWOOSH_WINDOWED="1")

    def start(bundle):
        child = subprocess.Popen([str(bundle / "Contents/MacOS/Swoosh")], env=environment,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        children.append(child)
        return child

    def assert_holding(child):
        time.sleep(2)
        assert child.poll() is None, "Primary instance exited unexpectedly"
        with open(lock_path, "r") as check:
            try:
                fcntl.flock(check, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return
            raise AssertionError("Primary did not acquire the machine-wide lock")

    try:
        first = start(app)
        assert_holding(first)
        duplicate = start(copy)
        assert duplicate.wait(timeout=5) == 0, "Second copy did not exit cleanly"
        assert first.poll() is None, "Second copy stopped the primary"
        first.kill()
        first.wait(timeout=5)
        replacement = start(copy)
        assert_holding(replacement)
        print("PASS: second copy exits; primary survives; a new copy starts after a crash.")
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=5)
