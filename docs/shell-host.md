# Interactive shell host

`mise run shell` opens an empty desktop. Ctrl-] Enter creates a floating shell,
using `$SHELL` or `/bin/sh`. Up to 32 shells can run. Closing the last shell
returns to the desktop; Ctrl-] q closes all children and quits.

Use `compo ctl create --tile --command 'your_program'` to create a window through
the control socket. Each window has its own optional command; after it finishes,
an interactive shell remains. `--float X,Y,W,H` places a float, and tile edge,
target, and ratio options build splits. See [the control CLI](control-protocol.md#command-line-client)
for examples and persistent scripting support.

For an xinitrc-style layout, put a shell script in `~/.config/compo/init.sh` or
launch `compo --init FILE`. It runs outside the panes, with `COMPO_BIN` and
`COMPO_SOCKET` set. Name windows with `--name main`, then use `--target main` or
`ctl focus main`. See [startup scripts](control-protocol.md#startup-scripts) and
[the example](../examples/init.sh). `--no-init` skips startup scripts.

Option-left-drag moves a float. Option-Control-left-drag moves freely across the
full screen without docking or resizing. Border handles still resize. Option-dragging a tiled or wall border pulls it
out after a small movement threshold, restoring its remembered floating size.
Drag near a workspace edge to split the whole tiled area. Over an existing
tile, broad left/right/top/bottom zones split that tile; the central 40% in both
dimensions leaves the window floating. The outer workspace band takes priority. A muted gray-blue rectangle previews the destination. The first edge drop
occupies that half of the desktop; adding another tile fills the tiled area. Release commits;
Escape restores the original layout. Each split starts at 50/50. For a wall drop, start an Option-drag, then release Option and hold Control
while moving to a workspace edge. Walls reserve one
third of the available dimension. Existing shells retain their PTYs and IDs.
The preview does not resize neighbors until release. Tiles share one border. Drag a shared vertical or horizontal divider to resize
both sides without changing focus. Nested splits resize within their parent;
Escape cancels. Float edges/corners and the legacy left sidebar divider also
support dragging. Four-sided wall resizing remains future work. The preview consumes no window slot.

Click focuses a window. Ctrl-] Tab cycles focus and raises the selected window
within its layer, repainting retained content even when the child is idle. Ctrl-] twice sends a literal Ctrl-].
The user's tmux prefix passes through. Ctrl-] f toggles a floating window.

`COMPO_LEGACY=1` starts the original left dock and main tile. `COMPO_SINGLE=1`
starts a single full-root shell; `COMPO_FLOAT=1` adds the third floating shell.
These legacy layouts exit when their children close and return the main shell's
status. `COMPO_COMMAND`, `COMPO_SIDEBAR_COMMAND`, and `COMPO_FLOAT_COMMAND`
provide fixture commands. `COMPO_DESKTOP=1` forces empty-desktop startup even
when those variables are set. In desktop mode each new shell uses COMPO_COMMAND
if provided. Desktop quit returns zero.

To try a startup command that leaves a shell when it finishes, the existing
launcher accepts this wrapper:

```sh
COMPO_SINGLE=1 COMPO_COMMAND='/bin/bash -c "your_command_here; exec /bin/bash -i"' ./zig-out/bin/compo
```

Replace `your_command_here` with the program to launch. The semicolon opens the
interactive shell even when the program returns a nonzero status. Exiting that
shell closes the window. The first command runs in noninteractive Bash; aliases
and functions from interactive startup files are only available in the shell
opened afterward. An explicit `exit` or `exec` in the first command bypasses the
handoff. This uses process execution, with no prompt detection or timed input.
For a complete layout, use a startup script with per-window control commands.

`zig build` installs `zig-out/bin/compo` and both demos.

The window model remains terminal-independent. `src/shell.zig` connects it to
the terminal adapter and renderer. `src/host.zig` handles POSIX PTYs, tty modes, polling, signals, and child cleanup.
It uses standard-library platform definitions and calls libc directly for OS
services; the compositor/host interface uses ordinary Zig functions and slices.
There is no project-owned C host source or header translation step. It contains
no layout or terminal-emulation logic. Native Windows hosting remains future work.

## Scrollback

Each hosted terminal retains up to 8 MiB of primary-screen history. Alternate
screens keep their usual no-history behavior. Wheel events browse history when
the child has not enabled mouse reporting; tmux and mouse-aware TUIs keep their
wheel input. Typing returns a wheel-scrolled window to live output before sending
the input to the child.

Shift+PageUp/PageDown scroll the focused window by a page, including when the
child owns the mouse.

Ctrl-] [ toggles explicit scrollback mode in the focused window. Use Up/Down or
k/j, PageUp/PageDown, g for the oldest retained row, and G for live output.
Escape or q exits and returns to live output. While in this mode, keys are consumed
by compo and wheel events browse history even when the child owns the mouse.
New process output does not pull a scrolled viewport back to the bottom. History
remains subject to the byte limit and is discarded with its window.

## Copy and paste

Click inside a shell to focus it without selecting. Drag to another cell with
the left mouse button to select text from that terminal only. Selection respects wide characters and combining marks; copied soft wraps
are joined. Ctrl-] y copies the selection to the outer terminal clipboard through
OSC 52, then clears the highlight. A muted teal `[ N copied ]` notice appears in
the top border for two seconds. Completed bracketed pastes show `[ N pasted ]`.
Counts are Unicode code points, not UTF-8 bytes; combining marks count separately.
Copy notices confirm that compo sent the clipboard request, not that the outer
terminal accepted it. Paste notices count bytes successfully sent to the child
as characters; they do not imply the application has processed the paste.
Unbracketed input has no paste notice because it cannot be distinguished from
typing. Labels are omitted if the border is too narrow or obscured. Escape cancels a selection. Ordinary typing
also clears it before going to the child.

Mouse-aware applications keep their normal mouse events. To select their text,
focus the window and press Ctrl-] c, then drag and copy with Ctrl-] y. Ctrl-] c
again or Escape cancels this selection mode. Borders still move/resize windows;
selection drags clamp at the terminal content edges rather than spanning windows.

Use the outer terminal's normal paste command, such as Command-V on macOS.
Compo sends it to the focused child and preserves bracketed-paste boundaries when
that child requests them. It never reads the system clipboard itself. Copy works
over SSH when the outer terminal supports and permits OSC 52 writes; terminal
settings or intermediate multiplexers can block it. Compo cannot confirm that the
terminal accepted the write. Copies larger than 1 MiB ring the bell and are not
sent. No clipboard polling, query requests, or automatic child OSC 52 forwarding
is enabled. Clipboard writes happen only on the explicit copy shortcut.

Selection also works on the visible scrollback viewport. Selection autoscroll,
word/line gestures, rectangular selections, and clipboard readback are not included.

## Display and input

Unfocused terminals show a muted teal cell highlight at their retained cursor position
when the application requests a visible cursor. Cursor-only output moves it even
while another window has keyboard focus. The marker preserves the character and
styles beneath it, highlights a complete wide glyph, and follows window clipping.
It disappears when the application hides the cursor or the window gains focus;
the focused window uses the outer terminal cursor. This is a cell background
highlight, not a native hollow outline, and it does not tint Kitty image pixels.


The renderer projects retained libghostty-vt cells, styles, wide characters,
combining characters, and cursor state through the window's visible region.
It uses libghostty-vt row identities and dirty flags to skip unchanged rows,
then compares encoded rows before sending them in a synchronized frame. Adjacent
cells are emitted as text runs, with cursor positioning at each visible run and
style changes only when needed. The host uses pooled allocations and the encoder
retains its frame buffer, row scratch space, and per-row cache capacity between
draws. The host writes a borrowed frame directly; callers must not free it or
retain it across another draw. Visibility regions are cached until the scene
revision changes. Buffers grow when needed and are released with the renderer. Unchanged surfaces
are skipped; full clearing is reserved for layout changes. The cursor is restored
to the focused surface after painting. The host owns outer input modes and keeps
focus reporting enabled across frames to avoid focus-event feedback loops. The default `aurora` border style interpolates pink, violet, and teal across
each window, with rounded floating corners. Inactive gradients are muted;
hovering a draggable edge brightens it. Shared dividers use the focused
neighbor's gradient when adjacent to focus. `COMPO_BORDER_STYLE=plain` restores
the original cyan/gray colors and square corners. Window labels remain pending.

`src/input.zig` incrementally frames outer CSI and SS3 key sequences, SGR mouse
reports, focus reports, and bracketed paste. Application-mode arrows stay intact
across reads. A 50 ms timeout forwards only a standalone Escape, even if another
shell continuously emits output; it never flushes a started CSI/SS3 sequence or
runs ahead of already-readable input. The compositor always requests
SGR mouse motion and bracketed-paste reports so borders can react to hover. Clicks focus windows; captured drags and
releases remain with their starting window. Mouse positions become local to
that window, clamped at its edges during capture. Mouse events reach only children
that requested them, with SGR cell, SGR pixel, or legacy encoding according to the child's mode.
Mode 1016 reports use pane-local cell centers because outer input currently
uses cell coordinates; subcell mouse precision is not yet retained.

Ordinary key bytes go to the focused child. Cursor-key mode follows that child.
Focus reports go only to children requesting them. Paste contents bypass the
compositor shortcut, and bracket markers are removed for children that do not
request bracketed paste. Extended Kitty keyboard negotiation, extra mouse formats,
OSC8 hyperlinks, palette updates, and cursor shapes remain to be completed.

The host reads cell and pixel dimensions from TIOCGWINSZ and resizes each child
PTY to its own layout rectangle on SIGWINCH. If pixel dimensions are unavailable, it does not invent them;
image placement output waits for measured dimensions. Terminal mode restoration
and alternate-screen exit happen on child exit, errors, SIGTERM, SIGHUP, and
SIGINT. The shell's exit status is returned. SIGKILL cannot run cleanup.

## Kitty graphics boundary

Decoded RGB and RGBA pixels, including PNG input decoded by the adapter, are
uploaded with compositor-owned image IDs. Each renderer allocates a disjoint
sequence of image IDs, so identical IDs in child applications cannot collide.
The renderer emits its own placements
and never forwards raw application APC graphics commands. Unchanged image data
and placements stay unchanged during text-only redraws. Changed/deleted images invalidate uploads;
exit explicitly deletes the host's remaining image IDs.

The initial renderer handles ordinary pinned placements fully contained in a
visible rectangle, with source crops, cell sizing, pixel offsets, and z-order.
It suppresses partially clipped placements rather than drawing outside the
window. Relative placements, virtual Unicode placements, animation scheduling,
and partial-image clipping are not implemented yet. This is not complete Kitty
protocol conformance. The outer terminal must support Kitty graphics; capability
probing and non-Kitty fallback are still pending.

The default host has two shells. Set `COMPO_FLOAT=1` to start a third shell in
an opaque floating rectangle, initially centered in the main area. For example:

```sh
COMPO_FLOAT=1 ./zig-out/bin/compo
```

Click the float to focus it; Ctrl-] then Tab cycles visible shells. Ctrl-] then
`f` hides or shows the float without restarting it, returning focus to the
previous shell when possible. Option-left-drag inside the float moves it.
Drag any floating border with a normal click to resize that edge only, keeping
its opposite edge fixed. Corners resize both adjoining edges and hold the
opposite corner fixed. A corner handle extends two columns along the horizontal
border and one row along the vertical border; it does not cover application
content. Hover replaces the corner glyph with a diagonal arrow (↖ ↗ ↙ ↘).
The sidebar and main shell share one draggable divider that changes their widths
together without changing keyboard focus. Its color reflects focus in either
adjacent terminal. Hovering
a draggable edge brightens that edge within its active/inactive color scheme.
Option-right-drag inside a float resizes its bottom-right corner.
Control-Option-left-drag moves it without docking. Shift-Option is not a compositor gesture,
since the outer terminal uses it for rectangular selection. On macOS, Alt is
Option. The outer terminal must forward modified mouse
events. These gestures are consumed by the compositor; ordinary mouse events
still go to the child. `COMPO_FLOAT_COMMAND` optionally supplies its command.
`COMPO_SINGLE` takes precedence over the floating-shell option.

Docks reserve tile space. Floats can move across the full screen; stacking
still determines visibility where they overlap an always-on-top dock.
Moving does not resize the child or send SIGWINCH; changing its size does.
Layout changes repaint exposed content, and an obscured background cursor stays
hidden. Terminals have one-cell box borders; the main shell uses the sidebar divider as
its left border. PTY dimensions exclude decorations, and input coordinates are
relative to the content area. Borders receive no application input. Tiny windows
under three rows or columns omit borders to preserve usable content. Closing the float
restores the same underlying shells. If only the floating shell remains, it
becomes a visible full-root tile. The final exit status still comes from the main
shell. Controller sidebars and reconnectable attachment remain pending.

Partially covered Kitty images are currently suppressed in full and restored
when fully visible again. Pixel-accurate partial-image clipping remains pending;
this first floating-shell experiment does not complete graphics composition.

## Checks

`mise run test` includes renderer round-trips through a second libghostty-vt
terminal, checking visible Unicode text, style, cursor-key mode, image bytes,
placement rebuilding, deletion, and upload reuse.

`mise run test-host` exercises real disposable PTYs. It checks input, a resize
observed through the child's `stty size`, nonzero exit status, Kitty output with
remapped IDs, and tty restoration after normal exit and SIGTERM. Darwin's
transient PENDIN flag is excluded from the mode comparison; all configured
flags and control characters are compared.

The two-shell tests additionally check shortcut and click focus, fragmented mouse
reports, local mouse coordinates, drag capture across the wall, literal shortcut
bytes inside pasted text, terminal replies returning to the right child, separate
outer image IDs and positions, resizing, and survivor expansion after dock exit.

The integration checks verify terminal bytes and lifecycle, not visual output
in every terminal emulator. macOS is the tested host platform so far.

The TUI host check measures acknowledged 160×50 styled redraws with an output-byte
budget, then opens Vim in the main tile, scrolls, edits, and saves a disposable
file. Timing is reported rather than asserted because host speeds differ.

A counting-allocator regression checks that warmed, fixed-size text updates
perform no allocations or frees, including an explicit repaint. Screen growth,
new styles or images, and layout changes may still require allocations.

`tests/floating_host.py` checks floating-shell focus, intercepted drag gestures,
PTY resizing, movement without SIGWINCH, hide/reveal, and close.
`tests/window_navigation.py` checks free movement to every screen corner across
dock reservations and Tab raising/repainting a covered idle float.
Renderer tests round-trip occlusion and restoration of text and image placements.

`tests/borders_host.py` checks hover highlighting, each anchored float edge,
interception of border gestures, and the shared sidebar/main resize divider.

## Diagnostics

Library warnings do not write onto the live composed display. When stderr is a
terminal, the host buffers up to 16 KiB and prints diagnostics after restoring
the terminal on exit. Extra diagnostics are dropped with a notice. Redirect
stderr for immediate logging: `./zig-out/bin/compo 2>/tmp/compo.log`.
This isolates diagnostics; it does not add support for unimplemented protocols.

Warnings about `CSI > p` and Kitty queries without dimensions can come from
application capability probes. Those warnings do not disable mouse reporting.
`COMPO_TRACE_MOUSE=1 ./zig-out/bin/compo 2>/tmp/compo-mouse.log` records button
events, window routing, mouse modes, and forwarded pane coordinates. It does not
record keystrokes or terminal contents, and skips hover motion. Without stderr
redirection, these trace records are also deferred until exit and share the
bounded diagnostic buffer. This distinguishes missing outer-terminal events
from events consumed by selection, scrollback, or application mouse routing.
Motion with a held button but no captured press is normalized to no-button hover
and logged as an orphan drag. This preserves border highlighting and application
hover without inventing a drag. Modifiers and drags that start inside a child
retain their original meaning.

`compo --help` and `compo -h` describe startup and shortcuts without opening a
terminal. `compo ctl --help` and `compo ctl -h` describe the control client.

Drop previews blend a 25% gray-blue tint into retained cell foreground and
background colors, preserving text, Unicode graphemes, and style attributes.
Moving or cancelling restores the original colors without requiring child output.
Palette colors use the embedded VT palette. Until outer-terminal default colors
are queried, defaults use the embedded VT colors, initially black and white.
Borders retain focus colors. Kitty images remain visible and untinted; image
alpha composition and general translucent windows remain future work.

### Reloading a startup layout

Press **Ctrl-] r** to reread the original startup script and rebuild its windows.
The selected path is stored as an absolute path; the compositor retains its
original working directory. Edit the script, then reload to try a new layout.

Reload first runs `/bin/sh -n` asynchronously. Missing/unreadable scripts and
syntax errors leave existing windows intact. After validation, all existing
windows close and the script runs again against the same control socket. Direct
programs are stopped; tmux clients reconnect when the script launches them.
Changes made interactively to the layout are not saved.

A runtime failure leaves compo open with any windows created so far and a
`[ reload failed ]` notice. There is no rollback after window replacement.
Detailed diagnostics follow the normal stderr logging policy. A second reload
is rejected while a startup script or validation is running. With no init script,
the shortcut shows `[ no startup script ]`.

`compo ctl startup` shows the script path, original directory, and phase.
`compo ctl reload` requests the same asynchronous reload as the keyboard shortcut.

### Known quirk: tmux session selection with tmm

A layout that starts tmm alongside plain `tmux attach` can alternate between
tmux sessions on successive reloads. Untargeted attach prefers unattached
sessions before comparing recent activity. Tmm currently creates two tmux
control-mode clients; those count as attachments and affect session activity.
Consequently, plain attach is not a reliable way to restore the visible
client's previous session.

This was reproduced on an isolated tmux server with three sessions and the
actual tmm binary: the visible client selected `a`, `c`, `a`, `c` across four
starts. Waiting for both tmm control clients before starting the visible client
still reproduced it. Testing the reverse order also alternated. Merely changing
window creation order or adding an attachment readiness signal does not solve
the session-selection issue.

For now, the local `x/current-layout.sh` experiment starts tmm first and uses
plain `tmux attach`; no session-preservation workaround is implemented in compo.
Investigation of the control clients' effect belongs in tmm. An explicit
`tmux attach -t SESSION` avoids automatic selection, but pins a session rather
than remembering the user's latest choice. Any future session-restoration
mechanism must also handle the remembered session disappearing before attach.

### Startup title

Startup shows a centered COMPO tile-art modal over either an empty desktop or
a scripted layout. Tiles settle into place over 700 ms. Any key or click
dismisses it with a short 280 ms drift-and-fade; the dismissal input, paste, and
mouse release do not reach the underlying shell. Hover alone does not dismiss.
The modal has no startup help text. Reload replays the animation after the
script passes validation. `--no-title` skips it on startup and reload.

Children continue running while the modal is visible. Terminal content is
subdued and clipped around the panel; it is restored when the panel closes.
Animation stops completely once the title settles. Small terminals use a
centered `compo` wordmark.

`src/title.zig` contains the tile rectangles, glyph contours, palette, half-cell
rasterizer, and entrance/exit animator, ported from the supplied
`x/ansi-art/compo.py`. There are no embedded image files or runtime Python
dependencies. The modal is a display/input overlay, not a managed PTY window.


### Prefix configuration

The default prefix is Ctrl-]. Set `COMPO_PREFIX=ctrl-]` or launch with
`compo --prefix ctrl-]` to change it. The command-line option overrides the
environment variable. `C-]` notation is also accepted. Key names are case-insensitive, so
`ctrl-]`, `Ctrl-]`, and `CTRL-]` all work.
Help (`compo --help`) shows shortcuts using the selected prefix. Shortcut
examples elsewhere in this document use the default.

Supported keys are Ctrl-a through Ctrl-z and Ctrl-@, Ctrl-\, Ctrl-], Ctrl-^,
and Ctrl-_. Ctrl-[ (Escape) is reserved for terminal escape sequences.
Control keys share bytes with some ordinary keys: Ctrl-i is Tab, Ctrl-m is
Enter, and Ctrl-h is Backspace on some terminals, so choose with care.
Press the configured prefix twice to send it literally to the child. Prefix
bytes inside bracketed paste pass through unchanged. Prefix configuration is
read at process startup; reloading the layout does not change it.


### Window shortcuts and help

Prefix `/` or `?` toggles a compact help panel in the top-right. Escape or an
outside click dismisses it without sending dismissal input to the shell.
Its binding descriptions come from the input dispatch table and show your
configured prefix. Children continue running behind the panel.

Prefix `1` through `9`, then `0`, focuses and raises windows numbered 1 through
10 within their existing layers. Prefix `n` toggles muted, centered `[1] name`
labels on the borders. Labels remain enabled until toggled off. Names that
cannot safely be displayed as ASCII are omitted from labels.

Each new window takes the lowest free number, or remains unnumbered if all ten
are assigned. Closing a window frees its number without renumbering others.
Numbers survive moves, docking, and focus changes. Startup scripts can choose
stable numbers with `compo ctl create --tile --name main --number 1`.
`ctl list` reports both `name` and `number`; `null` means unnumbered. Duplicate
names/numbers and numbers outside 1–10 are rejected before launching a child.
The number 10 uses the `0` shortcut and `[0]` label. Prefix shortcuts are
consumed while help is open, except the help shortcut itself.
