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
Screen snapshots, injected input, subscriptions, and `compo ctl` remain subsequent
stages. Use a persistent socket client such as Python for now.

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
operations require the exact reference returned by discovery or creation.

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
3 by 3. Only floating placement is supported by the API. Exact fit is the default
and rejects constraints that would change the requested rectangle. `constrain`
applies normal workspace constraints and reports both requested and actual
bounds. Placement requires a floating window and never changes neighboring tile
sizes. Mutations during a pointer drag return `DragInProgress`.

Layer is a signed 32-bit integer, default zero. Higher layers paint above lower
ones; always-on-top and raise/lower operate within a layer. A negative layer does
not hide a window or disable its pointer input. Hidden layers and opacity are not
implemented. Creation defaults to no focus change, even on an empty desktop.
`window.get`, `window.focus`, `window.raise`, `window.lower`, and `window.close`
accept only `window` besides the request ID and operation.

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

`python3 tests/control_windows.py` creates its own headless host and checks real
child environment/cwd/PTY sizing, focus isolation, overlapping layers, exact and
constrained placement, failed launches, name collisions, stale references, slot
reuse, capacity, natural exit, and process/socket cleanup. Core tests separately
check layer hit testing and occlusion. No test discovers an existing user host.
