#!/usr/bin/env python3
"""Dependency warnings must never write across composed terminal borders."""
import os
import shlex
import sys
from pty_host import Host

script = '''import os, tty
tty.setraw(0)
os.write(1, b"\\x1b[?7727h\\x1b[>p\\x1b_Gi=1,a=q\\x1b\\\\READY")
received = b""
while b"!" not in received:
    received += os.read(0, 4096)
assert b"EINVAL: dimensions required" in received
'''
host = Host(shlex.join([sys.executable, '-c', script]))
try:
    host.until(lambda: b'READY' in host.text())
    assert b'warning(' not in host.data, 'diagnostic leaked into the composed screen'
    os.write(host.master, b'!')
    host.finish(0)
    end = host.data.index(b'\x1b[?1049l')
    for diagnostic in (b'unimplemented mode: 7727', b'dimensions required', b'ignoring unimplemented CSI p'):
        assert diagnostic in host.data[end:], diagnostic
finally:
    host.close()
print('Diagnostics: warnings deferred until alternate-screen exit; protocol replies still reach the child.')
