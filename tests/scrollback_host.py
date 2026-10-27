#!/usr/bin/env python3
"""Isolated PTY history browsing without changing child input or terminal size."""
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
root = Path(sys.argv[1])
root.joinpath('pid').write_text(str(os.getpid()))
def output(*_): os.write(1, b'NEW-OUTPUT\r\n' * 5)
signal.signal(signal.SIGUSR1, output)
os.write(1, b''.join(('history-%02d\r\n' % i).encode() for i in range(60)))
while True:
 data = os.read(0, 4096)
 with root.joinpath('input').open('ab') as f: f.write(data)
 if b'!' in data: break
'''
with tempfile.TemporaryDirectory(prefix='compo-scroll-', dir='/tmp') as directory:
    root = Path(directory)
    host = Host(shlex.join([sys.executable, '-c', fixture, directory]))
    try:
        host.until(lambda: b'history-59' in host.text())
        host.data.clear()
        os.write(host.master, b'\x1b[5;2~')
        host.until(lambda: b'history-20' in host.text())
        host.data.clear()
        os.write(host.master, b'\x1b[6;2~')
        host.until(lambda: b'history-59' in host.text())
        os.write(host.master, b'\x1d[')
        host.data.clear()
        os.write(host.master, b'g')
        host.until(lambda: b'history-00' in host.text())
        host.data.clear()
        os.kill(int((root / 'pid').read_text()), signal.SIGUSR1)
        # Ping via input is intentionally consumed in browse mode.
        os.write(host.master, b'k')
        for _ in range(5): host.read()
        assert b'NEW-OUTPUT' not in host.text()
        assert not (root / 'input').exists()
        os.write(host.master, b'q')
        host.until(lambda: b'NEW-OUTPUT' in host.text())
        host.data.clear()
        os.write(host.master, b'\x1b[<64;5;5M')
        host.until(lambda: b'history-' in host.text())
        host.data.clear()
        os.write(host.master, b'hello')
        host.until(lambda: (root / 'input').exists() and (root / 'input').read_bytes() == b'hello')
        host.until(lambda: b'NEW-OUTPUT' in host.text())
        os.write(host.master, b'!')
        host.finish(0)
    finally:
        host.close()
print('Scrollback: retained history, pinned output, browse keys, wheel and return-on-input passed.')
