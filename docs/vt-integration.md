# Moving the useful parts of tmm into tmux

## Direction

Evaluate libghostty-vt for application terminals in this tmux fork, including
the static sidebar. The `compositor-final` tag in `awesomo4000/tmm`, commit
`eeb0616`, preserves the relevant external experiment. The current `../tmm`
working tree no longer contains its compositor code.
Use it as a source of code, tests, and lessons. Do not link tmm as a dependency,
copy it wholesale, or treat its behavior as a correctness oracle.

All tmm paths below refer to that tag. Read them without changing the checkout:

```sh
git -C ../tmm show compositor-final:src/surface.zig
git -C ../tmm show compositor-final:handoff.md
git -C ../tmm show compositor-final:tools/deps-check.sh
git -C ../tmm show compositor-final:vendor/README.md
```

`handoff.md` contains the design and measurement notes. `tools/deps-check.sh`
tracks libghostty-vt releases and OSC 7501 work; `vendor/README.md` records the
dependency pin. Prefer the tag over the movable `compositor-archive` branch.

The earlier `../ghostmux/docs/shim-analysis.md` is additional research against
an older tmux and libghostty-vt snapshot. Its architectural observations are useful;
its specific missing-feature claims need rechecking against the chosen pins.
The tmm vendor notes pin libghostty-vt at `e3ebb1d1bf772cf5d1bc70b5ae19e6943e33a110`.
The ghostmux copy is older and is not automatically the dependency to select.

## What disappears inside the server

| External tmm mechanism | In-process replacement |
| --- | --- |
| `%output` subscription and octal decoding | Feed the terminal backend directly from the pane's PTY read path. |
| Parsing `%layout-change` and querying pane rectangles | Read existing window/pane layout objects and receive resize callbacks. |
| Discovering and reconciling pane existence | Allocate/free backend state with pane lifecycle. |
| `capture-pane` seeding after discovery | Maintain authoritative terminal state from process creation through detach/reattach. |
| `send-keys -H` for encoded keys and terminal replies | Write to the pane's PTY bufferevent. |
| `refresh-client -C` to make tmux resize panes | Use normal client sizing, layout calculation, and PTY resize paths. |
| Querying active windows and parsing notifications | Read the owning client's session and current window; use server events. |
| Discovering tmux keybindings through commands | Dispatch through tmux's existing key tables before terminal encoding. |

Keep raw pipe-pane and control-client outputs available to other consumers.
Only one emulator should be authoritative for an application's screen. Do not
run two independently mutable terminal histories and try to reconcile them.

## What to take from tmm

- `src/surface.zig`: terminal/stream/render state setup, reply sink, pixel sizing,
  input encoding, mode publication, and image placement extraction.
- `src/png.zig`: PNG decoder installation and its tests. A library build needs
  its decoding callback wired explicitly.
- `src/panes.zig`: per-pane ownership lessons and lifecycle tests. Discard the
  external command transport, initial seeding, and layout reconciliation.
- `src/region.zig` and `src/pty.zig`: shell-terminal behavior and resize tests.
  Reuse tmux's own process machinery where it already supplies the equivalent.
- `tests/images*.py`, `tests/size_report.py`, `tests/compositor*.py`, and
  `tests/split_shell.py`: adapt the useful behavioral cases to a native server.

`Surface.draw` targets libvaxis and `ImageSink` uses vaxis image objects, so the
renderer cannot be pasted into tmux unchanged. Extract terminal state/readout
and image geometry behind a small C ABI, then provide a tmux renderer. Keeping
adapted Zig behind that ABI is an option; rewriting it in C is not required.
The synchronization and locking choices also need review for tmux's event loop.

## Actual integration work

The difficult boundary is downstream of parsing. tmux's `screen_write_*`
functions both mutate its grid and emit optimized terminal operations.
`window-copy.c`, `cmd-capture-pane.c`, `format.c`, redraw code, input encoding,
and other consumers inspect screen/grid data directly.

A staged prototype can keep a read-only tmux viewport projection of libghostty-vt's
screen for drawing, updated from dirty rows. libghostty-vt owns history and reflow.
Copy/search/capture/history formats must read that authoritative history through
an adapter; a viewport projection alone does not preserve them. Retain tmux's
existing screens for menus, chooser modes, status, and other generated UI.

A projection trades integration simplicity for copying and potentially more
output bytes. Measure scrolling, large output, interactive latency, redraw
volume over SSH, and multiple attached clients before deciding to keep it.
Do not claim tmux's optimized scroll/insert/delete stream is preserved merely
because final cells match.

Preserve tmux-specific policies and effects: passthrough, terminal identity and
capability queries, title/rename permission, clipboard forwarding, hyperlinks,
bells, shell integration, synchronized output, and request/reply ordering.
Pin and inspect libghostty-vt's C API or expose a narrow Zig adapter for the required
behavior. Its public C API is still marked unstable in the inspected headers.

Keyboard decoding remains tmux's responsibility at the outer terminal. libghostty-vt
encoding cannot recover events that tmux discarded before dispatch. Preserve
user key tables and assess richer key events separately. Mouse/paste/focus
encoding needs the focused terminal's actual negotiated modes.

## Kitty graphics is still an output integration

libghostty-vt can own image protocol state, data, and placement semantics. tmux still
must display the result on each outer terminal. Use per-terminal upload and
placement caches, collision-free IDs across panes and sidebar, clipping,
visibility updates, and explicit deletion when panes switch or disappear.
Keep image source data independent of client presentation so reattach redraws
correctly without asking applications to upload again.

A single pane can be visible to clients with different cell sizes and graphics
capabilities. Choose a deterministic application-facing pixel size policy and
render correctly for each client. Do not promote tmm's first working graphics
path into a claim of complete protocol compliance. See
[the Kitty audit](kitty-graphics.md).

## Sequence

1. Extract a small backend boundary and prove one client-owned sidebar shell.
2. Adapt tmm's libghostty-vt integration for that terminal, including replies and input.
3. Prove an opt-in ordinary pane using direct PTY input, authoritative libghostty-vt
   state, and a renderer adapter.
4. Preserve copy/search/capture, history/reflow, tmux effects, multiple clients,
   and performance before making it the default for all application panes.
5. Complete graphics output and the protocol conformance matrix.

This is a port and simplification of existing work, plus integration with tmux's
screen consumers. It is not a new control-mode compositor.

Primary API reference: https://github.com/ghostty-org/ghostty/blob/main/include/ghostty/vt.h
