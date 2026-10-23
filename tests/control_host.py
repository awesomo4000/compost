#!/usr/bin/env python3
"""Exercise one persistent control connection beside a real interactive PTY."""
import json
import os
from pathlib import Path
import shlex
import socket
import stat
import sys
import tempfile
from pty_host import Host

child = r'''
import os, sys, stat, tty
from pathlib import Path
tty.setraw(0)
Path(sys.argv[1]).write_text(os.environ['COMPO_SOCKET'])
for fd in range(3, 128):
    try: mode = os.fstat(fd).st_mode
    except OSError: continue
    assert not stat.S_ISSOCK(mode), ('inherited control socket', fd)
os.write(1, b'CONTROL_READY')
while True:
    data = os.read(0, 4096)
    if b'!' in data: break
    os.write(1, data)
'''
class Wire:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(5)
        self.socket.connect(str(path))
        self.file = self.socket.makefile('rb')
    def send(self, request):
        self.socket.sendall(json.dumps(request).encode() + b'\n')
    def read(self):
        line = self.file.readline()
        assert line, 'unexpected control disconnect'
        return json.loads(line)
    def hello(self):
        self.send(dict(id='hello', op='hello', version=1))
        return self.read()['result']
    def close(self):
        self.file.close()
        self.socket.close()

with tempfile.TemporaryDirectory(prefix='compo-control-test-', dir='/tmp') as directory:
    discovery = Path(directory) / 'socket-path'
    host = Host(shlex.join([sys.executable, '-c', child, str(discovery)]))
    clients = []
    try:
        host.until(lambda: b'CONTROL_READY' in host.text())
        path = Path(discovery.read_text())
        assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
        assert path.stat().st_uid == os.getuid()
        wire = Wire(path); clients.append(wire)
        wire.send(dict(id='early', op='ping'))
        assert wire.read()['error']['code'] == 'handshake_required'
        wire.send(dict(id='version', op='hello', version=99))
        assert wire.read()['error']['code'] == 'unsupported_version'
        # Fragmented JSON and UTF-8 must survive arbitrary socket read boundaries.
        request = json.dumps(dict(id='héllo"\n', op='hello', version=1), ensure_ascii=False).encode() + b'\n'
        for byte in request: wire.socket.sendall(bytes([byte]))
        hello = wire.read()
        assert hello['id'] == 'héllo"\n'
        instance = hello['result']['instance']
        assert len(instance) == 32
        assert hello['result']['root'] == dict(x=0, y=0, w=80, h=24)
        assert 'window.create' in hello['result']['operations']
        wire.socket.sendall(b'{oops}\n' + json.dumps(dict(id='unknown', op='nonexistent')).encode() + b'\n')
        assert wire.read()['error']['code'] == 'invalid_json'
        assert wire.read()['error']['code'] == 'unknown_operation'
        wire.send(dict(id='field', op='ping', typo=1))
        assert wire.read()['error']['code'] == 'invalid_request'
        for batch in range(100):
            ids = [str(batch * 32 + i) for i in range(32)]
            wire.socket.sendall(b''.join(json.dumps(dict(id=i, op='ping')).encode() + b'\n' for i in ids))
            assert [wire.read() for _ in ids] == [dict(id=i, result=dict(pong=True)) for i in ids]
        # Independent clients share the instance identity, not handshake state.
        other = Wire(path); clients.append(other)
        assert other.hello()['instance'] == instance
        # An invalid peer is isolated; neither it nor a slow reader stops the PTY.
        for payload in (b'x' * (65536 + 1), b'{"id":"dup","op":"ping"}\n' * 2,
                        b''.join(json.dumps(dict(id=str(i), op='ping')).encode() + b'\n' for i in range(500))):
            bad = Wire(path)
            bad.hello()
            try:
                bad.socket.sendall(payload)
                while bad.socket.recv(65536): pass
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally: bad.close()
            wire.send(dict(id='alive', op='ping'))
            assert wire.read()['result']['pong']
        # Repeated connect/close must release slots and descriptors.
        for _ in range(50):
            transient = Wire(path)
            assert transient.hello()['instance'] == instance
            transient.close()
        os.write(host.master, b'interactive-still-works')
        host.until(lambda: b'interactive-still-works' in host.text())
        os.write(host.master, b'!')
        host.finish(0)
        assert not path.exists() and not path.parent.exists()
    finally:
        for client in clients: client.close()
        host.close()
print('Control: persistent 3200-request session, framing, versions, limits, client isolation, permissions, PTY responsiveness and cleanup passed.')
