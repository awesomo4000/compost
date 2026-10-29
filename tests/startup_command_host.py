#!/usr/bin/env python3
"""Prove command-to-interactive-shell handoff in the real compositor PTY."""
import os
from pathlib import Path
import shlex
import tempfile

from pty_host import Host


with tempfile.TemporaryDirectory(prefix="compo-startup-", dir="/tmp") as directory:
    # An isolated rc file gives the test an explicit readiness signal without
    # reading a prompt, sleeping, or loading the user's shell configuration.
    rc = Path(directory) / "bashrc"
    rc.write_text("printf 'SHELL_%s\\n' READY\n")
    for status in (0, 7):
        script = (
            f"cd {shlex.quote(directory)}; export COMPO_STARTUP_TEST=kept; "
            f"/bin/sh -c 'exit {status}'; "
            f"exec /bin/bash --noprofile --rcfile {shlex.quote(str(rc))} -i"
        )
        host = Host(shlex.join(["/bin/bash", "-c", script]))
        try:
            host.until(lambda: b"SHELL_READY" in host.text())
            assert host.process.poll() is None
            os.write(host.master, b"printf 'ENV_%s\\n' \"$COMPO_STARTUP_TEST\"; pwd; case $- in *i*) printf 'MODE_%s\\n' interactive;; esac\r")
            host.until(lambda: b"ENV_kept" in host.text() and b"MODE_interactive" in host.text())
            assert os.fsencode(directory) in host.text()
            os.write(host.master, b"exit 9\r")
            host.finish(9)
        finally:
            host.close()

print("Startup command: success/failure handoff, interactive input, cwd/environment, shell exit, and tty cleanup passed.")
