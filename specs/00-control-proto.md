# Compo control protocol

Status: staged implementation. Transport and floating window lifecycle are
implemented; see [the current API](../docs/control-protocol.md) for supported
operations and limits. The complete protocol below remains the target, including
asynchronous lifecycle waits, observation, input, subscriptions, and the CLI.

## Purpose

Let an agent or test runner connect once to a running compo instance, create a
terminal window, drive an application through states, and observe the results.
The terminal is a direct PTY hosted by compo, with libghostty-vt retaining its
screen. No tmux server or control client sits between the driver and application.

Keep this small: no scrollback service, session database, persistent daemon, or
recovery of running applications after compo exits. Connection loss need not
terminate applications, but reconnection starts a new observation subscription.
The CLI is a wrapper around the persistent protocol, not the protocol itself.

## Architecture and identity

Use a local Unix-domain socket on macOS first. Integrate nonblocking socket I/O
into the host event loop. Parse requests into commands applied by that loop;
socket handlers must not mutate the scene or VT concurrently with rendering.
Keep protocol encoding, host operations, and terminal-independent geometry
separate. Leave Windows transport behind an adapter for later work.

Each host launch generates an instance ID. A window reference consists of that
instance ID and the existing monotonic scene window ID, encoded as strings:
`instance-id/window-id`. Never address windows by reusable PTY slot or PID.
References survive movement, docking, resizing, focus changes, and layer changes.
An exited or removed reference must never resolve to a subsequent window.

Optional names are unique among live windows within an instance. Resolve a name
once to an exact reference before replay; never automatically retarget a replay
when its named window disappears. List results include reference, name, command,
process state, geometry, layer, stacking order, visibility, and focus.

Create a private per-instance socket directory with mode 0700 and socket mode
0600. Prefer an owner-controlled runtime directory, otherwise a securely created
temporary directory. Verify ownership before reuse or cleanup; reject unsafe
existing paths and symlinks. No TCP listener or remote authentication in v1.
Expose the socket location at launch and through `COMPO_SOCKET` in child shells.
External drivers can supply `--socket PATH`; never guess the target instance.

## Transport and framing

One connection supports many requests, responses, and subscriptions for its entire
lifetime. No process execution is required between interactions. Start with UTF-8
JSON objects separated by newlines. JSON strings escape embedded newlines. Encode
arbitrary PTY input/output bytes as base64, never as presumed UTF-8 text.

The client first sends `hello` with protocol major version 1. The response includes
instance ID, supported operations, capabilities, limits, and root geometry.
Reject incompatible versions and unknown operations or fields with structured
errors rather than silently ignoring a misspelled option.

Requests carry connection-local string IDs. Responses echo the ID and contain
either `result` or `error: {code, message}`. Events carry a subscription ID and
monotonic sequence number. A request gets exactly one terminal response, except
when the connection closes before it can be delivered. Reject duplicate in-flight
IDs. Responses may arrive out of order; command acceptance follows received order
on one connection. The host event loop serializes commands from different clients.

Illustrative messages:

```json
{"id":"1","op":"hello","version":1}
{"id":"2","op":"window.create","name":"game","argv":["./game","--seed","123"],"cwd":"/tmp/compo-test","placement":{"kind":"floating","rect":{"x":8,"y":4,"w":60,"h":24},"fit":"exact","layer":-100},"focus":false}
{"id":"3","op":"subscribe","window":"abc/7","events":["screen","resize","exit"],"initial_snapshot":true}
{"id":"4","op":"input.key","window":"abc/7","key":"right","action":"press"}
{"id":"5","op":"screen.get","window":"abc/7"}
```

Requests such as `screen.get` can return a transfer descriptor. Send the snapshot
as ordered `transfer.chunk` events followed by `transfer.end`, all bound to the
same transfer ID and snapshot revision. Encode chunks independently as base64;
the receiver concatenates decoded bytes. Include byte offsets and final byte
count. Interleaved events cannot become part of the transfer. A missing end event
means the transfer is incomplete and must be discarded.

Initial limits: 64 KiB per wire frame, 1 MiB outbound queue per connection,
256 KiB pending injected input per window, and 16 MiB per immutable screen
snapshot. Advertise these in `hello`; tune them with measurements. Large snapshots
stream from bounded immutable storage rather than filling the outbound queue.
Reject oversize requests before applying mutations. Raw writes are individually
bounded and can be sent in acknowledged chunks. Image blobs get their own
negotiated limits when graphics observation is implemented.

## Window lifecycle and placement

The first usable slice must support both creating and removing windows, not just
attaching to an already-open shell.

| Operation | Contract |
| --- | --- |
| `window.list`, `window.get` | Return current host state and exact references. |
| `window.create` | Spawn an explicit argv, optional cwd and environment overrides, and requested placement. Return reference and actual geometry. No implicit shell parsing; request a shell explicitly if needed. |
| `window.place` | Change geometry, presentation, or layer without replacing the PTY or process. |
| `window.focus` | Explicitly move human keyboard focus. Injected input never implies focus or raising. |
| `window.raise` / `window.lower` | Change stacking within the current layer. |
| `window.close` | Close one exact window, terminate its owned child using bounded HUP/TERM/KILL cleanup, reap it, and remove its scene entry. This is process termination, not a shell `exit` keystroke. |

Creation defaults to `focus:false`. Validate capacity, geometry, executable launch,
and placement before exposing a live window. An exec failure must be reported
through a child launch-status channel, not mistaken for successful creation.
Rollback failures without leaking processes, descriptors, scene entries, or names.
Allocate the PTY and configure its content size before the child starts.

Coordinates are zero-based root-relative cells, with half-open rectangles. `rect`
describes the outer window, including decorations. Responses also return the
content rectangle, PTY columns/rows, measured cell pixel size, and scene revision.
Input coordinates are content-relative, never outer-window coordinates.

`fit:"exact"` rejects a placement that cannot be honored without changing other
windows. `fit:"constrain"` uses normal layout constraints and returns requested
and actual rectangles separately. Never silently clamp exact test placements.
Initial support is explicit floating placement; tiled placement then adds a target
reference, edge, and ratio in basis points. Dock placement explicitly specifies
edge, extent, and whether space is reserved. Layout mutations return all changed
window sizes so tests can assert effects on neighbors.

For create/place, commit the scene and PTY size updates before acknowledging.
If a resize operation fails, roll back where possible and report failure; never
report success with a partially applied layout. The response does not guarantee
that an application has handled SIGWINCH or repainted yet.

Natural child exit emits an exit event with status, then a removed event. Explicit
close completes after cleanup and removal. Emit those lifecycle events before its
success response on the requesting connection when subscribed. Retain a bounded
terminal result for stale-reference diagnostics; do not retain arbitrary history.
Compo must remain alive after the last controlled window closes in desktop mode.

## Layers and later test presentation

Accept `layer` in floating create/place from the first placement implementation.
It is a signed integer, default 0; lower layers paint behind higher layers.
For example, -100 can be a testing layer and 0 the interactive workspace. Layer
is independent of insertion order, focus, and space reservation.

Define stacking as `(layer, always_on_top, order)` with ascending back-to-front
order. Raising stays within a layer; `always_on_top` stays within a layer too.
Compositor-owned UI has a separate final decoration pass. Adapt existing hit
testing and visible-region computation to use the same ordering. Reserve no
magic test-layer number: -100 is a convention, not a hidden privilege.

Initially allow nonzero layers only for floating windows. Reject other
combinations until cross-layer tiling and dock reservation policies are defined.
This avoids a testing dock unexpectedly changing the interactive workspace.

Depth alone does not make a test window invisible: uncovered areas still show,
and normal pointer hit testing can reach them. A layer is not a security boundary.
For early noninterfering tests, use a separate headless/test host instance.

Later add explicit layer visibility, interaction policy, and opacity. A hidden
test layer should keep its PTYs running and retain independent terminal sizes
without taking physical focus or pointer events. Direct protocol input and screen
inspection must still work. A partially transparent layer needs real composition
of cells and graphics, beyond today's preview tint. Reject unsupported visibility
or opacity options until that work exists; never pretend a window was hidden.

## Input and observations

Expose `input.text`, `input.key`, `input.mouse`, and `input.raw` separately.
Text is UTF-8; paste wrapping is explicit and follows the child's bracketed-paste
mode. Keys include modifiers and press/repeat/release actions. Encode them for the
child's active terminal modes, including Kitty keyboard flags where supported.
Reject unsupported key actions rather than synthesizing misleading releases.
Raw input writes exactly the decoded bytes to the child's PTY.

Mouse input specifies cell or pixel coordinates and an explicit button/action.
Translate into the child's negotiated mouse format. Do not route injected input
through compositor shortcuts, border gestures, desktop hit testing, or physical
pointer capture. Direct input targets the specified child even if obscured.
Human input remains possible; deterministic tests use a dedicated instance until
an explicit exclusive-input lease is implemented.

Partial PTY writes and EAGAIN must not block the host loop. A success response
means all bytes for that input request were written to the PTY, not that the
application read them. On failure after a partial write, return the byte count;
retries must not silently duplicate the accepted prefix.

`screen.get` returns the retained application screen, not a scrape of the outer
terminal. Include size, cursor, modes needed for input encoding, text/graphemes,
cell widths, colors, and attributes. Occlusion does not remove cells from this
snapshot. Expose scene state separately. A text-only representation is available
for simple assertions. Distinguish default, palette, and explicit RGB colors.

Subscriptions support screen changes, geometry changes, exit/removal, and optional
raw PTY output. Raw output is observed once before VT parsing; it is never stolen
from the renderer or forwarded blindly to the outer terminal. Raw events include
byte offsets. Screen events have a per-window monotonic revision and an associated
processed-output offset; layout events have a separate scene revision.

An initial snapshot and its subscription boundary are captured atomically in the
host loop. Deliver only subsequent changes after the snapshot revision. Screen
updates can initially be full snapshots, then become revision-based deltas. A
delta names its base revision; a mismatch requires a fresh snapshot.

Slow consumers must not stall PTYs, input, or rendering. Coalesce screen changes
into a new snapshot with an explicit resync indication. Never silently discard
raw bytes: issue a gap event with offsets, or terminate that subscription if the
queue cannot carry the gap notification. Disconnect clients exceeding bounded
queues when recovery cannot be represented. Do not drop command responses and
continue as if they were delivered. A disconnected caller must inspect state
before retrying a mutation whose result is unknown.

## Replay and synchronization

Record actions, their exact references, replies, observed revisions, and relative
monotonic timestamps. Replays bind logical names to newly created references;
they do not reuse references from a prior host instance.

Provide cancellable `wait` requests for text predicates, a revision newer than a
specified revision, and exit, with explicit timeouts. Evaluate the predicate and
register the waiter atomically, so a fast application response cannot be missed.
Text matching is against defined snapshot text, not ANSI bytes; v1 needs literal
substring matching, not arbitrary expressions evaluated by the server.

An input acknowledgment and a later revision do not prove that revision resulted
from that input. Output may already have been buffered. For asynchronous apps,
wait for meaningful screen conditions. An optional quiet interval is a heuristic,
not a completion barrier, and continuously animating games may never reach it.

Exact game replay needs application cooperation: fixed seed, fixed terminal and
pixel dimensions, a controlled simulation clock, and explicit frame/step markers.
Add an opt-in app test channel later for `step` and frame acknowledgments. Do not
invent a general “12 ticks” operation over an arbitrary PTY. Protocol observation
alone cannot guarantee deterministic state, frame boundaries, or input causality.

## Development chunks and acceptance gates

Each chunk should be reviewable and usable before the next starts.

1. **Contracts and transport.** Add request types, version negotiation, framing,
   bounded queues, socket ownership, and persistent connection handling. Test
   fragmented/coalesced input, malformed JSON, duplicate IDs, version rejection,
   and clean disconnects. Gate: thousands of requests on one connection without
   spawning helper processes or leaking descriptors.
2. **Window lifecycle and layers.** Add list/get/create/close, explicit floating
   rectangles, names, stable references, and numeric layer ordering. Add a test
   host mode with fixed root and pixel dimensions that does not require a human
   terminal. Gate: create, overlap, move, resize, reorder, and remove windows;
   exact-placement failures leave the scene unchanged; child cleanup is complete.
3. **Observe and inject.** Add screen snapshots and text/key/mouse/raw input.
   Gate: drive a deterministic fixture from menu to play to result over one
   connection, verify styles and cursor, and prove input goes only to its target.
4. **Subscriptions and synchronization.** Add atomic initial snapshots, revisions,
   output offsets, waits, cancellation, chunked transfers, and backpressure.
   Gate: interleave input with continuous output; no missed initial boundary,
   silent stream gaps, or compositor stalls with a deliberately slow subscriber.
5. **CLI and replay driver.** Add `compo ctl` wrappers and a persistent `ctl stream`
   mode using the same wire protocol. Supply a small programmatic client and
   recorded action/condition replay. Gate: repeat fixture scenarios without sleeps
   as the primary synchronization mechanism, and report actionable timeout state.
6. **Full placement controls and graphics observation.** Add target-relative tiles,
   split ratios, docks, image metadata and bounded image downloads. Keep image IDs
   scoped to the window and graphics generation. Add screenshot capture with an
   explicit definition of whether it represents the VT or the composed display.
   Gate: verify Kitty placement, clipping/restoration, and correct graphics after
   resizing; text snapshots alone cannot pass graphics assertions.
7. **Noninterfering layers and deterministic app hooks.** Add hidden/noninteractive
   test layers, optional opacity, input leases if needed, and cooperative frame
   stepping. Gate: tests run while interactive windows retain their layout, focus,
   pointer behavior, and rendering throughput. General image alpha composition
   and reconnectable display attachment remain separate projects.

## Testing engineering

Use three levels of tests. Pure protocol tests need neither PTYs nor VT state.
Core scene tests exercise placement, layers, shared borders, focus, and visibility
without terminals. Integration tests launch a disposable compo instance and real
PTY children, then talk to its socket as an external client would.

Reuse the existing disposable-PTY infrastructure for outer-terminal integration.
The headless host should share the same command dispatcher, PTY ownership, VT,
and scene paths; avoid a separate fake implementation that only passes tests.
Run each scenario in a dedicated temporary directory under `/tmp`, with unique
socket names and child process groups. Cleanup runs on failure and timeout too.
Never discover or control the developer's existing windows in automated tests.
For permission/path tests, create disposable targets under `/tmp`; assume every
protection under test could fail.

Fixtures should cover a mode-switching input recorder, a deterministic menu/game,
a continuous-output producer, a resize reporter, and a Kitty graphics producer.
Use an independent VT decode of emitted display output for renderer assertions;
otherwise testing a snapshot against itself can hide display errors. Validate
logical RGB/Unicode/image state separately from font-dependent screenshots.

Required regression cases:

- Two windows receiving distinct simultaneous input; obscured windows remain
  addressable. Creation and injection do not steal human focus.
- Stale references after close, slot reuse, process exit, and host restart.
- Spawn failure, capacity exhaustion, exact-fit rejection, partial PTY writes,
  resize errors, repeated close, and disconnect during an in-flight mutation.
- Requested versus actual rectangles, content insets, SIGWINCH sizes, layer
  ordering, raise/lower within a layer, and rejected unsupported layer options.
- Split UTF-8, graphemes, wide cells, ANSI sequences split across reads, alternate
  screens, cursor-only changes, bracketed paste, SGR cell/pixel mouse formats,
  application cursor keys, and supported Kitty keyboard actions.
- Snapshot/subscribe races, output arriving during a snapshot transfer, wait
  completion before waiter registration, cancellation, and exit while waiting.
- Slow readers, queue overflow, explicit raw gaps, bounded memory, and recovery
  to a fresh screen snapshot without freezing a continuously emitting child.
- Kitty uploads and placements during recording and replay, independent image
  namespaces, deleted images, and final screen cleanup after window removal.

Measure idle CPU, command-to-PTY latency, input-to-observed-state latency, queue
high-water marks, and allocations after warmup. Compare with the existing TUI
redraw baseline, with control disabled, connected idle, and actively subscribed.
Use generous deadlines for correctness tests; keep timing regressions in a
separate benchmark so scheduler noise does not make the main suite flaky.

The first milestone is complete when an external driver can create a named
window at an exact rectangle and layer, keep one connection open, drive and
inspect multiple application states, then remove the window and shut down the
disposable host without leaving child processes or sockets behind. This milestone
comprises chunks 1 through 5; later
graphics and presentation work must not be implied by its completion.
