#!/usr/bin/env python3
"""Cursor state and synchronized child redraws through a real disposable PTY."""
import os
from pathlib import Path
import shlex
import signal
import sys
import tempfile
import time
from pty_host import Host

fixture = r'''
import os, signal, sys, tty
from pathlib import Path
tty.setraw(0)
name, directory = sys.argv[1:]
Path(directory, name + '.pid').write_text(str(os.getpid()))
signal.signal(signal.SIGUSR1, lambda *_: os.write(1, b'\x1b[2;1HSIDE-UPDATE'))
os.write(1, b'\x1b[2 q\x1b[?25h' + name.encode())
while True:
 for key in os.read(0, 4096):
  data = {
   ord('b'): b'\x1b[?2026h\x1b[?25l\x1b[3;1HPARTIAL',
   ord('e'): b'\x1b[3;1HCOMPLETE\x1b[?25h\x1b[?2026l',
   ord('u'): b'\x1b[4;1HUPDATE',
   ord('h'): b'\x1b[?25l',
   ord('v'): b'\x1b[?25h',
   ord('s'): b'\x1b[5 q',
   ord('t'): b'\x1b[?2026h\x1b[5;1HTIMEOUT',
  }.get(key, b'')
  os.write(1, data)
  Path(directory, chr(key) + '.ack').touch()
'''
with tempfile.TemporaryDirectory(prefix='compo-cursor-updates-', dir='/tmp') as directory:
    root = Path(directory)
    def command(name): return shlex.join([sys.executable, '-c', fixture, name, directory])
    host = Host(command('MAIN'), sidebar=command('SIDE'))
    def drain(seconds=.2):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline: host.read()
    def send(key):
        host.data.clear()
        os.write(host.master, key.encode())
        host.until(lambda: (root / (key + '.ack')).exists())
        drain()
    try:
        host.until(lambda: b'MAIN' in host.text() and b'SIDE' in host.text())
        drain()
        send('u')
        assert b'UPDATE' in host.text()
        assert b'\x1b[?25l' not in host.data and b'\x1b[?25h' not in host.data
        send('b')
        assert b'PARTIAL' not in host.text() and b'\x1b[?25l' not in host.data
        os.kill(int((root / 'SIDE.pid').read_text()), signal.SIGUSR1)
        host.until(lambda: b'SIDE-UPDATE' in host.text())
        assert b'PARTIAL' not in host.text() and b'\x1b[?25l' not in host.data
        send('e')
        assert b'COMPLETE' in host.text() and b'PARTIAL' not in host.text()
        assert b'\x1b[?25l' not in host.data and b'\x1b[?25h' not in host.data
        send('h')
        assert host.data.count(b'\x1b[?25l') == 1
        send('v')
        assert host.data.count(b'\x1b[?25h') == 1
        send('s')
        assert host.data.count(b'\x1b[5 q') == 1
        send('t')
        assert b'TIMEOUT' not in host.text()
        host.until(lambda: b'TIMEOUT' in host.text())
        host.process.terminate()
        host.finish(143)
        assert b'\x1b[0 q' in host.data
    finally:
        host.close()
print('Cursor updates: stable visibility, child sync batching, independent panes, timeout, and style passed.')
