"""Small raw-mode terminal application for disposable PTY integration tests."""
import os
import sys
import tty

tty.setraw(0)
label, path, pixel = sys.argv[1:]
os.write(1, ("\x1b[?1002h\x1b[?1006h\x1b[?2004h"
             "\x1b_Ga=T,f=24,s=1,v=1,i=42;" + pixel + "\x1b\\" + label).encode())
with open(path, "ab", buffering=0) as log:
    while True:
        data = os.read(0, 4096)
        if not data:
            break
        log.write(data)
