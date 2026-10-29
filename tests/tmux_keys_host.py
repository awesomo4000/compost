#!/usr/bin/env python3
"""Application-cursor repeats must never drop tmux out of copy mode."""
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
from pty_host import Host

tmux = shutil.which("tmux")
if tmux is None:
    raise SystemExit("tmux is required for this integration test")

with tempfile.TemporaryDirectory(prefix="compo-tmux-keys-", dir="/tmp") as directory:
    socket = str(Path(directory, "tmux.sock"))
    config = Path(directory, "tmux.conf")
    config.write_text("set -g prefix C-a\nset -s escape-time 20\nset -g mode-keys vi\nset -g default-shell /bin/sh\n")
    env = dict(os.environ)
    env.pop("TMUX", None)
    env.pop("TMUX_PANE", None)
    def run(*args):
        return subprocess.check_output([tmux, "-S", socket, *args], env=env, text=True).strip()
    host = None
    try:
        command = "i=0; while [ $i -lt 100 ]; do printf 'history-%s\\n' $i; i=$((i+1)); done; printf 'HISTORY_READY\\n'; exec /bin/cat"
        run("-f", str(config), "new-session", "-d", "-s", "test", "-x", "78", "-y", "22", command)
        host = Host(shlex.join([tmux, "-S", socket, "attach-session", "-t", "test"]))
        host.until(lambda: b"HISTORY_READY" in host.text())
        os.write(host.master, b"\x01[")
        deadline = time.monotonic() + 5
        while run("display-message", "-p", "-t", "test", "#{pane_in_mode}") != "1":
            host.read()
            assert time.monotonic() < deadline
        # A delayed SS3 final byte previously delivered ESC O first, letting
        # tmux's escape timeout expire and exit copy mode before the arrow.
        os.write(host.master, b"\x1bO")
        deadline = time.monotonic() + .2
        while time.monotonic() < deadline:
            host.read()
        assert run("display-message", "-p", "-t", "test", "#{pane_in_mode}") == "1"
        os.write(host.master, b"A" + b"\x1bOA" * 100 + b"\x1bOD" * 100)
        # A marker command in copy mode verifies that the complete input burst
        # has been handled without injecting any marker text into a shell.
        marker = Path(directory, "processed")
        binding = Path(directory, "marker.conf")
        binding.write_text(f"bind-key -T copy-mode-vi Z run-shell 'touch {marker}'\n")
        run("source-file", str(binding))
        os.write(host.master, b"Z")
        host.until(marker.exists)
        assert run("display-message", "-p", "-t", "test", "#{pane_in_mode}") == "1"
        os.write(host.master, b"q")
        deadline = time.monotonic() + 5
        while run("display-message", "-p", "-t", "test", "#{pane_in_mode}") != "0":
            host.read()
            assert time.monotonic() < deadline
        host.process.terminate()
        host.finish(128 + signal.SIGTERM)
    finally:
        if host is not None:
            host.close()
        subprocess.run([tmux, "-S", socket, "kill-server"], env=env, capture_output=True)
print("Tmux keys: delayed and repeated application arrows stay in copy mode; q exits normally.")
