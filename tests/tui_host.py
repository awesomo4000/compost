#!/usr/bin/env python3
"""Full-screen throughput and real Vim editing in disposable PTYs."""
import json
import os
from pathlib import Path
import shlex
import signal
import tempfile
import time
from pty_host import Host

# Acknowledging each frame prevents coalescing from hiding missing updates.
child = '''import os, tty
tty.setraw(0)
for frame in range(40):
    rows = [f'\\x1b[{r};1H\\x1b[38;5;{r%7+1}m'+chr(65+frame%26)*160 for r in range(1,50)]
    os.write(1, (''.join(rows)+f'\\x1b[50;1HFRAME{frame:04d}').encode())
    os.read(0,1)
'''
# Set geometry before the child begins generating full-screen frames.
host = Host('read start; exec python3 -c ' + shlex.quote(child))
try:
    host.until(lambda: b'\x1b[?1004h' in host.data)
    host.resize(50, 160)
    host.process.send_signal(signal.SIGWINCH)
    host.until(lambda: b'\x1b[50;1H' in host.data)
    os.write(host.master, b'go\r')
    durations = []
    sizes = []
    for frame in range(40):
        start = time.monotonic()
        host.until(lambda: f'FRAME{frame:04d}'.encode() in host.text())
        durations.append(time.monotonic() - start)
        sizes.append(len(host.data))
        host.data.clear()
        os.write(host.master, b'x')
    host.finish(0)
    # Deterministic byte budget; timing is reported, not a machine-speed assertion.
    assert max(sizes[1:]) < 16000, sizes
    print(json.dumps({'frames': 40, 'mean_redraw_ms': sum(durations[1:]) / 39 * 1000,
                      'max_redraw_bytes': max(sizes[1:])}))
finally:
    host.close()

with tempfile.TemporaryDirectory(prefix='tmuxpp-vim-', dir='/tmp') as directory:
    file = Path(directory) / 'edit.txt'
    file.write_text(''.join(f'line {i:04d}\n' for i in range(200)))
    host = Host('exec /usr/bin/vi -u NONE -i NONE -n ' + shlex.quote(str(file)),
                sidebar="printf 'SIDEBAR\\n'; read value")
    try:
        host.until(lambda: b'line 0000' in host.text() or b'Press ENTER' in host.text())
        if b'Press ENTER' in host.text():
            os.write(host.master, b'\r')
            host.until(lambda: b'line 0000' in host.text())
        start = time.monotonic()
        os.write(host.master, b'Gofast edit\x1b')
        host.until(lambda: b'fast edit' in host.text())
        elapsed = time.monotonic() - start
        os.write(host.master, b':wq\r')
        host.until(lambda: 'fast edit' in file.read_text())
        assert file.read_text().endswith('fast edit\n')
        host.process.terminate()
        host.finish(128 + signal.SIGTERM)
        print(f'Vim: scroll, insert, Escape, and save passed; edit visible in {elapsed * 1000:.1f} ms')
    finally:
        host.close()
