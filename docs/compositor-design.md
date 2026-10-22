# Standalone compositor design

## Architecture decision

Build a standalone compositor in Zig. It hosts terminal programs, eventually
including multiple tmux clients with separate controllers. The first runnable
milestone is a shell filling the root rectangle. The tmux fork remains available
for graphics and integration work; the compositor does not require tmux to test
its layout or run a shell.

This replaces the earlier plan to embed the initial compositor in tmux's server.
The sidebar and VT integration documents retain research for that earlier path.
They are references, not requirements for the standalone host.

## Window-management core

Keep geometry and window-management policy independent of terminals. The core
has no PTYs, escape sequences, terminal cells, libghostty-vt objects, tmux IDs,
or operating-system window handles. Implement it as a library that can be tested
without terminal I/O. A future C ABI can expose opaque handles and plain data
if the tmux fork needs to call it.

The model contains a root rectangle, stable window IDs, layout containers,
window bounds and size constraints, visibility, stacking order, focus, and
pointer capture. Content belongs to the host and is referenced by opaque IDs.
Moving a window never changes its content identity.

Use abstract layout units, signed positions, nonnegative extents, and half-open
rectangles. Keep coordinate conversion explicit. The terminal adapter supplies
an integer grid and snapping constraints; the core must not assume one unit is
a character or encode glyph widths. Define deterministic rounding and distribute
split remainders so children exactly cover their parent without gaps or overlap.
The initial implementation can use integral layout units without committing to
pixel-smooth movement or fractional scaling.

Commands such as add, remove, focus, move, resize, dock, and change root bounds
produce geometry and focus changes for the host to apply. The core never spawns
processes, writes output, or issues SIGWINCH. The host translates decoded input
into these commands and applies the results to content backends.

Separate rectangle/region algorithms, layout policy, and content integration.
Region intersection and subtraction support visible-region calculations and
invalidation of both old and new coverage. Hit testing follows stacking order;
pointer capture persists across window boundaries and is canceled on removal.

## Tiling, floats, and walls

Windows can be tiled, floating, or docked. Tiled windows receive rectangles from
a split tree. Floating windows have explicit bounds. Docked windows attach to
an edge of a layout container. All three use the same window identities.

Always-on-top and space reservation are independent properties. A sidebar
normally has both. An overlay may be on top without reserving space. Ordinary
floating windows are constrained to the remaining usable rectangle when moved,
resized, or when the root or docks change. Raising them does not raise them over
an always-on-top panel.

Start with edge docks that consume a strip from the remaining rectangle in a
defined order. This keeps the usable area rectangular. Docking the left edge
first gives it full height; docking the top first gives it full width. Nested
containers allow asymmetric corner ownership. Arbitrary interior obstacles and
nonrectangular content windows are outside the initial scope.

Define minimum-size failure behavior before implementing layout. When the root
cannot fit all requested sizes, return a constrained layout with explicit unmet
constraints, never negative dimensions or overlapping walls. The terminal host
must handle zero-area windows without passing invalid PTY sizes downstream.

## Terminal adapter and rendering

Each terminal surface owns a PTY/process and libghostty-vt terminal state. The
adapter translates layout bounds into terminal dimensions, mouse coordinates,
and renderer clipping. libghostty-vt is the emulation library, not the Ghostty
GUI application and not the compositor renderer.

Retain each surface's current screen, modes, and image data for repainting.
Tmux continues owning its sessions, panes, applications, and user scrollback.
The compositor does not need a second user-facing scrollback for a tmux client.
Hidden terminals continue consuming output.

The renderer uses the core's visible regions for text, images, decorations,
selection, and the focused cursor. Moving or restacking invalidates old and new
coverage. Begin with opaque rectangles and repaint from retained content.
Optimized scroll, erase, or passthrough operations are allowed only when their
entire effect stays within the correct visible region.

Kitty graphics belongs in the first terminal rendering design and tests. Track
image data independently of outer-terminal upload IDs, clip placements, remove
occluded placements, and restore exposed images. An upper opaque text window
must cover lower images. Raw graphics passthrough must not bypass composition.
Library support alone does not establish end-to-end protocol support; maintain
a capability matrix for emulation, rendering, and the outer terminal. A tmux
client inside a surface also depends on that tmux version's graphics handling.

## Controllers and reconnect

Two surfaces can run two independent tmux clients. Sidebars target the appropriate
server socket and client identity. An aggregate controller can query multiple
configured servers. These bindings belong to controllers, not the geometry core.
Preserve ordinary tmux keybindings when forwarding input to a tmux client.

The remote compositor process can outlive its display connection, keeping its
child PTYs alive. Reattachment supplies new display dimensions, restores input
and terminal modes, repaints retained screens, and reuploads graphics. Layout
and focus stay in the running process. Persistence across process restart is a
separate feature.

dtach is a candidate initial attachment transport. Its redraw request must cause
a complete display restoration; it does not itself retain terminal screens.
A reconnectable host and transport adapter must handle this without adding
attachment or SSH knowledge to the window-management core.

## Implementation order and acceptance

1. Implement the independent geometry and window model with headless tests.
   Cover docking order, tiling partitions, constrained floats, stacking, focus,
   capture, visibility subtraction, root resize, and impossible size constraints.
2. Run one shell in a full-root libghostty-vt surface. Establish Kitty image
   rendering and redraw behavior here, alongside text and input.
3. Add docked shells and tiled terminals. Verify corner ownership and preserve
   process identity across layout changes.
4. Move a floating terminal over scrolling text and images. Verify clipping,
   exposed content, input coordinates, and cursor visibility. Moving must not
   resize the child; resizing must update it.
5. Exercise display disconnect and reconnect with retained child processes,
   changed outer dimensions, restored input, and fresh graphics uploads.
6. Run multiple tmux clients and add targeted and aggregate controllers.

Use synthetic content for core tests. Add terminal integration tests for Unicode
at clip edges, alternate screens, synchronized output, graphics occlusion,
child exit, and reconnect during pointer capture. Use disposable /tmp fixtures.
Adapt useful tmm code selectively; tmm is a reference, not a dependency.

The initial geometry and window-management core is implemented in `src/core.zig`
and `src/geometry.zig`, with headless tests and a static layout demo. A separate
`src/terminal.zig` adapter retains VT state and decoded Kitty images. The initial
[shell host](shell-host.md) starts with an empty desktop and creates floating
shells on demand. Drag previews support nested tiles and reserved walls;
Option-drag undocks and Escape cancels. Running shells keep their PTYs across
layout changes. Borders, resizing, independent focus, and basic Kitty placements
are implemented.
Full graphics composition and reconnect remain pending. See
[core API notes](core-api.md) for the current implementation's limits.
