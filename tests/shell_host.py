#!/usr/bin/env python3
"""Exercise the real host in a disposable outer PTY, never the user's terminal."""
import os
from pathlib import Path
import signal
import shlex
import sys
import tempfile
import time

from pty_host import Host


host = Host("printf 'READY\\n'; read value; printf 'INPUT:%s\\n' \"$value\"; stty size; sleep 0.1; exit 7")
try:
    host.until(lambda: b"READY" in host.text())
    host.resize(30, 100)
    host.process.send_signal(signal.SIGWINCH)
    # Wait for the resized renderer's last row, then let the child read its size.
    host.until(lambda: b"\x1b[29;2H" in host.data)
    os.write(host.master, b"hello\r")
    host.finish(7)
    assert b"INPUT:hello" in host.text()
    assert b"28 98" in host.text(), host.text()[-500:]
finally:
    host.close()

host = Host("printf '\033_Ga=T,f=24,s=1,v=1,i=42;/wAA\033\\\\'; printf 'IMAGE\\n'; read value")
try:
    host.until(lambda: b"a=p,i=1" in host.data)
    assert b"a=t,f=24,s=1,v=1,i=1" in host.data, "image did not use an outer ID"
    assert b"/wAA" in host.data
    host.process.terminate()
    host.finish(128 + signal.SIGTERM)
finally:
    host.close()

print("Shell host: input, resize, exit status, Kitty output, and tty cleanup passed.")

host = Host(
    "printf 'RREADY\\n'; read value; printf 'RIGHT:%s\\n' \"$value\"; read value; printf 'CLICK:%s\\n' \"$value\"; read value; stty size; printf 'EXPANDED\\n'; read value",
    "printf 'LREADY\\n'; read value; printf 'LEFT:%s\\n' \"$value\"; read value; exit 0",
)
try:
    host.until(lambda: b"RREADY" in host.text() and b"LREADY" in host.text())
    os.write(host.master, b"one\r")
    host.until(lambda: b"RIGHT:one" in host.text())
    os.write(host.master, b"\x1d\ttwo\r")
    host.until(lambda: b"LEFT:two" in host.text())
    # Click into the main shell. Split the mouse report across writes.
    os.write(host.master, b"\x1b[<0;30;")
    os.write(host.master, b"1M\x1b[<0;30;1mthree\r")
    host.until(lambda: b"CLICK:three" in host.text())
    host.resize(30, 100)
    host.process.send_signal(signal.SIGWINCH)
    host.until(lambda: b"\x1b[29;2H" in host.data)
    # The sidebar exits independently; the main shell fills the resized root.
    os.write(host.master, b"\x1d\tdone\r")
    # Poll the main shell size after its text moves into the first column.
    host.until(lambda: b"\x1b[2;2H\x1b[0mR" in host.data)
    os.write(host.master, b"size\r")
    host.until(lambda: b"EXPANDED" in host.text())
    assert b"28 98" in host.text()
    host.process.terminate()
    host.finish(128 + signal.SIGTERM)
finally:
    host.close()
print("Two shells: independent input, shortcut focus, click focus, and survivor expansion passed.")

with tempfile.TemporaryDirectory(prefix="tmuxpp-input-", dir="/tmp") as directory:
    left_log = Path(directory) / "left.bin"
    right_log = Path(directory) / "right.bin"
    child = Path(__file__).with_name("mouse_child.py").resolve()
    def command(label, path, pixel):
        return shlex.join([sys.executable, str(child), label, str(path), pixel])
    def contents(path):
        return path.read_bytes() if path.exists() else b""
    host = Host(command("RIGHT_MOUSE", right_log, "/wAA"),
                command("LEFT_MOUSE", left_log, "AP8A"))
    try:
        host.until(lambda: b"RIGHT_MOUSE" in host.text() and b"LEFT_MOUSE" in host.text())
        host.until(lambda: b"i=42;OK" in contents(left_log) and b"i=42;OK" in contents(right_log))
        host.until(lambda: b"a=t,f=24,s=1,v=1,i=1" in host.data and b"a=t,f=24,s=1,v=1,i=2" in host.data)
        host.until(lambda: b"\x1b[2;2H\x1b_Ga=p,i=1" in host.data and b"\x1b[2;25H\x1b_Ga=p,i=2" in host.data)
        # A drag begun in the main window stays there across the wall.
        os.write(host.master, b"\x1b[<0;30;4M\x1b[<32;1;4M\x1b[<0;1;4m")
        expected = b"\x1b[<0;6;3M\x1b[<32;1;3M\x1b[<0;1;3m"
        host.until(lambda: expected in contents(right_log))
        assert b"\x1b[<" not in contents(left_log)
        # A bracketed paste contains literal compositor shortcut bytes.
        paste = b"\x1b[200~a\x1d\tb\x1b[201~"
        os.write(host.master, paste)
        host.until(lambda: paste in contents(right_log))
        assert paste not in contents(left_log)
        os.write(host.master, b"\x1b[<0;2;4M\x1b[<0;2;4m")
        host.until(lambda: b"\x1b[<0;1;3M\x1b[<0;1;3m" in contents(left_log))
        host.process.terminate()
        host.finish(128 + signal.SIGTERM)
    finally:
        host.close()
print("Two shells: mouse translation/capture, paste isolation, reply routing, and image IDs passed.")

# Emulate a terminal sending focus-in when reporting is enabled. Re-enabling it
# on every frame used to create an unbounded redraw/focus feedback loop.
host = Host("printf 'RIGHTREADY\\n'; read value; printf 'GOT:%s\\n' \"$value\"; sleep 10",
            sidebar="printf 'LEFTREADY\\n'; sleep 10")
try:
    host.until(lambda: b"RIGHTREADY" in host.text() and b"LEFTREADY" in host.text())
    deadline = time.monotonic() + 0.4
    replied = 0
    while time.monotonic() < deadline:
        host.read()
        enabled = host.data.count(b"\x1b[?1004h")
        if enabled > replied:
            os.write(host.master, b"\x1b[I" * (enabled - replied))
            replied = enabled
    assert replied == 1, ("focus reporting repeatedly enabled", replied)
    assert b"\x1b[?1004l" not in host.data
    before = len(host.data)
    os.write(host.master, b"hello\r")
    host.until(lambda: b"GOT:hello" in host.text())
    update = bytes(host.data[before:])
    assert b"\x1b[2J" not in update, "typing cleared the screen"
    assert b"LEFTREADY" not in update, "typing repainted the idle sidebar"
    assert len(update) < 6000, len(update)
    host.process.terminate()
    host.finish(128 + signal.SIGTERM)
finally:
    host.close()
print("Focus reports stay enabled; typing updates changed rows without clearing either shell.")

for shutdown_signal in (signal.SIGHUP, signal.SIGINT):
    host = Host("printf 'SIGNALREADY\\n'; read value")
    try:
        host.until(lambda: b'SIGNALREADY' in host.text())
        host.process.send_signal(shutdown_signal)
        host.finish(128 + shutdown_signal)
    finally:
        host.close()
print('SIGHUP and SIGINT restore tty modes and exit with signal status.')
