# Local control socket: first slice

Compo creates a private `/tmp/compo-XXXXXX/control.sock` on startup. It prints
`COMPO_SOCKET=...` before entering the alternate screen and exports that variable
in child shells. The directory is mode 0700 and the socket is mode 0600. Each
launch uses a random 128-bit instance ID. Normal exit removes the socket and its
private directory; a SIGKILL can leave them behind. Startup never reuses an old
socket path or deletes another instance's directory.

This implements the transport stage of the [control spec](../specs/00-control-proto.md).
Only `hello` and `ping` are supported. Window creation, inspection, input injection,
subscriptions, headless mode, and the `compo ctl` CLI are subsequent stages.

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
