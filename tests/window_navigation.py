#!/usr/bin/env python3
"""Real pointer drags across dock bounds and keyboard reveal of an idle float."""
import json
import os
from pathlib import Path
import re
import select
import time
import shlex
import socket
import sys
import tempfile
from pty_host import Host

with tempfile.TemporaryDirectory(prefix='compo-navigation-', dir='/tmp') as directory:
    def command(label):
        return shlex.join([sys.executable, str(Path(__file__).with_name('float_child.py')), label, directory])
    host = Host(command('MAIN'), sidebar=command('DOCK'), floating=command('FLOAT'))
    connection = None
    try:
        host.until(lambda: b'FLOAT01' in host.text() and b'MAIN01' in host.text())
        path = re.search(rb'COMPO_SOCKET=([^\r\n]+)', host.data).group(1).decode()
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(5)
        connection.connect(path)
        replies = connection.makefile('rb')
        seq = 0
        def call(op, **fields):
            global seq
            seq += 1
            connection.sendall(json.dumps(dict(id=str(seq), op=op, **fields)).encode() + b'\n')
            # Drain the disposable display while awaiting a socket reply, just
            # as a real terminal consumes output. Otherwise a full PTY buffer
            # can block the host renderer before it handles the next request.
            deadline = time.monotonic() + 5
            while not select.select([connection], [], [], 0)[0]:
                host.read()
                assert time.monotonic() < deadline, 'control reply timeout'
            response = json.loads(replies.readline())
            assert 'result' in response, response
            return response['result']
        call('hello', version=1)
        windows = call('window.list')['windows']
        floating = next(w for w in windows if w['kind'] == 'floating')
        main = next(w for w in windows if w['kind'] == 'tiled')
        dock = next(w for w in windows if w['kind'] == 'docked')
        ref = floating['window']
        origin = floating['rect']
        def get(): return call('window.get', window=ref)['window']
        def reset():
            call('window.place', window=ref, placement=dict(kind='floating', rect=origin))
        # Hit all four screen corners without changing size or entering docking.
        # The left destinations cross the legacy dock reservation at column 24.
        for x, y, expected_x, expected_y in ((1, 1, 0, 0), (80, 1, 52, 0),
                                             (1, 24, 0, 12), (80, 24, 52, 12)):
            reset()
            os.write(host.master, f'\x1b[<24;40;8M\x1b[<56;{x};{y}M\x1b[<24;{x};{y}m'.encode())
            host.until(lambda: get()['rect']['x'] == expected_x and get()['rect']['y'] == expected_y)
            current = get()
            assert current['kind'] == 'floating' and current['rect']['w'] == origin['w']
            assert current['rect']['h'] == origin['h']
            assert (current['columns'], current['rows']) == (floating['columns'], floating['rows'])
            assert call('window.get', window=dock['window'])['window']['rect'] == dock['rect']
        reset()
        # Put an idle float beneath the tiled layout. Focus cycling must raise it
        # and emit its retained cells without waiting for new child output.
        call('window.lower', window=ref)
        call('window.focus', window=main['window'])
        host.until(lambda: b'MAIN01' in host.text())
        host.data.clear()
        os.write(host.master, b'\x1d\t')
        host.until(lambda: get()['focused'] and b'FLOAT01' in host.text())
        assert get()['order'] > call('window.get', window=main['window'])['window']['order']
        os.write(host.master, b'cycled')
        input_path = Path(directory) / 'FLOAT.input'
        host.until(lambda: input_path.exists() and input_path.read_bytes() == b'cycled')
        # Check the entire cycle, including a tile that was behind the float.
        for expected in (dock['window'], main['window'], ref):
            os.write(host.master, b'\x1d\t')
            host.until(lambda: call('window.get', window=expected)['window']['focused'])
        replies.close()
        connection.close(); connection = None
        host.process.terminate()
        host.finish(143)
    finally:
        if connection: connection.close()
        host.close()
print('Navigation: full-screen free drags and focus cycling reveal covered idle windows.')
