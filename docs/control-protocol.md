# Local control socket

Compo creates a private `/tmp/compo-XXXXXX/control.sock` on startup. It prints
`COMPO_SOCKET=...` before entering the alternate screen and exports that variable
in child shells. The directory is mode 0700 and the socket is mode 0600. Each
launch uses a random 128-bit instance ID. Normal exit removes the socket and its
private directory; a SIGKILL can leave them behind. Startup never reuses an old
socket path or deletes another instance's directory.

This implements transport and window lifecycle from the
[control spec](../specs/00-control-proto.md). Supported operations are `hello`,
`ping`, `window.list`, `window.get`, `window.create`, `window.place`,
`window.focus`, `window.raise`, `window.lower`, and `window.close`.
Screen snapshots, injected input, and subscriptions remain subsequent stages.

## Command-line client

Run `compo ctl` inside a compo shell to use its inherited `COMPO_SOCKET`, or supply
`compo ctl --socket /tmp/compo-XXXXXX/control.sock ...` from outside. Every command
prints a JSON response. A server error produces a nonzero exit status.

```sh
# First tile fills the workspace; this opens an ordinary interactive shell.
compo ctl create --tile --name main --focus

# Discover windows. Names can be used directly by subsequent commands.
compo ctl list

# Give a sidebar one quarter of a specific tile's width.
compo ctl create --tile --target main --edge left --ratio 2500 \
  --name sidebar --command 'tmm'

# Run a command in a float, leaving a shell when the command finishes.
compo ctl create --float 10,4,60,20 --cwd /absolute/project \
  --shell /bin/bash --command 'your_program' --focus

# Move that same running window into the bottom half of another tile.
compo ctl place INSTANCE/FLOAT_ID --tile --target INSTANCE/ID --edge bottom
compo ctl place INSTANCE/FLOAT_ID --float 12,5,50,18 --layer 10
compo ctl focus INSTANCE/FLOAT_ID
compo ctl close INSTANCE/FLOAT_ID
```

`get`, `raise`, and `lower` also take a window reference. `--float X,Y,W,H` uses
outer cell bounds, including borders. `--constrain` permits clamping to the screen.
`--ratio` is the new tile's share in basis points, so 2500 means 25% and 3333 is
approximately one third. Omitting `--target` splits the whole tiled area on the
chosen edge. Later tiles require `--edge`; the first tile fills the workspace.
Window and target arguments accept unique live names as well as exact references.
Use `name:NAME` to explicitly address a name, including one containing `/`.
Unprefixed arguments containing `/` are always treated as references, so stale
references never fall back to names. A name resolves to its current live window;
if you close and recreate that name, it refers to the replacement. Use exact
references when identity must survive retries without retargeting. `ctl --quiet`
suppresses successful replies while preserving errors and nonzero exit statuses.

`create` defaults to an interactive shell. `--command TEXT` executes TEXT in a
noninteractive shell, then replaces that shell with an interactive instance of
the same shell. A normal nonzero command status still reaches the shell. An
explicit `exit` or `exec` in TEXT retains its normal meaning. Interactive aliases
and functions are not loaded before TEXT runs. This handoff uses no prompt
detection or timed input. `--shell` defaults to the compositor's `$SHELL`, or
`/bin/sh` when unset. Command handoff supports sh/bash/zsh/dash/ksh syntax;
other shells can still be launched without a startup command.

For a direct process that closes its window when it exits, use
`compo ctl create --float 2,2,40,15 -- /absolute/program arg...`.

For a long-running agent or script, start `compo ctl stream` once and write NDJSON
requests to its stdin. It performs the handshake, then writes one response to
stdout for each request. Include an `id` and `op` in each request; do not send
another handshake. It waits for each response before sending the next request
and stops at EOF or the first error. The connection stays open while waiting for
more input. Response reads time out after ten seconds without data.

## Startup scripts

Compo optionally runs `$XDG_CONFIG_HOME/compo/init.sh`, or
`~/.config/compo/init.sh` when XDG_CONFIG_HOME is unset. Use `compo --init FILE`
for an explicit script, `COMPO_INIT=FILE` to select one through the environment,
or `compo --no-init` to skip scripts entirely. The command-line path takes
precedence over COMPO_INIT. A missing default file is fine; an unreadable explicit
file fails before compo opens the desktop. Headless mode only runs explicitly
selected scripts.

The script runs once under `/bin/sh` after the control socket opens, outside all
panes, with stdin from `/dev/null`. It does not need an executable bit. The host
continues servicing the socket while the script runs. It supplies `COMPO_SOCKET`
and `COMPO_BIN`, the absolute path to this compo executable, so neither PATH
setup nor socket discovery is necessary. The script inherits the launch working
directory and environment. Each window inherits that working directory unless
`--cwd` specifies another; a `cd` in the script alone does not change the host's
working directory.

```sh
#!/bin/sh
set -eu
ctl() { "$COMPO_BIN" ctl --quiet "$@"; }

ctl create --tile --name main --command 'tmux new-session -A -s work'
ctl create --tile --name sidebar --target main --edge left --ratio 2500 --command 'tmm'
ctl create --tile --name scratch --target main --edge bottom --ratio 2500
ctl focus main
```

An example is provided in [examples/init.sh](../examples/init.sh). No JSON
parsing, bootstrap pane, sleeps, or prompt detection is required. Each control
command waits for its server response. Successful script exit leaves the
compositor and its windows running. A nonzero exit aborts startup, closes created
windows, restores the outer terminal, and reports the status with up to 16 KiB
of captured script stdout/stderr. Successful script output is discarded. Use
`set -e` to stop at a failing control command. A still-running startup script's
process group is stopped when compo closes; launch long-lived applications in
windows rather than backgrounding them in the script. Startup scripts force an
empty desktop instead of the legacy fixture layouts.

## Wire protocol

Connect once and exchange newline-delimited JSON objects. Each request has a
string `id` of 1–128 bytes. First send `hello` with `version:1`; its response lists
implemented operations, instance identity, root cell dimensions, and limits.
Subsequent `ping` requests return `{"pong":true}`. JSON escaping applies to all
strings. Unknown fields, malformed JSON, unsupported versions, and unknown
operations return structured errors. A failed handshake can be retried.

For example, run this in a compo shell. The entire loop uses one connection:

```python
import json, os, socket

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
    connection.connect(os.environ["COMPO_SOCKET"])
    with connection.makefile("rb") as replies:
        requests = [{"id": "hello", "op": "hello", "version": 1}]
        requests += [{"id": str(i), "op": "ping"} for i in range(10)]
        for request in requests:
            connection.sendall(json.dumps(request).encode() + b"\n")
            print(json.loads(replies.readline()))
```

The initial host supports eight clients. Each frame, including its newline, is
at most 64 KiB. Per-client output queues are limited to 1 MiB and 64 outstanding
request IDs. An ID remains outstanding until its response is written to the
socket; wait for that response before reusing it. Oversized frames, duplicate
outstanding IDs, and exceeded queue limits close only the offending connection.
They do not attempt an ambiguous second response for the same ID. Extra clients
are closed immediately when all slots are occupied. Half-closed connections are
not a supported request/response pattern; keep the connection open while reading.

Socket I/O is nonblocking and has a per-loop read budget. A slow or malformed peer
cannot block the renderer or other clients. Listener and client descriptors are
close-on-exec and do not leak into child applications. Existing PTY writes are
still synchronous; asynchronous injected-input queues belong to the input stage.

`zig build test-control` runs protocol-contract tests without sockets or PTYs.
`python3 tests/control_host.py` tests the real host, including a 3,200-request
persistent connection, framing, negotiation, client limits, socket permissions,
child descriptor isolation, PTY responsiveness, and normal-exit cleanup.


## Window operations

`window.list` returns `windows` and `scene_revision`. Each window includes its
exact `window` reference, optional name, executable path in `command`, outer
`rect`, `content` rectangle, PTY columns/rows, cell pixel dimensions, kind, layer,
stacking order, visibility, and focus. Command metadata is null for shells opened
interactively. List visibility describes the window flag, not whether another
window covers it. References combine the instance ID and monotonic window ID;
slot reuse never retargets a reference. Names are unique among live windows, but
operations also accept names as described above. Replies always contain the
canonical reference, including `removed` in close responses.

Send these messages after `hello`, reusing the connection:

```json
{"id":"2","op":"window.create","name":"test","argv":["/bin/sh"],"placement":{"kind":"floating","rect":{"x":4,"y":3,"w":40,"h":16},"fit":"exact","layer":-100},"focus":false}
{"id":"3","op":"window.list"}
```

Creation returns `result.window`, `requested_rect`, and `scene_revision`. Use its
`window` reference for later commands:

```json
{"id":"4","op":"window.place","window":"INSTANCE/1","placement":{"kind":"floating","rect":{"x":10,"y":2,"w":50,"h":20},"layer":0}}
{"id":"5","op":"window.focus","window":"INSTANCE/1"}
{"id":"6","op":"window.close","window":"INSTANCE/1"}
```

Rectangles are zero-based outer cell bounds including borders, with minimum size
3 by 3 for floats. Exact fit is the default
and rejects constraints that would change the requested rectangle. `constrain`
applies full-screen bounds and reports both requested and actual
bounds. `window.place` can convert between floating and tiled placement without
restarting the child. Mutations during a pointer drag return `DragInProgress`.

Tiled placement uses `{"kind":"tiled","target":"INSTANCE/ID","edge":"left","ratio":2500}`.
`target` is optional and must reference a visible tile when supplied. Without it,
the placement splits the whole tiled area. `edge` is left/right/top/bottom and is
required when a tiled area already exists. `ratio` defaults to 5000, accepts
1–9999, and measures the new tile's share. A first tile fills the workspace.
Tiles reject rectangles, nonzero layers, and constrained fit. Splits that leave
any visible window without terminal content are rejected. Shared borders and
neighboring PTY sizes update with the layout; failed launches restore the prior
layout and PTY sizes. Tiled responses have a null `requested_rect`.

Layer is a signed 32-bit integer, default zero. Higher layers paint above lower
ones; always-on-top and raise/lower operate within a layer. A negative layer does
not hide a window or disable its pointer input. Hidden layers and opacity are not
implemented. Creation defaults to no focus change, even on an empty desktop.
`window.get`, `window.focus`, `window.raise`, `window.lower`, and `window.close`
accept only `window` besides the request ID and operation.

Creation accepts either `argv`, or optional `command` and `shell`. Omitting all
three starts the default interactive shell. `command` uses the handoff described
above; `shell` must be an absolute executable path. Combining `argv` with either
shell field is rejected.

`argv` requires an absolute executable path and does not perform shell expansion
or PATH lookup. It allows up to 128 arguments totaling 8 KiB; the executable path
is limited to 512 bytes. Optional `cwd` must be absolute. Optional `env` is an
object of environment overrides; the child inherits the host environment, with
TERM/COLORTERM defaults and its own COMPO_SOCKET. Names are 1–128 bytes. Encoded
name and executable metadata together are limited to 1 KiB so a full 32-window
list fits in one frame. NULs and invalid environment keys are rejected.

A close-on-exec status pipe confirms launch before creation succeeds. Failed
launches roll back without exposing a window. The current launch-status wait is
synchronous with a one-second bound; explicit close uses the existing bounded
child cleanup, which can wait about 200 ms before killing an unresponsive child.
Moving these lifecycle waits into asynchronous host states is follow-up work.
Socket reads/writes remain nonblocking. Natural child exits remove their windows;
get/close of a removed reference returns `UnknownWindow`. Lifecycle events and
retained exit results are not implemented yet.

## Headless tests

```sh
COMPO_HEADLESS=80x24 zig-out/bin/compo
```

This starts an empty desktop with fixed root dimensions and 8-by-16 pixel cells.
It needs no controlling terminal, discards display output, prints its socket path
to stderr, and runs the same scene, VT, PTY, and socket operations as the interactive
host. Dimensions must each be 3–1000. Terminate the disposable host with SIGTERM;
normal cleanup removes its socket and children. This mode is for isolated tests,
not detached display attachment.

`python3 tests/control_cli.py` checks the native CLI, persistent streaming,
targeted splits, ratios, float/tile conversion, neighbor PTY dimensions, failure
rollback, and startup command handoff using an isolated shell configuration.

`python3 tests/control_windows.py` creates its own headless host and checks real
child environment/cwd/PTY sizing, focus isolation, overlapping layers, exact and
constrained placement, failed launches, name collisions, stale references, slot
reuse, capacity, natural exit, and process/socket cleanup. Core tests separately
check layer hit testing and occlusion. No test discovers an existing user host.

### Startup metadata and reload

`startup.get` returns `result.script` (absolute path or null), `result.cwd`
(original startup directory or null), and `result.phase` (`initial`, `idle`,
`validating`, or `reloading`). CLI: `compo ctl startup`.

`startup.reload` starts shell syntax validation and returns the same metadata
with phase `validating`. CLI: `compo ctl reload`. The response acknowledges the
request, not successful completion; poll `startup.get` for the phase. Validation
failure preserves existing windows. Validation success closes all windows and
reruns the script on the same socket. Runtime failure leaves partial results
available and reports a notice and stderr diagnostics; no rollback is attempted.
The phase returns to `idle` on either success or failure.

Both operations accept only `id` and `op`. No script yields `NoStartupScript`;
an active startup/reload yields `StartupBusy`. Window references from before a
successful replacement become stale.
