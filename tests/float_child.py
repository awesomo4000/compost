"""Disposable raw terminal fixture recording input and PTY resize notifications."""
import json
import os
from pathlib import Path
import signal
import sys
import tty

tty.setraw(0)
label, directory = sys.argv[1:]
root = Path(directory)
def paint(*_):
    cols, rows = os.get_terminal_size(0)
    with (root / (label + '.sizes')).open('a') as f:
        f.write(json.dumps([cols, rows]) + '\n')
    output = ''.join(f'\x1b[{y};1H' + (label + f'{y:02d}').ljust(cols, '.')[:cols]
                     for y in range(1, rows + 1))
    os.write(1, output.encode() + b'\x1b[H')
signal.signal(signal.SIGWINCH, paint)
paint()
with (root / (label + '.input')).open('ab', buffering=0) as log:
    while True:
        data = os.read(0, 4096)
        if not data:
            break
        if data == b'!':
            break
        log.write(data)
