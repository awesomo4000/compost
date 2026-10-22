#!/usr/bin/env python3
"""Exercise the real host in a disposable outer PTY, never the user's terminal."""
import errno
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import termios
import time

BINARY = Path(__file__).resolve().parents[1] / "zig-out/bin/compo"


class Host:
    def __init__(self, command, sidebar=None, floating=None, desktop=False, border_style="plain"):
        self.master, self.slave = pty.openpty()
        self.resize(24, 80)
        self.original = termios.tcgetattr(self.slave)
        self.data = bytearray()
        env = dict(os.environ, SHELL="/bin/sh", TMUXPP_COMMAND=command, COMPO_BORDER_STYLE=border_style)
        env.pop("TMUXPP_DESKTOP", None)
        if desktop:
            env["TMUXPP_DESKTOP"] = "1"
        if sidebar is None:
            env["TMUXPP_SINGLE"] = "1"
        else:
            env.pop("TMUXPP_SINGLE", None)
            env["TMUXPP_SIDEBAR_COMMAND"] = sidebar
        env.pop("TMUXPP_FLOAT", None)
        env.pop("TMUXPP_FLOAT_COMMAND", None)
        if floating is not None:
            env["TMUXPP_FLOAT"] = "1"
            env["TMUXPP_FLOAT_COMMAND"] = floating
        self.process = subprocess.Popen([str(BINARY)], stdin=self.slave,
                                        stdout=self.slave, stderr=self.slave,
                                        env=env, start_new_session=True)

    def resize(self, rows, cols):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ,
                    struct.pack("HHHH", rows, cols, cols * 8, rows * 16))

    def read(self):
        if select.select([self.master], [], [], 0.05)[0]:
            try:
                self.data.extend(os.read(self.master, 65536))
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise

    def text(self):
        text = re.sub(rb"\x1b_G.*?\x1b\\", b"", bytes(self.data), flags=re.S)
        return re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", text)

    def until(self, predicate):
        deadline = time.monotonic() + 15
        while not predicate():
            self.read()
            if time.monotonic() > deadline:
                raise AssertionError("host timeout: " + repr(self.text()[-500:]))

    def finish(self, status):
        self.until(lambda: self.process.poll() is not None)
        while select.select([self.master], [], [], 0.05)[0]:
            self.read()
        assert self.process.returncode == status, (self.process.returncode, self.text()[-500:])
        restored = termios.tcgetattr(self.slave)
        expected = list(self.original)
        # Darwin marks pending canonical input for reprocessing after tcsetattr.
        # PENDIN is transient kernel state, not a mode selected by the host.
        restored[3] &= ~getattr(termios, "PENDIN", 0)
        expected[3] &= ~getattr(termios, "PENDIN", 0)
        assert restored == expected, ("tty modes were not restored", expected, restored)
        assert b"\x1b[?1049l" in self.data, "alternate screen was not closed"

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        os.close(self.master)
        os.close(self.slave)
