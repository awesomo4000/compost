# Terminal adapter

`src/terminal.zig` owns one libghostty-vt terminal and stream per surface. The
geometry library does not import it. The host will associate window IDs with
surface pointers and apply layout results through `applyBounds`.

Surfaces are heap-pinned because the library stream borrows the terminal address.
Use `Surface.create` and `destroy`; do not copy a surface value. The adapter is
single-threaded, including its initialization of the library-wide PNG decoder.
The decoder uses the Wuffs module already shipped in the pinned library's build.

Feed child output through `feed`. Protocol replies go to the surface's `Sink`.
The sink must consume or copy bytes before returning. Write failures are latched
and returned to the host rather than silently discarding subsequent replies.
Terminal semantic failures are also exposed. The host must decide how to recover
or close a failed surface; feeding is not a transactional operation.

The optional status callback receives borrowed OSC 7501 reports synchronously.
Installing it also enables the library's support-query response. This is an event
hook, not yet a controller's persistent agent-status model.

`applyBounds` maps abstract integer extents to terminal rows and columns for the
initial cell-aligned host. Moving leaves the terminal unchanged. Resizing uses
the library handler so negotiated mode-2048 size replies are emitted. A window
with zero area retains its previous terminal size. Pixel geometry comes from the
host; zero means unknown, and size queries are suppressed until it is measured.
The replay uses explicit synthetic cell dimensions.

Each surface retains current screen state, modes, alternate buffers, and up to
16 MiB of Kitty image storage. User scrollback is disabled. The focused tests
cover split UTF-8 input, alternate screens, moves and resizes, cursor and size
replies, raw RGB images, chunked PNG decoding, placements and deletion, independent
surfaces, OSC 7501 callbacks, and sink failures.

## Current boundary

`mise run demo-vt` feeds a deterministic byte stream and prints retained text and
image presence. It does not draw the image in the outer terminal. This proves
the terminal-state boundary while keeping it separate from process hosting.

The [shell host](shell-host.md) now connects two surfaces to separate PTYs and
renderers, with keyboard focus and translated mouse input. It draws retained
styled cells and fully visible pinned Kitty images with independent outer image
IDs. Complete image clipping remains future work. Passing Kitty input tests does not establish
end-to-end graphics conformance.
