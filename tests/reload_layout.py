#!/usr/bin/env python3
"""Reload through the keyboard and socket, preserving windows on invalid edits."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from pty_host import BINARY, Host

with tempfile.TemporaryDirectory(prefix='compo-reload-', dir='/tmp') as directory:
    root = Path(directory)
    script = root / "layout 'quoted'.sh"
    def layout(name):
        return ('set -eu\n"$COMPO_BIN" ctl --quiet create --tile --focus --name ' + name + ' -- /bin/cat\n')
    script.write_text(layout('first'))
    host = Host('', desktop=True, args=['--init', os.path.relpath(script)])
    def ctl(*args, ok=True):
        process = subprocess.Popen([str(BINARY), 'ctl', '--socket', socket, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 10
        while process.poll() is None:
            host.read()
            if time.monotonic() > deadline:
                process.kill()
                raise AssertionError('control command timed out')
        stdout, stderr = process.communicate()
        assert (process.returncode == 0) == ok, (stdout, stderr)
        return json.loads(stdout)
    def idle(): host.until(lambda: ctl('startup')['result']['phase'] == 'idle')
    def windows(): return ctl('list')['result']['windows']
    def named(name):
        current = windows()
        return len(current) == 1 and current[0]['name'] == name
    try:
        host.until(lambda: b'COMPO_SOCKET=' in host.data)
        socket = re.search(rb'COMPO_SOCKET=([^\r\n]+)', host.data)[1].decode()
        idle()
        info = ctl('startup')['result']
        assert Path(info['script']).resolve() == script.resolve(), info
        assert Path(info['script']).is_absolute()
        assert Path(info['cwd']).resolve() == Path.cwd().resolve()
        first = windows()[0]['window']
        script.write_text(layout('second'))
        os.write(host.master, b'\x1dr')
        host.until(lambda: named('second'))
        idle()
        second = windows()[0]['window']
        assert second != first
        ctl('get', first, ok=False)
        # Syntax failure must not close or replace any live windows.
        script.write_text('if then\n')
        ctl('reload')
        idle()
        assert windows()[0]['window'] == second
        host.until(lambda: b'reload failed' in host.text())
        # Missing path also leaves the desktop intact.
        script.unlink()
        ctl('reload', ok=False)
        assert windows()[0]['window'] == second
        # A runtime failure leaves the compositor and any created windows usable.
        script.write_text(layout('partial') + 'exit 17\n')
        ctl('reload')
        idle()
        assert host.process.poll() is None
        assert windows()[0]['name'] == 'partial'
        # Busy calls cannot recursively reload an in-progress script.
        script.write_text(layout('third') + 'sleep 1\n')
        ctl('reload')
        host.until(lambda: named('third'))
        ctl('reload', ok=False)
        idle()
        assert windows()[0]['focused']
        # Empty scripts are valid: the desktop stays available for new windows.
        script.write_text(':\n')
        ctl('reload')
        idle()
        assert windows() == [] and host.process.poll() is None
        host.process.terminate()
        host.finish(143)
    finally: host.close()
    host = Host('exec /bin/cat')
    try:
        host.until(lambda: b'COMPO_SOCKET=' in host.data)
        socket = re.search(rb'COMPO_SOCKET=([^\r\n]+)', host.data)[1].decode()
        assert ctl('startup')['result']['script'] is None
        ctl('reload', ok=False)
        os.write(host.master, b'\x1dr')
        host.until(lambda: b'no startup script' in host.text())
        host.process.terminate()
        host.finish(143)
    finally: host.close()
print('Reload: keyboard, metadata, replacement, validation failures, busy, runtime recovery, and no-script notice passed.')
