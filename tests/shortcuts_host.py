#!/usr/bin/env python3
"""Number allocation, keyboard focus, modal isolation and configured-prefix help."""
import json
import os
import re
import socket
import select
import time
from pty_host import Host

host = Host("/bin/cat", desktop=True, env_overrides={"COMPO_PREFIX": "ctrl-g"})
try:
    host.until(lambda: b"COMPO_SOCKET=" in host.data and b"\x1b[2J" in host.data)
    path = re.search(rb"COMPO_SOCKET=([^\r\n]+)", host.data).group(1).decode()
    with socket.socket(socket.AF_UNIX) as peer:
        peer.settimeout(5)
        peer.connect(path)
        stream = peer.makefile('rb')
        seq = 0
        def request(op, **fields):
            global seq
            seq += 1
            peer.sendall(json.dumps(dict(id=str(seq), op=op, **fields)).encode() + b'\n')
            deadline = time.monotonic() + 10
            while not select.select([peer], [], [], .01)[0]:
                host.read()
                assert time.monotonic() < deadline, 'control request timed out'
            return json.loads(stream.readline())
        def call(op, **fields):
            reply = request(op, **fields)
            assert 'result' in reply, reply
            return reply['result']
        call('hello', version=1)
        def create(name, **fields):
            return call('window.create', name=name, argv=['/bin/cat'],
                        placement=dict(kind='floating', rect=dict(x=1, y=2, w=70, h=20)), **fields)['window']
        one = create('one', focus=True)
        ten = create('ten', number=10)
        two = create('two')
        assert (one['number'], ten['number'], two['number']) == (1, 10, 2)
        before = call('window.list')
        for fields in (dict(name='duplicate', number=10), dict(name='one'), dict(number=0), dict(number=11)):
            reply = request('window.create', argv=['/bin/cat'], placement=dict(kind='floating', rect=dict(x=1, y=2, w=20, h=10)), **fields)
            assert 'error' in reply, reply
        assert call('window.list') == before
        def key(data):
            os.write(host.master, data)
            deadline = time.monotonic() + .2
            while time.monotonic() < deadline: host.read()
        key(b'\x070')
        focused = call('window.get', window='ten')['window']
        assert focused['focused']
        assert focused['order'] > call('window.get', window='two')['window']['order']
        key(b'\x071')
        assert call('window.get', window='one')['window']['focused']
        call('window.close', window='two')
        assert create('replacement')['number'] == 2
        key(b'\x071')
        key(b'\x07n')
        assert b'[1] one' in host.text(), host.text()[-500:]
        start = len(host.data)
        key(b'\x07/')
        assert b'Ctrl-g / or ?: toggle help' in host.text(), host.text()[-1500:]
        key(b'SHOULD_NOT_REACH_CAT')
        assert b'SHOULD_NOT_REACH_CAT' not in host.data[start:]
        key(b'\x07?')
        key(b'AFTER_MODAL\n')
        host.until(lambda: b'AFTER_MODAL' in host.text())
        key(b'\x07?')
        # Outside click and its release must not reach the underlying cat.
        key(b'\x1b[<0;1;24M\x1b[<0;1;24m')
        key(b'\x07/')
        key(b'\x1b')
        key(b'\x073')
        assert b'No window 3' in host.text()
        for n in range(3, 10):
            assert create('extra' + str(n))['number'] == n
        assert create('overflow')['number'] is None
        call('window.close', window='extra3')
        assert create('reuse')['number'] == 3
        key(b'\x07?')
        host.resize(4, 12)
        key(b'\x1b')
        key(b'\x07q')
        host.finish(0)
finally:
    host.close()
print('Shortcuts: stable numbers, duplicate rejection, focus/raise, labels, modal isolation and small resize passed.')
