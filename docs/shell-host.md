# Interactive shell host

`mise run shell` starts two independent shells: a left edge dock and a main tile.
The dock reserves up to 24 columns, capped at one third of the display width.
The main tile starts focused. On extremely narrow displays the dock can have
zero visible area while its shell retains its previous valid terminal size.
`zig build` installs `zig-out/bin/tmuxpp-shell` and both demos. The host uses
`$SHELL`, falling back to `/bin/sh`. `exit` and Ctrl-D use the shell's ordinary
behavior. When a shell closes, the survivor fills the root and receives focus.
The host exits when both close, returning the main shell's status.

Click a window or press Ctrl-] followed by Tab to focus it. Ctrl-] twice sends a
literal Ctrl-]. This leaves the user's tmux prefix available to tmux.
`TMUXPP_SINGLE=1` selects the original full-root shell layout. `TMUXPP_COMMAND`
supplies the main shell command for automated checks; `TMUXPP_SIDEBAR_COMMAND`
supplies the dock command. Without these variables, each runs an interactive shell.

The window model remains terminal-independent. `src/shell.zig` connects it to
the terminal adapter and renderer. `src/host.c` is a small POSIX bridge for
forkpty, tty modes, poll, signals, and child cleanup. It contains no layout or
terminal-emulation logic. Native Windows hosting remains future work.

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
focus reporting enabled across frames to avoid focus-event feedback loops. The cursor identifies focus; borders and window labels are pending.

`src/input.zig` incrementally frames outer CSI sequences, SGR mouse reports,
focus reports, and bracketed paste. A 50 ms timeout forwards a standalone Escape
even if another shell continuously emits output. The compositor always requests
SGR mouse and bracketed-paste reports. Clicks focus windows; captured drags and
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
uploaded with compositor-owned image IDs. The two renderers allocate disjoint
odd/even IDs, so identical image IDs in the child applications cannot collide.
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

The host currently has two fixed shell slots. It does not yet provide interactive
floats, dragging, controller sidebars, or reconnectable attachment.

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
