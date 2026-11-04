#!/usr/bin/env python3
"""Tmux mouse copies reach OSC 52 without including the adjacent pane."""
import base64
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pty_host import Host

tmux = shutil.which('tmux')
if not tmux:
    raise SystemExit('tmux is required')
with tempfile.TemporaryDirectory(prefix='compo-tmux-copy-', dir='/tmp') as directory:
    socket = str(Path(directory, 'tmux.sock'))
    config = Path(directory, 'tmux.conf')
    config.write_text('set -g mouse on\nset -g default-shell /bin/sh\nset -s set-clipboard external\nset -as terminal-features ",xterm*:clipboard"\n')
    env = dict(os.environ)
    env.pop('TMUX', None)
    env.pop('TMUX_PANE', None)
    def run(*args):
        return subprocess.check_output([tmux, '-S', socket, *args], env=env, text=True).strip()
    def app(text):
        return shlex.join([sys.executable, '-c', "import os,tty; tty.setraw(0); os.write(1," + repr(b"\x1b[4;4H" + text.encode()) + "); exec('while True: os.read(0,4096)')"])
    host = None
    try:
        run('-f', str(config), 'new-session', '-d', '-s', 'copytest', '-x', '78', '-y', '22', app('LEFT_COPY'))
        left = run('display-message', '-p', '-t', 'copytest', '#{pane_id}')
        run('split-window', '-h', '-t', left, app('RIGHT_MUST_NOT_COPY'))
        run('select-pane', '-t', left)
        host = Host(shlex.join([tmux, '-S', socket, 'attach', '-t', 'copytest']))
        host.until(lambda: b'LEFT_COPY' in host.text() and b'RIGHT_MUST_NOT_COPY' in host.text())
        # The outer compo border offsets tmux by one cell in both directions.
        deadline = time.monotonic() + .5
        while time.monotonic() < deadline: host.read()
        for event in (b'\x1b[<0;5;5M', b'\x1b[<32;14;5M', b'\x1b[<0;14;5m'):
            os.write(host.master, event)
            deadline = time.monotonic() + .1
            while time.monotonic() < deadline: host.read()
        def copies():
            return [base64.b64decode(value) for value in re.findall(rb'\x1b\]52;c;([^\x1b]*)\x1b\\', host.data)]
        host.until(lambda: bool(copies()))
        assert copies()[-1].strip() == b'LEFT_COPY', copies()
        assert 'LEFT_COPY' == run('show-buffer').strip()
        assert b'RIGHT_MUST_NOT_COPY' not in copies()[-1]
        assert b'\x1b]52;c;?' not in host.data
        host.until(lambda: b'copied ]' in host.text())
        host.process.terminate()
        host.finish(143)
    finally:
        if host: host.close()
        subprocess.run([tmux, '-S', socket, 'kill-server'], env=env, capture_output=True)
print('Tmux clipboard: mouse release forwards the pane-local copy to the outer terminal.')
