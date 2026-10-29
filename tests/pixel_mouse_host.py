#!/usr/bin/env python3
"""Reproduce Vaxis mouse negotiation and pixel reporting in a sidebar."""
import os
from pathlib import Path
import shlex
import signal
import sys
import tempfile
from pty_host import Host

script = r'''
import os, sys, tty
tty.setraw(0)
os.write(1, b'\x1b[?1016$p')
reply = b''
while b'$y' not in reply:
    reply += os.read(0, 4096)
assert b'\x1b[?1016;2$y' in reply, reply
os.write(1, b'\x1b[?1002;1003;1004;1016hPIXEL_READY')
with open(sys.argv[1], 'ab', buffering=0) as log:
    while True:
        log.write(os.read(0, 4096))
'''
with tempfile.TemporaryDirectory(prefix='tmuxpp-pixel-', dir='/tmp') as directory:
    log = Path(directory) / 'events'
    host = Host('sleep 60', sidebar=shlex.join([sys.executable, '-c', script, str(log)]))
    def data():
        return log.read_bytes() if log.exists() else b''
    try:
        host.until(lambda: b'PIXEL_READY' in host.text())
        # Content starts at outer column 2, row 2, with 8x16 pixel cells.
        os.write(host.master, b'\x1b[<35;3;4M\x1b[<0;3;4M\x1b[<0;3;4m\x1b[<64;3;4M')
        host.until(lambda: b'\x1b[<35;13;41M' in data() and b'\x1b[<0;13;41M' in data())
        host.until(lambda: b'\x1b[<0;13;41m\x1b[<64;13;41M' in data())
        # Observed Ghostty hover arrived as right-button motion without a press.
        # Normalize it to hover, including modifiers, rather than losing it or
        # inventing an application drag. Use distinct cells for each assertion.
        os.write(host.master, b'\x1b[<34;4;5M\x1b[<42;5;6M')
        host.until(lambda: b'\x1b[<35;21;57M' in data() and b'\x1b[<43;29;73M' in data())
        assert b'\x1b[<34;' not in data() and b'\x1b[<42;' not in data()
        # Capture crossing the pane boundary clamps to the final content cell.
        os.write(host.master, b'\x1b[<0;3;4M\x1b[<32;50;4M\x1b[<0;50;4m')
        host.until(lambda: b'\x1b[<32;173;41M\x1b[<0;173;41m' in data())
        # A genuine right-button drag keeps its identity after a matching press.
        os.write(host.master, b'\x1b[<2;3;4M\x1b[<34;4;5M\x1b[<2;4;5m')
        host.until(lambda: b'\x1b[<2;13;41M\x1b[<34;21;57M\x1b[<2;21;57m' in data())
        host.process.terminate()
        host.finish(128 + signal.SIGTERM)
    finally:
        host.close()
print('Pixel mouse: Vaxis negotiation, hover, click, release, wheel and clamped capture passed.')
