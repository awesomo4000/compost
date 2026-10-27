#!/usr/bin/env python3
"""Move, resize, hide and reveal a third shell over retained background text."""
import os
import re
from pathlib import Path
import shlex
import signal
import sys
import tempfile
from pty_host import Host

with tempfile.TemporaryDirectory(prefix='tmuxpp-float-', dir='/tmp') as directory:
    root = Path(directory)
    def command(label):
        return shlex.join([sys.executable, str(Path(__file__).with_name('float_child.py')), label, directory])
    def data(label, suffix):
        path = root / (label + suffix)
        return path.read_bytes() if path.exists() else b''
    host = Host(command('MAIN'), sidebar=command('DOCK'), floating=command('FLOAT'))
    def painted():
        # Cursor markers can add SGR changes within otherwise unchanged text.
        # Keep cursor positioning while ignoring styling for these layout checks.
        return re.sub(rb"\x1b\[[0-9:;]*m", b"", bytes(host.data))
    try:
        host.until(lambda: b'FLOAT01' in host.text() and b'MAIN01' in host.text())
        assert b'\x1b[8;40H' in host.data
        host.until(lambda: b'[26, 10]' in data('FLOAT', '.sizes'))
        original_sizes = data('FLOAT', '.sizes')
        # Click the floating shell; ordinary typing follows focus.
        os.write(host.master, b'\x1b[<0;40;8M\x1b[<0;40;8mhello')
        host.until(lambda: b'hello' in data('FLOAT', '.input'))
        host.data.clear()
        # Alt-left drag moves without changing the child terminal size.
        os.write(host.master, b'\x1b[<8;40;8M\x1b[<40;46;11M\x1b[<8;46;11m')
        host.until(lambda: b'\x1b[11;46HFLOAT01' in painted())
        assert data('FLOAT', '.sizes') == original_sizes
        assert data('FLOAT', '.input') == b'hello'
        # Alt-right drag resizes the PTY; border handles are the trackpad alternative.
        os.write(host.master, b'\x1b[<10;46;11M\x1b[<42;50;13M\x1b[<10;50;13m')
        host.until(lambda: b'[30, 12]' in data('FLOAT', '.sizes'))
        # Continue resizing without changing the floating origin.
        os.write(host.master, b'\x1b[<10;46;11M\x1b[<42;48;12M\x1b[<10;48;12m')
        host.until(lambda: b'[32, 13]' in data('FLOAT', '.sizes'))
        # Control-Alt-left moves freely without changing the PTY size or docking.
        host.data.clear()
        os.write(host.master, b'\x1b[<24;46;11M\x1b[<56;26;1M\x1b[<24;26;1m')
        host.until(lambda: b'\x1b[2;26HFLOAT01' in painted())
        # Hide, restore the uncovered background, and direct typing to a base shell.
        host.data.clear()
        os.write(host.master, b'\x1df')
        host.until(lambda: b'\x1b[2;25HMAIN01' in painted())
        host.data.clear()
        os.write(host.master, b'\x1df')
        host.until(lambda: b'\x1b[2;26HFLOAT01' in painted())
        os.write(host.master, b'world')
        host.until(lambda: b'helloworld' in data('FLOAT', '.input'))
        # Closing the float restores the same main shell and leaves the dock intact.
        host.data.clear()
        os.write(host.master, b'!')
        host.until(lambda: b'\x1b[2;25HMAIN01' in painted())
        assert data('MAIN', '.sizes') == b'[55, 22]\n'
        host.process.terminate()
        host.finish(128 + signal.SIGTERM)
    finally:
        host.close()
print('Floating shell: focus, drag, resize, free movement, hide/reveal, and close passed.')
