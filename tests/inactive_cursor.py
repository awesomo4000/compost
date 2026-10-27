#!/usr/bin/env python3
"""Unfocused PTY cursor-only output repaints without stealing keyboard focus."""
import os
from pathlib import Path
import shlex
import signal
import sys
import tempfile
from pty_host import Host

fixture = r'''
import os, signal, sys, tty
from pathlib import Path
tty.setraw(0)
name, directory = sys.argv[1:]
Path(directory, name + '.pid').write_text(str(os.getpid()))
def move(*_): os.write(1, b'\x1b[3;5H')
def hide(*_): os.write(1, b'\x1b[?25l')
signal.signal(signal.SIGUSR1, move)
signal.signal(signal.SIGUSR2, hide)
os.write(1, b'\x1b[38;2;200;200;200;48;2;20;20;20m' + name.encode() + b'\x1b[3;1Hcursor row\x1b[1;1H')
if name == 'MAIN': os.write(1, b'\x1b[?25l')
while True:
 data = os.read(0, 4096)
 with open(Path(directory, name + '.input'), 'ab') as f: f.write(data)
'''
with tempfile.TemporaryDirectory(prefix='compo-cursor-', dir='/tmp') as directory:
    root = Path(directory)
    def command(name): return shlex.join([sys.executable, '-c', fixture, name, directory])
    host = Host(command('MAIN'), sidebar=command('SIDE'))
    try:
        highlight = b'48;2;38;120;98m'
        host.until(lambda: b'SIDE' in host.text() and b'MAIN' in host.text() and highlight in host.data)
        pid = int((root / 'SIDE.pid').read_text())
        host.data.clear()
        os.kill(pid, signal.SIGUSR1)
        host.until(lambda: highlight in host.data and b'\x1b[4;2H' in host.data)
        # Input still goes to the main shell, not the source of cursor movement.
        os.write(host.master, b'main-input')
        host.until(lambda: (root / 'MAIN.input').exists() and b'main-input' in (root / 'MAIN.input').read_bytes())
        host.data.clear()
        os.kill(pid, signal.SIGUSR2)
        host.until(lambda: b'cursor row' in host.text())
        assert highlight not in host.data
        # Focus changes repaint retained windows even without child output.
        os.write(host.master, b'\x1d\t')
        host.data.clear()
        os.write(host.master, b'side-input')
        host.until(lambda: (root / 'SIDE.input').exists() and b'side-input' in (root / 'SIDE.input').read_bytes())
        host.process.terminate()
        host.finish(143)
    finally:
        host.close()
print('Inactive cursor: cursor-only movement, hide, focus changes, and input isolation passed.')
