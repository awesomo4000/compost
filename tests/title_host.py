#!/usr/bin/env python3
"""Startup art fades once, fits the terminal, and yields to shell creation."""
import os
import signal
import time
from pty_host import Host

host = Host('printf READY; exec /bin/cat', desktop=True, title=True)
def settle():
    end = time.monotonic() + 1
    while time.monotonic() < end: host.read()
try:
    settle()
    assert '▀'.encode() in host.data
    assert b'Ctrl-]' not in host.text(), 'startup must not show shortcut help'
    assert host.data.count(b'\x1b[?2026h') >= 5, 'missing fade frames'
    host.data.clear()
    settle()
    assert not host.data, 'settled title keeps redrawing'
    host.resize(4, 12)
    os.kill(host.process.pid, signal.SIGWINCH)
    host.until(lambda: b'compo' in host.text())
    assert '▀'.encode() not in host.data, 'small terminal should use wordmark'
    host.data.clear()
    host.resize(24, 80)
    os.kill(host.process.pid, signal.SIGWINCH)
    host.until(lambda: '▀'.encode() in host.data)
    settle()
    host.data.clear()
    os.write(host.master, b' ')
    settle()
    host.data.clear()
    os.write(host.master, b'\x1d\r')
    host.until(lambda: b'READY' in host.text())
    assert '▀'.encode() not in host.data, 'title remained over new window'
    os.write(host.master, b'\x1dq')
    host.finish(0)
finally:
    host.close()
print('Title: fade, idle stability, no startup help, resize fallback, and shell transition passed.')

# Scripted children keep running behind the modal; the dismissal click must not
# reach their mouse handler, including its release after the fade has completed.
import tempfile
from pathlib import Path
import shlex
import sys
with tempfile.TemporaryDirectory(prefix='compo-title-', dir='/tmp') as directory:
    root = Path(directory)
    fixture = root / 'child.py'
    fixture.write_text('''import os, tty
from pathlib import Path
tty.setraw(0)
Path(__file__).with_suffix('.ready').touch()
os.write(1, b'\\x1b[?1003h\\x1b[?1006h\\x1b[10;20HUNDERLAY')
while True:
 data = os.read(0,4096)
 with open(Path(__file__).with_suffix('.input'), 'ab') as f: f.write(data)
''')
    script = root / 'init.sh'
    script.write_text('"$COMPO_BIN" ctl --quiet create --tile --focus --name test -- ' + shlex.join([sys.executable, str(fixture)]) + '\n')
    for gesture in ('click', 'key', 'paste'):
        fixture.with_suffix('.ready').unlink(missing_ok=True)
        fixture.with_suffix('.input').unlink(missing_ok=True)
        host = Host('', desktop=True, title=True, args=['--init', str(script)])
        try:
            host.until(lambda: fixture.with_suffix('.ready').exists())
            settle()
            assert b'UNDERLAY' not in host.text(), 'child text leaked through modal'
            host.data.clear()
            if gesture == 'click':
                os.write(host.master, b'\x1b[<0;20;10M')
                settle()
                os.write(host.master, b'\x1b[<0;20;10m')
            elif gesture == 'paste':
                os.write(host.master, b'\x1b[200~secret-start')
                settle()
                os.write(host.master, b'secret-end\x1b[201~')
            else:
                os.write(host.master, b'dismiss-key')
            settle()
            assert not fixture.with_suffix('.input').exists(), 'dismissal reached child'
            assert b'UNDERLAY' in host.text(), 'underlying terminal did not restore'
            assert host.data.count(b'\x1b[?2026h') >= 3, 'missing dismissal animation'
            os.write(host.master, b'z')
            host.until(lambda: fixture.with_suffix('.input').exists())
            assert fixture.with_suffix('.input').read_bytes() == b'z'
            if gesture == 'key':
                host.data.clear()
                os.write(host.master, b'\x1dr')
                host.until(lambda: '▀'.encode() in host.data)
                settle()
                assert host.data.count(b'\x1b[?2026h') >= 5, 'reload did not replay entrance'
                host.data.clear()
                os.write(host.master, b' ')
                settle()
                assert b'UNDERLAY' in host.text(), 'reload modal did not dismiss'
            host.process.terminate()
            host.finish(143)
        finally:
            host.close()
print('Title modal: scripted child runs, occlusion restores, click/key/paste consumed, and input resumes.')
