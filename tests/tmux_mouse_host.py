#!/usr/bin/env python3
"""Single-click tmux pane selection through compo, on an isolated tmux server."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch

from pty_host import Host

tmux = shutil.which("tmux")
if tmux is None:
    raise SystemExit("tmux is required for this integration test")

with tempfile.TemporaryDirectory(prefix="compo-tmux-mouse-", dir="/tmp") as directory:
    socket = str(Path(directory, "tmux.sock"))
    config = Path(directory, "tmux.conf")
    config.write_text("set -g mouse on\nset -g focus-events on\nset -g default-shell /bin/sh\n")
    env = dict(os.environ)
    env.pop("TMUX", None)
    env.pop("TMUX_PANE", None)

    def run(*args):
        return subprocess.check_output([tmux, "-S", socket, *args], env=env, text=True).strip()

    # A mouse-aware application makes tmux request all-motion reports. In that
    # mode an orphan drag used to poison the following single click.
    app = shlex.join([sys.executable, "-c", "import os,tty; tty.setraw(0); os.write(1,b'\x1b[?1003h\x1b[?1006hREADY'); exec('while True: os.read(0,4096)')"])
    host = None
    try:
        run("-f", str(config), "new-session", "-d", "-s", "test", "-x", "78", "-y", "22", app)
        left = run("display-message", "-p", "-t", "test", "#{pane_id}")
        right = run("split-window", "-h", "-t", "test", "-P", "-F", "#{pane_id}", app)
        with patch.dict(os.environ, {"COMPO_TRACE_MOUSE": "1"}):
            host = Host(shlex.join([tmux, "-S", socket, "attach-session", "-t", "test"]))
        host.until(lambda: b"\x1b[?1006h" in host.data and b"READY" in host.text() and b"test" in host.text())
        # Wait for the tmux client to attach and finish negotiating its terminal.
        deadline = time.monotonic() + 5
        while not run("list-clients", "-F", "#{client_name}"):
            host.read()
            assert time.monotonic() < deadline
        for target, x in ((left, 5), (right, 65), (left, 5), (right, 65)):
            # Include ordinary hover and an orphan held-button motion, as can
            # happen after gestures outside the child or a missing release.
            orphan = 34 if target == left else 32
            os.write(host.master, f"\x1b[<35;{x};5M\x1b[<{orphan};{x};5M\x1b[<0;{x};5M\x1b[<0;{x};5m".encode())
            deadline = time.monotonic() + 3
            while run("display-message", "-p", "-t", "test", "#{pane_id}") != target:
                host.read()
                assert time.monotonic() < deadline, ("single click failed", target, host.text()[-1000:])
        assert b"\x1b]52;" not in host.data, "single click emitted clipboard write"
        assert b"mouse_trace" not in host.data, "trace leaked into active terminal"
        # Explicitly finish so deferred trace records can be checked after cleanup.
        host.process.terminate()
        host.finish(143)
        trace = bytes(host.data).split(b"\x1b[?1049l", 1)[1]
        assert trace.count(b"received button=0 release=false") == 4, trace
        assert trace.count(b"received button=0 release=true") == 4, trace
        assert trace.count(b"forward window=") == 8, trace
        assert trace.count(b"normalized orphan drag to hover") == 4, trace
    finally:
        if host is not None:
            host.close()
        subprocess.run([tmux, "-S", socket, "kill-server"], env=env, capture_output=True)

print("Tmux mouse: single clicks switch panes through compo without clipboard output.")
