#!/usr/bin/env python3
"""Help must work without a terminal or a compositor connection."""
import os
from pathlib import Path
import subprocess

binary = Path(__file__).resolve().parents[1] / "zig-out/bin/compo"
env = dict(os.environ)
env.pop("COMPO_SOCKET", None)
for arguments in (("--help",), ("-h",), ("ctl", "--help"), ("ctl", "-h")):
    result = subprocess.run([str(binary), *arguments], env=env, stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=5)
    assert result.returncode == 0, result.stderr
    assert result.stdout.startswith(b"Usage: compo")
    assert result.stderr == b""
    assert b"\x1b" not in result.stdout
    assert b"COMPO_SOCKET=/tmp/" not in result.stdout
print("CLI help: both help flags work without a PTY or control socket.")
