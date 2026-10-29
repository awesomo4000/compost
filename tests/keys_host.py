#!/usr/bin/env python3
"""Key sequence framing survives fragmented reads and held-arrow repeats."""
import os
from pathlib import Path
import shlex
import signal
import sys
import tempfile
import time
from pty_host import Host

fixture = r'''
import os,sys,tty
tty.setraw(0)
os.write(1,b'\x1b[?1hKEYS_READY')
with open(sys.argv[1],'ab',buffering=0) as log:
 while True: log.write(os.read(0,4096))
'''
with tempfile.TemporaryDirectory(prefix="compo-keys-", dir="/tmp") as directory:
    path = Path(directory, "keys")
    host = Host(shlex.join([sys.executable, "-c", fixture, str(path)]))
    def data():
        return path.read_bytes() if path.exists() else b""
    try:
        host.until(lambda: b"KEYS_READY" in host.text() and b"\x1b[?1h" in host.data)
        expected = b""
        for prefix, final in ((b"\x1bO", b"D"), (b"\x1b[", b"A"), (b"\x1b[1;", b"5D")):
            os.write(host.master, prefix)
            # Deliberately exceed the former 50ms incomplete-sequence timeout.
            deadline = time.monotonic() + .2
            while time.monotonic() < deadline:
                host.read()
            assert data() == expected, ("partial key escaped", data())
            os.write(host.master, final)
            expected += prefix + final
            host.until(lambda: data() == expected)
        repeated = (b"\x1bOD\x1bOC\x1bOA\x1bOB\x1b[D\x1b[1;5D") * 200
        # Vary the read boundaries independently of key boundaries.
        for offset in range(0, len(repeated), 7):
            os.write(host.master, repeated[offset:offset + 7])
        expected += repeated
        host.until(lambda: data() == expected)
        os.write(host.master, b"\x1b")
        expected += b"\x1b"
        host.until(lambda: data() == expected)
        host.process.terminate()
        host.finish(128 + signal.SIGTERM)
    finally:
        host.close()
print("Keys: delayed SS3/CSI fragments, 1200 repeated keys, and standalone Escape passed.")
