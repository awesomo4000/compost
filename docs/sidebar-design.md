# Static client sidebar

The sidebar is a terminal surface in the [per-client compositor](compositor-design.md).
That design governs layout, overlap, clipping, and input ownership. The sidebar
is the first use case, not a special column outside the composition model.

## Agreed behavior

The sidebar is a real terminal with a shell, usable for any terminal program.
It behaves like a pane for typing, mouse input, scrolling, copying, and resizing,
but belongs to an attached client rather than a session or window. Switching
windows or sessions, changing layouts, and zooming the workspace leave it in
place. Two Ghostty terminals attached to tmux get separate sidebar processes.

For the first version, create the sidebar on attachment when enabled, preserve
it through window/session switches, and end it on detach. Reattachment starts a
fresh process. Durable display identities and process restoration are deferred.

A sidebar controller is a view of tmux state. It reads sessions, windows, panes,
and status, and sends explicit control commands when the user interacts. The
host terminal need not know about agent lists or controller UI. Preserve the
user's regular configuration and Ctrl-a bindings.

Sessions belong to the server. Clients attach to sessions; two clients on the
same session ordinarily share that session's selected window. This design makes
the sidebar and its focus client-local, without silently changing tmux's shared
session/window semantics.

## Baseline and useful existing work

Working source: `vendor/tmux`, commit
`a864c419900182fe624abf73db72ae6f1b0ab9a5`.

Native `side-status` already reserves a column and handles much of the geometry,
including full redraw, incremental output, resizing, cursor placement, and mouse
coordinates. It renders formats, not an application terminal. Its options are
session-scoped, so the new static terminal needs client-owned effective settings.
The existing `config/sidebar.conf` demonstrates native side status only. It does
not implement the shell-backed sidebar described here.

The `compositor-final` tag in `../tmm`, commit `eeb0616`, is reference code,
not a dependency. Its current working tree no longer has the compositor files.
Copy and adapt useful pieces,
retaining their notices, and use its tests as evidence to recheck. It is early
code with known bugs. Do not import its external control-client machinery into
tmux. See [the VT integration plan](vt-integration.md).

## Required changes

Use nested rectangular splits for docking, including asymmetric corner
ownership, and explicit rectangles with z-order for floating surfaces. Both
use the same rendering and input contracts. The workspace can itself float
above client terminals. Implement a left terminal first, but exercise overlap
early instead of leaving it as a future renderer redesign.

In normal tmux, the client process passes terminal descriptors and identity to
the server, which manages drawing through that client's tty. There is no
existing arbitrary viewport-allocation protocol between an external client
program and the server. The proposed reservations are server-managed per-client
state. Every drawing and input path must respect the workspace rectangle,
including status/prompts, menus, images, scroll operations, and mouse routing.
Keep tmux status, prompts, and menus inside the workspace surface; compositor
decorations have separate ownership.

| Area | Change and source locations |
| --- | --- |
| Ownership | Add a client-owned terminal object in `tmux.h` and its implementation module. Integrate creation, detach, disconnect, and destruction in `server-client.c`. Session switching must not recreate it. |
| Process | Reuse PTY/job or pane spawning mechanics in `job.c` and `spawn.c`, including the configured shell, environment, cwd, child exit, process reaping, and cleanup. `job_run` already supports `JOB_PTY`. |
| Terminal state | Store parser/backend state, main and alternate screens, history, palette, cursor, modes, and pending replies independently of the current window. Use a backend interface suitable for libghostty-vt. |
| Geometry | Build on `status_side_size`, `resize.c`, `tty.c`, and `screen-redraw.c`, but obtain the reservation from the owning client. Decide precedence with native side status; first version should use one sidebar column rather than overlapping two. |
| PTY resizing | Resize to the sidebar content rectangle and deliver SIGWINCH. Include actual pixel dimensions when known. `job_resize` currently fills cell dimensions only. A session switch must not change the effective width. |
| Drawing | Render into the reserved rectangle only. Support full and partial redraws, clears, scrolling, cursor shape, alternate screen, and synchronized output. Coalesce output; do not block the server loop on large transfers. |
| Focus and input | Add client-local sidebar/workspace focus, route normal keys to the focused terminal, and keep the configured tmux prefix active. Translate mouse coordinates and manage drag ownership across the divider. Deliver focus reports and bracketed paste to the correct terminal. |
| Pane-like commands | Define sidebar targeting for copy mode, paste, capture, send-keys, resize, and respawn. Existing commands assume a window-backed pane, so this is explicit integration work. Workspace split/zoom/layout operations must not absorb the sidebar. |
| Client targeting | Expose the owner's identity and server socket to the sidebar process. Controller commands must target that client explicitly, as tmm already does with switch-client -c. Do not infer the owner from the most recently active client. |
| Settings and UI | Add commands/options to enable, hide, focus, resize, and respawn the sidebar. Names such as static-sidebar are proposals, not existing commands. Keep lifecycle and geometry local to the client, with defaults supplied by configuration. |
| Build and docs | Register modules in the current build and document ownership, command targets, process lifetime, and keybindings. |

Normal shell commands such as `tmux new-window` also need correct implicit
context when launched from a sidebar. Exporting a client name alone does not
teach existing target resolution about it. Add and validate an owner-context
path in command/client lookup, or require explicit client context in the first
controller integration. Do not set a misleading TMUX_PANE pointing at the
workspace's currently active pane.

## Where reuse stops

An ordinary `window_pane` carries a window pointer, options, layout cell,
process state, history, and input context. Merely allocating one with no window
would violate assumptions in input, rendering, event dispatch, and commands.
A hidden session would keep those assumptions alive but introduce synthetic
windows and targets into the server model. Prefer extracting terminal services
that can have either a pane or a client owner.

The existing parser can parse into a standalone screen using
`input_parse_screen`. That is not yet a complete interactive terminal backend:
`input_get_event` drops replies without a pane, pixel queries consult the pane's
window, Kitty APC dispatch requires a pane, and synchronized output is pane
based. If the prototype uses tmux's parser, those paths need owner callbacks.
If it uses libghostty-vt, implement those effects through the new backend interface.

Retain tmux grids for menus and other internally drawn UI. Whether application
screens use libghostty-vt should not dictate that every tmux screen becomes a libghostty-vt
terminal.

## First proof

Create one shell-backed sidebar in an isolated server and record its PID. Switch
windows and sessions, split/zoom the main workspace, and confirm the PID and
sidebar contents stay unchanged. Attach a second terminal and prove its sidebar
has an independent PID, focus, and width. Detach the first and verify cleanup;
reattach and verify a new process starts.

Then exercise a full-screen application, terminal queries, resizing, mouse
reporting, selection/copy, paste, and the user's bindings. Rendered assertions
need a PTY or enclosing terminal capture; capturing the workspace pane alone
cannot inspect the sidebar. All test sockets and fixtures belong in fresh
`/tmp` directories.
