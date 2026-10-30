#!/usr/bin/env python3
"""Exercise native CLI, tiled layout, PTY resize, and command handoff."""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time

BINARY = Path(__file__).resolve().parents[1] / "zig-out/bin/compo"


def wait_for(predicate):
    deadline = time.monotonic() + 5
    while not predicate():
        assert time.monotonic() < deadline, "timed out waiting for child report"
        time.sleep(.01)


with tempfile.TemporaryDirectory(prefix="compo-ctl-", dir="/tmp") as directory:
    env = dict(os.environ, COMPO_HEADLESS="120x40", SHELL="/bin/bash", HOME=directory)
    # Explicit readiness reports from a disposable rc file, never prompt matching.
    Path(directory, ".bashrc").write_text(
        "printf '%s\\n' \"$PWD\" \"$COMPO_TEST\" \"$-\" > \"$HOME/shell-ready\"\n"
    )
    host = subprocess.Popen([str(BINARY), "--no-init"], env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    stream = None
    try:
        assert select.select([host.stderr], [], [], 10)[0]
        announcement = host.stderr.readline().decode().strip()
        assert announcement.startswith("COMPO_SOCKET="), announcement
        env["COMPO_SOCKET"] = announcement.split("=", 1)[1]

        def cli(*args, ok=True):
            result = subprocess.run([str(BINARY), "ctl", *args], env=env,
                                    capture_output=True, text=True, timeout=10)
            assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
            return json.loads(result.stdout) if result.stdout else None

        assert cli("list")["result"]["windows"] == []
        report = Path(directory, "size.json")
        fixture = """import os, signal, json, sys
from pathlib import Path
def report(*_):
 p = Path(sys.argv[1]); tmp = p.with_suffix('.tmp')
 tmp.write_text(json.dumps(list(os.get_terminal_size(0)))); tmp.replace(p)
signal.signal(signal.SIGWINCH, report)
report()
while True: signal.pause()
"""
        a = cli("create", "--tile", "--name", "main", "--focus", "--",
                sys.executable, "-c", fixture, str(report))["result"]["window"]
        aid = a["window"]
        assert a["rect"] == dict(x=0, y=0, w=120, h=40) and a["focused"]
        wait_for(lambda: report.exists())
        assert json.loads(report.read_text()) == [a["columns"], a["rows"]]
        b = cli("create", "--tile", "--target", aid, "--edge", "left", "--ratio", "2500",
                "--", "/bin/cat")["result"]["window"]
        bid = b["window"]
        assert b["rect"] == dict(x=0, y=0, w=30, h=40)
        a = cli("get", aid)["result"]["window"]
        assert a["rect"] == dict(x=30, y=0, w=90, h=40) and a["focused"]
        wait_for(lambda: json.loads(report.read_text()) == [a["columns"], a["rows"]])
        c = cli("create", "--tile", "--target", aid, "--edge", "bottom", "--ratio", "2500",
                "--", "/bin/cat")["result"]["window"]
        cid = c["window"]
        assert c["rect"] == dict(x=30, y=30, w=90, h=10)
        assert cli("get", bid)["result"]["window"]["rect"] == b["rect"]
        # Rejected splits and failed launches must preserve the entire layout.
        before = cli("list")["result"]
        for args in (
            ("--target", aid, "--edge", "right", "--ratio", "9999"),
            ("--target", aid, "--edge", "right", "--ratio", "0"),
            ("--target", "stale/1", "--edge", "right"),
            ("--layer", "-1", "--edge", "left"),
            (),
        ):
            cli("create", "--tile", *args, "--", "/bin/cat", ok=False)
            assert cli("list")["result"] == before
        cli("create", "--tile", "--target", aid, "--edge", "right", "--",
            "/tmp/compo-no-such-program", ok=False)
        assert cli("list")["result"] == before
        a = cli("get", aid)["result"]["window"]
        wait_for(lambda: json.loads(report.read_text()) == [a["columns"], a["rows"]])
        # Tile-to-float restores the neighbor; float-to-tile preserves the ID.
        moved = cli("place", cid, "--float", "5,6,40,12", "--layer", "3")["result"]["window"]
        assert moved["window"] == cid and moved["layer"] == 3
        assert moved["rect"] == dict(x=5, y=6, w=40, h=12)
        moved = cli("place", cid, "--tile", "--target", bid, "--edge", "top", "--ratio", "5000")["result"]["window"]
        assert moved["rect"] == dict(x=0, y=0, w=30, h=20) and moved["layer"] == 0
        cli("place", cid, "--tile", "--target", cid, "--edge", "left", ok=False)
        cli("focus", cid)
        assert cli("get", cid)["result"]["window"]["focused"]
        # Each command window runs its own command, then enters the real shell.
        command = "export COMPO_TEST='quotes \" and spaces'; false # trailing comment"
        d = cli("create", "--float", "50,10,40,15", "--cwd", directory,
                "--shell", "/bin/bash", "--command", command)["result"]["window"]
        ready = Path(directory, "shell-ready")
        wait_for(lambda: ready.exists() and len(ready.read_text().splitlines()) == 3)
        cwd, value, flags = ready.read_text().splitlines()
        assert cwd == os.path.realpath(directory) and value == 'quotes " and spaces' and "i" in flags
        cli("get", d["window"])
        ready.unlink()
        plain = cli("create", "--float", "2,2,30,12")["result"]["window"]
        wait_for(lambda: ready.exists())
        assert plain["command"] == "/bin/bash"
        cli("create", "--float", "2,2,30,12", "--command", "true", "--", "/bin/cat", ok=False)
        whole = cli("create", "--tile", "--edge", "right", "--ratio", "3333",
                    "--", "/bin/cat")["result"]["window"]
        assert whole["rect"] == dict(x=80, y=0, w=40, h=40)
        # One client process/connection remains available between requests.
        stream = subprocess.Popen([str(BINARY), "ctl", "stream"], env=env,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        for n in range(20):
            stream.stdin.write(json.dumps(dict(id=str(n), op="ping")).encode() + b"\n")
            stream.stdin.flush()
            assert select.select([stream.stdout], [], [], 10)[0]
            assert json.loads(stream.stdout.readline()) == dict(id=str(n), result=dict(pong=True))
            assert stream.poll() is None
        stream.stdin.close()
        assert stream.wait(timeout=5) == 0
        cli("--socket", env["COMPO_SOCKET"], "list")
        for window in cli("list")["result"]["windows"]:
            cli("close", window["window"])
        assert cli("list")["result"]["windows"] == []
        cli("get", aid, ok=False)
        only = cli("create", "--tile", "--number", "10", "--", "/bin/cat")["result"]["window"]
        assert only["number"] == 10
        cli("create", "--tile", "--number", "10", "--", "/bin/cat", ok=False)
        only = cli("place", only["window"], "--tile", "--edge", "left")["result"]["window"]
        assert only["rect"] == dict(x=0, y=0, w=120, h=40)
        cli("close", only["window"])
    finally:
        if stream is not None and stream.poll() is None:
            stream.terminate()
            stream.wait(timeout=5)
        host.send_signal(signal.SIGTERM)
        host.wait(timeout=5)

print("Control CLI: placements, ratios, neighbor PTY resize, rollback, shell handoff, persistent stream, and lifecycle passed.")
