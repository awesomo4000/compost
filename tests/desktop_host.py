#!/usr/bin/env python3
"""Create, dock, undock and cancel without restarting the child process."""
import os
from pathlib import Path
import shlex
import sys
import tempfile
from pty_host import Host

with tempfile.TemporaryDirectory(prefix='tmuxpp-desktop-', dir='/tmp') as directory:
    root = Path(directory)
    command = shlex.join([sys.executable, str(Path(__file__).with_name('float_child.py')), 'SHELL', directory])
    host = Host(command, desktop=True)
    def sizes():
        p = root / 'SHELL.sizes'
        return p.read_bytes() if p.exists() else b''
    def inputs():
        p = root / 'SHELL.input'
        return p.read_bytes() if p.exists() else b''
    def send(data):
        os.write(host.master, data)
    try:
        host.until(lambda: b'\x1b[2J' in host.data)
        assert not sizes()
        send(b'\x1d\r')
        host.until(lambda: b'[51, 14]' in sizes())
        send(b'before')
        host.until(lambda: inputs() == b'before')
        # First dock occupies the left half. Preview is emitted before release.
        host.data.clear()
        send(b'\x1b[<8;20;8M\x1b[<40;1;12M')
        host.until(lambda: b'\x1b[48;2;20;28;33m' in host.data)
        host.until(lambda: b'SHELL01' in host.text())
        send(b'\x1b[<8;1;12m')
        host.until(lambda: b'[38, 22]' in sizes())
        send(b'after')
        host.until(lambda: inputs() == b'beforeafter')
        # Pull the tile out, then cancel and recover the original tiled size.
        host.data.clear()
        send(b'\x1b[<8;1;12M\x1b[<40;10;12M')
        host.until(lambda: sizes().splitlines()[-1] == b'[51, 14]')
        send(b'\x1b')
        host.until(lambda: sizes().splitlines()[-1] == b'[38, 22]')
        send(b'cancelled')
        host.until(lambda: inputs().endswith(b'cancelled'))
        # Closing the last child leaves a usable desktop; reuse its slot.
        host.data.clear()
        send(b'!')
        host.until(lambda: b'\x1b[2J' in host.data)
        assert host.process.poll() is None
        old = sizes()
        send(b'\x1d\r')
        host.until(lambda: len(sizes()) > len(old))
        send(b'\x1dq')
        host.finish(0)
    finally:
        host.close()
print('Desktop: blank launch, shell creation, docking preview, cancellation, slot reuse and quit passed.')

with tempfile.TemporaryDirectory(prefix='tmuxpp-docking-', dir='/tmp') as directory:
    root = Path(directory)
    command = 'exec ' + shlex.join([sys.executable, str(Path(__file__).with_name('float_child.py'))]) + ' "$$" ' + shlex.quote(directory)
    host = Host(command, desktop=True)
    def send(data):
        os.write(host.master, data)
    def labels():
        return {p.stem for p in root.glob('*.sizes')}
    def create():
        old = labels()
        send(b'\x1d\r')
        host.until(lambda: len(labels()) == len(old) + 1)
        return (labels() - old).pop()
    def sized(label, size):
        host.until(lambda: (root / (label + '.sizes')).read_text().splitlines()[-1] == str(size))
    def move(x, y, tx, ty, control=False):
        send(f'\x1b[<8;{x};{y}M\x1b[<{48 if control else 40};{tx};{ty}M\x1b[<8;{tx};{ty}m'.encode())
    try:
        host.until(lambda: b'\x1b[2J' in host.data)
        a = create()
        move(20, 8, 1, 12)
        sized(a, [38, 22])
        b = create()
        move(20, 8, 1, 12)
        sized(a, [39, 22])
        sized(b, [38, 22])
        # One shared divider changes both PTYs and preserves focus on the right.
        send(b'\x1b[<0;70;12M\x1b[<0;70;12m')
        send(b'\x1b[<0;40;12M\x1b[<32;27;12M\x1b[<0;27;12m')
        sized(b, [25, 22])
        sized(a, [52, 22])
        send(b'focused-right')
        host.until(lambda: (root / (a + '.input')).read_bytes() == b'focused-right')
        send(b'\x1b[<0;27;12M\x1b[<32;40;12M\x1b[<0;40;12m')
        sized(a, [39, 22])
        sized(b, [38, 22])
        c = create()
        move(20, 8, 51, 12)
        sized(c, [19, 22])
        sized(a, [19, 22])
        sized(b, [38, 22])
        # Undocking returns to the remembered floating dimensions.
        move(41, 12, 20, 12)
        sized(c, [51, 14])
        sized(a, [39, 22])
        # Dock over the top part of the right tile, then drag its shared row.
        move(30, 12, 61, 7)
        sized(c, [39, 10])
        sized(a, [39, 11])
        send(b'\x1b[<0;61;12M\x1b[<32;61;9M\x1b[<0;61;9m')
        sized(c, [39, 7])
        sized(a, [39, 14])
        sized(b, [38, 22])
        # Cancel another divider drag and restore the exact previous geometry.
        send(b'\x1b[<0;61;9M\x1b[<32;61;11M')
        sized(c, [39, 9])
        send(b'\x1b')
        sized(c, [39, 7])
        sized(a, [39, 14])
        move(61, 9, 20, 12)
        sized(c, [51, 14])
        # Every original process remains alive throughout the rearrangement.
        for pid in (a, b, c):
            os.kill(int(pid), 0)
        send(b'still-running')
        host.until(lambda: (root / (c + '.input')).read_bytes() == b'still-running')
        # A control-modified drop creates a reserved left wall.
        move(35, 12, 1, 12, control=True)
        sized(c, [24, 22])
        send(b'\x1dq')
        host.finish(0)
        for pid in (a, b, c):
            try:
                os.kill(int(pid), 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError('child survived compositor quit: ' + pid)
    finally:
        host.close()
print('Docking: nested splits, remembered float size, reserved wall, process identity and child cleanup passed.')
