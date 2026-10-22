# Interactive shell host

`mise run shell` opens an empty desktop. Ctrl-] Enter creates a floating shell,
using `$SHELL` or `/bin/sh`. Up to 32 shells can run. Closing the last shell
returns to the desktop; Ctrl-] q closes all children and quits.

Option-left-drag moves a float. Option-dragging a tiled or wall border pulls it
out after a small movement threshold, restoring its remembered floating size.
Drag near a workspace edge to split the whole tiled area. Over an existing
tile, broad left/right/top/bottom zones split that tile; the central 40% in both
dimensions leaves the window floating. The outer workspace band takes priority. A muted gray-blue rectangle previews the destination. The first edge drop
occupies that half of the desktop; adding another tile fills the tiled area. Release commits;
Escape restores the original layout. Each split starts at 50/50. Hold Control
during the move to create a wall at a workspace edge instead. Walls reserve one
third of the available dimension. Existing shells retain their PTYs and IDs.
The preview does not resize neighbors until release. Tiles share one border. Drag a shared vertical or horizontal divider to resize
both sides without changing focus. Nested splits resize within their parent;
Escape cancels. Float edges/corners and the legacy left sidebar divider also
support dragging. Four-sided wall resizing remains future work. The preview consumes no window slot.

Click or Ctrl-] Tab focuses a window. Ctrl-] twice sends a literal Ctrl-].
The user's tmux prefix passes through. Ctrl-] f toggles a floating window.

`TMUXPP_LEGACY=1` starts the original left dock and main tile. `TMUXPP_SINGLE=1`
starts a single full-root shell; `TMUXPP_FLOAT=1` adds the third floating shell.
These legacy layouts exit when their children close and return the main shell's
status. `TMUXPP_COMMAND`, `TMUXPP_SIDEBAR_COMMAND`, and `TMUXPP_FLOAT_COMMAND`
provide fixture commands. `TMUXPP_DESKTOP=1` forces empty-desktop startup even
when those variables are set. In desktop mode each new shell uses TMUXPP_COMMAND
if provided. Desktop quit returns zero.

`zig build` installs `zig-out/bin/tmuxpp-shell` and both demos.

The window model remains terminal-independent. `src/shell.zig` connects it to
the terminal adapter and renderer. `src/host.zig` handles POSIX PTYs, tty modes, polling, signals, and child cleanup.
It uses standard-library platform definitions and calls libc directly for OS
services; the compositor/host interface uses ordinary Zig functions and slices.
There is no project-owned C host source or header translation step. It contains
no layout or terminal-emulation logic. Native Windows hosting remains future work.

## Display and input

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
focus reporting enabled across frames to avoid focus-event feedback loops. Focused borders are cyan; inactive borders are gray. Draggable edges brighten
on hover. Window labels remain pending.

`src/input.zig` incrementally frames outer CSI sequences, SGR mouse reports,
focus reports, and bracketed paste. A 50 ms timeout forwards a standalone Escape
even if another shell continuously emits output. The compositor always requests
SGR mouse motion and bracketed-paste reports so borders can react to hover. Clicks focus windows; captured drags and
releases remain with their starting window. Mouse positions become local to
that window, clamped at its edges during capture. Mouse events reach only children
that requested them, with SGR or legacy encoding according to the child's mode.

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

The default host has two shells. Set `TMUXPP_FLOAT=1` to start a third shell in
an opaque floating rectangle, initially centered in the main area. For example:

```sh
TMUXPP_FLOAT=1 ./zig-out/bin/tmuxpp-shell
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
Control-Option-left-drag inside a float resizes its bottom-right corner;
Option-right-drag is also available. Shift-Option is not a compositor gesture,
since the outer terminal uses it for rectangular selection. On macOS, Alt is
Option. The outer terminal must forward modified mouse
events. These gestures are consumed by the compositor; ordinary mouse events
still go to the child. `TMUXPP_FLOAT_COMMAND` optionally supplies its command.
`TMUXPP_SINGLE` takes precedence over the floating-shell option.

The dock acts as a wall. Floats stay inside the remaining usable rectangle.
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
PTY resizing, movement without SIGWINCH, wall constraints, hide/reveal, and close.
Renderer tests round-trip occlusion and restoration of text and image placements.

`tests/borders_host.py` checks hover highlighting, each anchored float edge,
interception of border gestures, and the shared sidebar/main resize divider.

## Diagnostics

Library warnings do not write onto the live composed display. When stderr is a
terminal, the host buffers up to 16 KiB and prints diagnostics after restoring
the terminal on exit. Extra diagnostics are dropped with a notice. Redirect
stderr for immediate logging: `./zig-out/bin/tmuxpp-shell 2>/tmp/tmuxpp.log`.
This isolates diagnostics; it does not add support for unimplemented protocols.

Drop previews blend a 25% gray-blue tint into retained cell foreground and
background colors, preserving text, Unicode graphemes, and style attributes.
Moving or cancelling restores the original colors without requiring child output.
Palette colors use the embedded VT palette. Until outer-terminal default colors
are queried, defaults use the embedded VT colors, initially black and white.
Borders retain focus colors. Kitty images remain visible and untinted; image
alpha composition and general translucent windows remain future work.
