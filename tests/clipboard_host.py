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
 if data == b'?':
  os.write(1, b'CLICK-CHECKED')
  continue
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
        host.data.clear()
        # A focus click, even with a same-cell motion report, is not a selection.
        os.write(host.master, b'\x1b[<0;20;8M\x1b[<32;20;8M\x1b[<0;20;8m\x1dy?')
        host.until(lambda: b'CLICK-CHECKED' in host.text())
        assert copies() == [], 'plain click left a copyable one-cell selection'
        assert b'\x1b[7m' not in host.data, 'plain click painted a selection highlight'
        select()
        os.write(host.master, b'\x1dy')
        host.until(lambda: copies() == [b'alpha'] and b'[ 5 copied ]' in host.text())
        assert not log.exists(), 'selection leaked mouse input to the shell'
        os.write(host.master, b'm')
        host.until(lambda: b'MOUSE' in host.text())
        select()
        # Wait for the full click before snapshotting. The child's read can split
        # press/release across iterations; waiting only for press races the rest.
        host.until(lambda: b'\x1b[<0;1;1M' in log.read_bytes() and log.read_bytes().endswith(b'\x1b[<0;5;1m'))
        before = log.read_bytes()
        os.write(host.master, b'\x1dc')
        select()
        os.write(host.master, b'\x1dy')
        host.until(lambda: copies() == [b'alpha', b'alpha'])
        assert log.read_bytes() == before, 'forced selection leaked to the application'
        os.write(host.master, b'p')
        host.until(lambda: b'PASTE' in host.text())
        body = 'literal\x1dy\nsecond 世界 🟢'.encode()
        payload = b'\x1b[200~' + body + b'\x1b[201~'
        # Fragment UTF-8 and the paste delimiters across writes.
        for byte in payload: os.write(host.master, bytes([byte]))
        host.until(lambda: log.read_bytes().endswith(payload))
        assert copies() == [b'alpha', b'alpha'], 'paste interpreted a compositor copy shortcut'
        notice = ('[ %d pasted ]' % len(body.decode())).encode()
        host.until(lambda: notice in host.text())
        host.data.clear()
        # The idle timer restores the top border with no further child output.
        host.until(lambda: b'\x1b[1;' in host.data)
        assert b' copied ]' not in host.text() and b' pasted ]' not in host.text()
        os.write(host.master, b'!')
        host.finish(0)
    finally:
        host.close()
print('Clipboard: pane-local selection, explicit OSC 52 copy, app isolation, and bracketed paste passed.')
