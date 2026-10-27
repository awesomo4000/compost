#!/usr/bin/env python3
"""Clipboard writes are user initiated; tests capture OSC 52 in a disposable PTY."""
import base64
import os
from pathlib import Path
import re
import shlex
import sys
import tempfile
from pty_host import Host

fixture = r'''
import os, sys, tty
from pathlib import Path
tty.setraw(0)
path = Path(sys.argv[1])
# Neither a write nor a read request from an application should escape.
os.write(1, b'\x1b]52;c;dW53YW50ZWQ=\x1b\\\x1b]52;c;?\x1b\\')
os.write(1, 'alpha世界 e\u0301\r\nsecond\x1b[3;1HREADY'.encode())
while True:
 data = os.read(0, 4096)
 with path.open('ab') as f: f.write(data)
 if data == b'm': os.write(1, b'\x1b[?1000h\x1b[?1006hMOUSE')
 if data == b'p': os.write(1, b'\x1b[?2004hPASTE')
 if data == b'!': break
'''
with tempfile.TemporaryDirectory(prefix='compo-clipboard-', dir='/tmp') as directory:
    log = Path(directory) / 'input'
    host = Host(shlex.join([sys.executable, '-c', fixture, str(log)]))
    def copies():
        return [base64.b64decode(v) for v in re.findall(rb'\x1b\]52;c;([^\x1b]*)\x1b\\', host.data)]
    def select(): os.write(host.master, b'\x1b[<0;2;2M\x1b[<32;6;2M\x1b[<0;6;2m')
    try:
        host.until(lambda: b'READY' in host.text())
        assert b'\x1b]52' not in host.data
        assert not log.exists()
        select()
        os.write(host.master, b'\x1dy')
        host.until(lambda: copies() == [b'alpha'])
        assert not log.exists(), 'selection leaked mouse input to the shell'
        os.write(host.master, b'm')
        host.until(lambda: b'MOUSE' in host.text())
        select()
        host.until(lambda: b'\x1b[<0;1;1M' in log.read_bytes())
        before = log.read_bytes()
        os.write(host.master, b'\x1dc')
        select()
        os.write(host.master, b'\x1dy')
        host.until(lambda: copies() == [b'alpha', b'alpha'])
        assert log.read_bytes() == before, 'forced selection leaked to the application'
        os.write(host.master, b'p')
        host.until(lambda: b'PASTE' in host.text())
        payload = b'\x1b[200~literal\x1dy\nsecond line\x1b[201~'
        os.write(host.master, payload)
        host.until(lambda: log.read_bytes().endswith(payload))
        assert copies() == [b'alpha', b'alpha'], 'paste interpreted a compositor copy shortcut'
        os.write(host.master, b'!')
        host.finish(0)
    finally:
        host.close()
print('Clipboard: pane-local selection, explicit OSC 52 copy, app isolation, and bracketed paste passed.')
