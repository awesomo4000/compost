#!/usr/bin/env python3
"""Border hover, independent edge resizing, and one shared dock divider."""
import os
from pathlib import Path
import shlex
import signal
import sys
import tempfile
from pty_host import Host

with tempfile.TemporaryDirectory(prefix='tmuxpp-border-', dir='/tmp') as directory:
    root = Path(directory)
    def command(label):
        return shlex.join([sys.executable, str(Path(__file__).with_name('float_child.py')), label, directory])
    def sizes(label):
        p = root / (label + '.sizes')
        return p.read_bytes() if p.exists() else b''
    def drag(x, y, end_x, end_y):
        os.write(host.master, f'\x1b[<0;{x};{y}M\x1b[<32;{end_x};{end_y}M\x1b[<0;{end_x};{end_y}m'.encode())
    host = Host(command('MAIN'), sidebar=command('DOCK'), floating=command('FLOAT'))
    try:
        host.until(lambda: b'FLOAT01' in host.text() and b'MAIN01' in host.text())
        assert b'\x1b[2;25H\x1b[0mMAIN01' in host.data
        assert b'[55, 22]' in sizes('MAIN')
        assert b'\x1b[0;36m\x1b[2;24H' in host.data, 'shared border must use main focus color'
        host.data.clear()
        os.write(host.master, b'\x1b[<35;39;10M')
        host.until(lambda: b'\x1b[0;37m' in host.data)
        assert b'\x1b[2J' not in host.data
        # Left edge changes x/width, preserving right edge and height.
        host.data.clear()
        drag(39, 10, 35, 10)
        host.until(lambda: b'[30, 10]' in sizes('FLOAT') and b'\x1b[8;36H\x1b[0mFLOAT01' in host.data)
        # Top edge changes y/height; x/width remain fixed.
        host.data.clear()
        drag(40, 7, 40, 5)
        host.until(lambda: b'[30, 12]' in sizes('FLOAT') and b'\x1b[6;36H\x1b[0mFLOAT01' in host.data)
        drag(66, 10, 70, 10)
        host.until(lambda: b'[34, 12]' in sizes('FLOAT'))
        drag(40, 18, 40, 20)
        host.until(lambda: b'[34, 14]' in sizes('FLOAT'))
        assert sizes('MAIN') == b'[55, 22]\n'
        assert sizes('DOCK') == b'[22, 22]\n'
        assert (root / 'FLOAT.input').read_bytes() == b''
        # Focus main, then drag the divider without stealing keyboard focus.
        os.write(host.master, b'\x1b[<0;25;2M\x1b[<0;25;2mfocus')
        host.until(lambda: b'focus' in (root / 'MAIN.input').read_bytes())
        # The sole divider resizes both adjacent base terminals.
        host.data.clear()
        drag(24, 12, 30, 12)
        host.until(lambda: b'[28, 22]' in sizes('DOCK') and b'[49, 22]' in sizes('MAIN'))
        host.until(lambda: b'\x1b[2;31H\x1b[0mMAIN01' in host.data)
        assert sizes('FLOAT').splitlines()[-1] == b'[34, 14]'
        os.write(host.master, b'kept')
        host.until(lambda: b'focuskept' in (root / 'MAIN.input').read_bytes())
        assert (root / 'DOCK.input').read_bytes() == b''
        host.process.terminate()
        host.finish(128 + signal.SIGTERM)
    finally:
        host.close()
print('Borders: hover, four anchored resize edges, event interception, and shared divider passed.')

# Adjacent border cells activate each corner; application cells remain available.
for x, y, dx, dy, symbol, origin in (
    (40, 7, -2, -1, '↖', b'\x1b[7;38H'),
    (65, 7, 2, -1, '↗', b'\x1b[7;40H'),
    (39, 17, -2, 1, '↙', b'\x1b[8;38H'),
    (65, 18, 2, 1, '↘', b'\x1b[8;40H'),
):
    with tempfile.TemporaryDirectory(prefix='tmuxpp-corner-', dir='/tmp') as directory:
        root = Path(directory)
        host = Host(command('MAIN'), sidebar=command('DOCK'), floating=command('FLOAT'))
        try:
            host.until(lambda: b'FLOAT01' in host.text())
            host.data.clear()
            os.write(host.master, f'\x1b[<35;{x};{y}M'.encode())
            host.until(lambda: symbol.encode() in host.data)
            host.data.clear()
            drag(x, y, x + dx, y + dy)
            host.until(lambda: b'[28, 11]' in sizes('FLOAT') and origin + b'\x1b[0mFLOAT01' in host.data)
            assert (root / 'FLOAT.input').read_bytes() == b''
            host.process.terminate()
            host.finish(128 + signal.SIGTERM)
        finally:
            host.close()
print('Corners: expanded border hit areas, hover arrows, and two-axis resizing passed.')

with tempfile.TemporaryDirectory(prefix='compo-aurora-', dir='/tmp') as directory:
    command = shlex.join([sys.executable, str(Path(__file__).with_name('float_child.py')), 'AURORA', directory])
    host = Host(command, desktop=True, border_style='aurora')
    try:
        host.until(lambda: b'Ctrl-]' in host.text())
        os.write(host.master, b'\x1d\r')
        host.until(lambda: b'AURORA01' in host.text())
        for corner in ('╭', '╮', '╰', '╯'):
            assert corner.encode() in host.data
        for rgb in (b'244;55;151', b'111;85;240', b'174;65;209', b'49;179;144'):
            assert b'\x1b[0;38;2;' + rgb + b'm' in host.data, rgb
        host.data.clear()
        # Hover reported as right-button motion without a captured press still
        # highlights the border, and must not start a resize.
        os.write(host.master, b'\x1b[<34;14;5M')
        host.until(lambda: '↖'.encode() in host.data)
        assert b'\x1b[0;38;2;247;115;182m' in host.data
        assert b'\x1b[2J' not in host.data
        os.write(host.master, b'\x1dq')
        host.finish(0)
    finally:
        host.close()
print('Aurora: four-corner RGB gradient, rounded floats, and brighter hover handles passed.')
