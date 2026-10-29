#!/usr/bin/env python3
"""Startup scripts build named layouts with no bootstrap pane or JSON parsing."""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import time

from pty_host import BINARY, Host


def until(predicate, host=None):
    deadline = time.monotonic() + 10
    while not predicate():
        if host is not None:
            host.read()
        else:
            time.sleep(.01)
        assert time.monotonic() < deadline, "startup timed out"


with tempfile.TemporaryDirectory(prefix="compo-startup-layout-", dir="/tmp") as directory:
    root = Path(directory)
    ready = root / "ready"
    script = root / "layout with 'quotes'.sh"
    script.write_text('''set -eu
ctl() { "$COMPO_BIN" ctl --quiet "$@"; }
ctl create --tile --name main -- /bin/cat
ctl create --tile --name sidebar --target main --edge left --ratio 2500 -- /bin/cat
ctl create --float 10,4,30,12 --name scratch -- /bin/cat
ctl place scratch --tile --target main --edge bottom --ratio 2500
ctl focus main
printf ready > "$READY"
''')
    env = dict(os.environ, COMPO_HEADLESS="120x40", READY=str(ready))
    env.pop("COMPO_INIT", None)
    host = subprocess.Popen([str(BINARY), "--init", str(script)], env=env,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        assert select.select([host.stderr], [], [], 10)[0]
        line = host.stderr.readline().decode().strip()
        assert line.startswith("COMPO_SOCKET="), line
        env["COMPO_SOCKET"] = line.split("=", 1)[1]
        until(ready.exists)
        assert host.poll() is None, "successful script should leave compositor running"
        def ctl(*args, ok=True):
            result = subprocess.run([str(BINARY), "ctl", *args], env=env, capture_output=True, text=True, timeout=10)
            assert (result.returncode == 0) == ok, (result.stdout, result.stderr)
            return json.loads(result.stdout) if result.stdout else None
        windows = ctl("list")["result"]["windows"]
        assert len(windows) == 3, "startup should not need a bootstrap shell"
        by_name = {w["name"]: w for w in windows}
        assert by_name["main"]["rect"] == dict(x=30, y=0, w=90, h=30)
        assert by_name["sidebar"]["rect"] == dict(x=0, y=0, w=30, h=40)
        assert by_name["scratch"]["rect"] == dict(x=30, y=30, w=90, h=10)
        assert by_name["main"]["focused"]
        assert ctl("get", "name:main")["result"]["window"]["window"] == by_name["main"]["window"]
        assert ctl("--quiet", "focus", "sidebar") is None
        assert "error" in ctl("--quiet", "focus", "missing", ok=False)
        ctl("create", "--tile", "--edge", "right", "--name", "main", ok=False)
        old_ref = by_name["scratch"]["window"]
        assert ctl("close", "scratch")["result"]["removed"] == old_ref
        replacement = ctl("create", "--float", "5,5,30,12", "--name", "scratch", "--", "/bin/cat")["result"]["window"]
        assert replacement["window"] != old_ref
        ctl("get", old_ref, ok=False)
        assert ctl("get", "scratch")["result"]["window"]["window"] == replacement["window"]
        special = ctl("create", "--float", "5,5,30,12", "--name", "a/b", "--", "/bin/cat")["result"]["window"]
        assert ctl("get", "name:a/b")["result"]["window"]["window"] == special["window"]
        ctl("get", "a/b", ok=False)  # An invalid reference never falls back to a name.
    finally:
        host.terminate()
        host.communicate(timeout=10)
    assert not Path(env["COMPO_SOCKET"]).exists()

    # Environment selection works without CLI args; explicit and disabled
    # startup options take precedence over inherited configuration.
    for arguments, init_env in (([], str(script)), (["--init", str(script)], str(root / "missing-env-script"))):
        ready.unlink()
        process = subprocess.Popen([str(BINARY), *arguments], env=dict(env, COMPO_INIT=init_env),
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            until(ready.exists)
            assert process.poll() is None
        finally:
            process.terminate()
            process.communicate(timeout=10)

    # A failing script stops startup, surfaces its bounded diagnostics, and
    # closes its compositor. Large output must not deadlock the event loop.
    failure = root / "failure.sh"
    failure.write_text('''set -eu
"$COMPO_BIN" ctl --quiet create --tile --name partial -- /bin/cat
i=0; while [ "$i" -lt 2000 ]; do printf 'startup-output-abcdefghijklmnopqrstuvwxyz0123456789\\n'; i=$((i+1)); done
exit 17
''')
    result = subprocess.run([str(BINARY), "--init", str(failure)], env=env,
                            stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
    assert result.returncode == 17, result.stderr
    assert b"startup script exited with status 17" in result.stderr
    assert len(result.stderr) < 17500, len(result.stderr)
    socket_path = result.stderr.split(b"\n", 1)[0].decode().split("=", 1)[1]
    assert not Path(socket_path).exists()
    missing = subprocess.run([str(BINARY), "--init", str(root / "missing")], env=env,
                             capture_output=True, timeout=5)
    assert missing.returncode != 0 and b"COMPO_SOCKET=" not in missing.stderr

    # Auto discovery and --no-init use an isolated config directory in a real PTY.
    config = root / "config"
    (config / "compo").mkdir(parents=True)
    (config / "compo" / "init.sh").write_text(script.read_text())
    ready.unlink()
    overrides = dict(XDG_CONFIG_HOME=str(config), READY=str(ready))
    display = Host("sleep 60", desktop=True, args=[], env_overrides=overrides)
    try:
        until(ready.exists, display)
        os.write(display.master, b"\x1dq")
        display.finish(0)
    finally:
        display.close()
    ready.unlink()
    display = Host("sleep 60", desktop=True, args=["--no-init"],
                   env_overrides=dict(overrides, COMPO_INIT=str(root / "missing-env-script")))
    try:
        display.until(lambda: b"Ctrl-]" in display.text())
        assert not ready.exists()
        os.write(display.master, b"\x1dq")
        display.finish(0)
    finally:
        display.close()

    # Closing compo terminates a startup script still running outside its panes.
    pidfile = root / "pid"
    waiting = root / "waiting.sh"
    waiting.write_text(f"echo $$ > '{pidfile}'\nexec sleep 60\n")
    running = subprocess.Popen([str(BINARY), "--init", str(waiting)], env=env,
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        until(pidfile.exists)
        pid = int(pidfile.read_text())
    finally:
        running.terminate()
        running.communicate(timeout=5)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError("startup process survived compositor shutdown")

print("Startup layouts: named targeting, quiet CLI, auto/explicit/disabled scripts, bounded failures, and cleanup passed.")
