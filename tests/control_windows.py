#!/usr/bin/env python3
"""Window API through a persistent socket and real PTYs in a disposable host."""
import json
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/compo'
with tempfile.TemporaryDirectory(prefix='compo-windows-', dir='/tmp') as directory:
    host = subprocess.Popen([str(binary), "--no-init"], env=dict(os.environ, COMPO_HEADLESS='80x24'),
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    peer = None
    pids = []
    try:
        assert select.select([host.stderr], [], [], 10)[0], 'no socket announcement'
        line = host.stderr.readline().decode().strip()
        assert line.startswith('COMPO_SOCKET='), line
        path = Path(line.split('=', 1)[1])
        peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        peer.settimeout(5)
        peer.connect(str(path))
        replies = peer.makefile('rb')
        sequence = 0
        def request(op, **fields):
            global sequence
            sequence += 1
            req = dict(id=str(sequence), op=op, **fields)
            peer.sendall(json.dumps(req).encode() + b'\n')
            answer = json.loads(replies.readline())
            assert answer['id'] == str(sequence), answer
            return answer
        def call(op, **fields):
            answer = request(op, **fields)
            assert 'result' in answer, answer
            return answer['result']
        hello = call('hello', version=1)
        assert hello['root'] == dict(x=0, y=0, w=80, h=24)
        assert call('window.list')['windows'] == []
        def placement(x=4, y=3, w=30, h=12, layer=0, fit='exact'):
            return dict(kind='floating', rect=dict(x=x, y=y, w=w, h=h), fit=fit, layer=layer)
        fixture = '''import os, sys, json, signal, termios
from pathlib import Path
p = Path(sys.argv[1])
def report(*_):
 p.write_text(json.dumps(dict(pid=os.getpid(), cwd=os.getcwd(), env=os.getenv('COMPO_TEST'), size=os.get_terminal_size(0))))
signal.signal(signal.SIGWINCH, report)
report()
while True: signal.pause()
'''
        def create(name, **kwargs):
            file = str(Path(directory) / name)
            result = call('window.create', name=name, argv=[sys.executable, '-c', fixture, file],
                          cwd=directory, env={'COMPO_TEST': 'yes'}, placement=kwargs.pop('placement', placement()), **kwargs)
            deadline = time.monotonic() + 5
            while not Path(file).exists():
                assert time.monotonic() < deadline
                time.sleep(.01)
            data = json.loads(Path(file).read_text())
            pids.append(data['pid'])
            assert data['cwd'] == os.path.realpath(directory)
            assert data['env'] == 'yes'
            assert data['size'] == [result['window']['columns'], result['window']['rows']]
            return result['window']
        first = create('one', focus=True)
        second = create('two', placement=placement(layer=-100))
        a, b = first['window'], second['window']
        assert a != b and a.startswith(hello['instance'] + '/')
        assert first['focused'] and not second['focused']
        assert call('window.get', window=a)['window']['focused']
        assert call('window.raise', window=b)['window']['layer'] == -100
        assert call('window.lower', window=a)['window']['layer'] == 0
        before = call('window.list')
        assert 'error' in request('window.place', window=a, placement=placement(x=75))
        assert call('window.list') == before
        assert 'error' in request('window.create', name='one', argv=['/bin/sh'], placement=placement())
        assert 'error' in request('window.create', argv=['/tmp/compo-nonexistent-executable'], placement=placement())
        assert 'error' in request('window.create', argv=['/bin/sh'], cwd='/tmp/compo-nonexistent-cwd', placement=placement())
        assert 'error' in request('window.create', argv=['/bin/sh'], placement=dict(placement(), opacity=.5))
        assert 'error' in request('window.focus', window=a, focus=False)
        assert call('window.list') == before
        moved = call('window.place', window=b, placement=placement(x=10, y=2, w=40, h=16, layer=10))['window']
        assert moved['rect'] == dict(x=10, y=2, w=40, h=16)
        assert moved['columns'] == 38 and moved['rows'] == 14
        constrained = call('window.place', window=b, placement=placement(x=75, fit='constrain'))['window']
        assert constrained['rect']['x'] == 50
        assert call('window.focus', window=b)['window']['focused']
        assert not call('window.get', window=a)['window']['focused']
        call('window.close', window=a)
        assert 'error' in request('window.get', window=a)
        assert 'error' in request('window.close', window=a)
        replacement = create('one')
        assert replacement['window'] != a
        call('window.close', window=b)
        call('window.close', window=replacement['window'])
        assert call('window.list')['windows'] == []
        assert call('ping')['pong']
        for pid in pids:
            try: os.kill(pid, 0)
            except ProcessLookupError: pass
            else: raise AssertionError(('child not reaped', pid))
        # A natural exit disappears without requiring a close command.
        exited = call('window.create', argv=['/bin/sh', '-c', 'exit 0'], placement=placement())['window']['window']
        deadline = time.monotonic() + 5
        while 'result' in request('window.get', window=exited):
            assert time.monotonic() < deadline
            time.sleep(.01)
        # Capacity failures do not evict windows, and all references remain unique.
        refs = [call('window.create', argv=['/bin/cat'], placement=placement())['window']['window'] for _ in range(32)]
        assert len(set(refs)) == 32
        before = call('window.list')
        assert len(before['windows']) == 32
        assert 'error' in request('window.create', argv=['/bin/cat'], placement=placement())
        assert call('window.list') == before
        for ref in refs: call('window.close', window=ref)
        assert call('window.list')['windows'] == []
        replies.close()
        peer.close(); peer = None
        host.terminate()
        stdout, stderr = host.communicate(timeout=5)
        assert stdout == b'', stdout
        assert not path.exists() and not path.parent.exists()
        print('control window lifecycle, placement, layers, references, and cleanup passed')
    finally:
        if peer: peer.close()
        if host.poll() is None:
            host.terminate()
            try: host.wait(timeout=5)
            except subprocess.TimeoutExpired: host.kill(); host.wait()
