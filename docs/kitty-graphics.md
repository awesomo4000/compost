# Kitty graphics audit

Inspected tmux baseline: `a864c419900182fe624abf73db72ae6f1b0ab9a5`.
This is a code audit and targeted baseline test, not a full conformance verdict.

## Existing implementation

Image support is optional. The first build had it disabled. The audit rebuilt
from clean objects with `--enable-images`; libpng and zlib were found. Changing
configure flags without cleaning left stale objects, so a clean rebuild is
required when switching this feature.

`image-kitty.c` accepts direct uploads, chunking, raw RGB/RGBA, PNG, compression,
queries, ordinary placements, cropping/scaling parameters, and some deletions.
The image store/grid and SIXEL or text fallback can display supported uploads.

However, `kitty_select` always returns zero, and the Kitty backend in
`image-grid.c` has no draw callback. There is no working native Kitty output
backend in this checkout. Successful input parsing is not native Kitty output.

| Feature | Code finding |
| --- | --- |
| Direct image transmission | Implemented subset, with raw/PNG decoding and chunking. |
| Native Kitty output | Stub backend, never selected. |
| Unicode placeholders / virtual placements | Nonzero U is rejected. |
| Relative placements | Nonzero P/Q/H/V are rejected. |
| Nonzero z-order | Rejected. Default-layer image composition exists. |
| Image numbers | Nonzero I is rejected. |
| File, temporary-file, shared-memory transport | Any medium other than direct is rejected. |
| Animation / frame composition | Actions f/a/c are rejected. |
| Deletion selectors | Only a/A/i/I accepted; the rest need implementation. |

The official protocol also defines storage, response, reset, alternate-screen,
scrolling, and clipping behavior. Completing a feature list must include those
interactions, malformed input, and resource limits, not just accepting keys.
Reference: https://sw.kovidgoyal.net/kitty/graphics-protocol/

## Tests run

After the clean image-enabled build, these upstream regressions passed on this
Mac using disposable sockets and files in fresh `/tmp` directories:

- `image-kitty-protocol.sh`
- `image-kitty-decode.sh`
- `image-kitty-placements.sh`
- `image-kitty-lifecycle.sh`

Some tests assert ENOTSUP for unsupported features. Passing them establishes the
current subset's behavior, not complete Kitty support. No real Ghostty/Kitty
rendering conformance run was performed in this audit.

## Implementation direction

Prefer adapting tmm's libghostty-vt integration before independently implementing
all missing Kitty semantics in tmux's parser. Audit the selected libghostty-vt version
and its exposed API too. tmm's PNG, virtual placement, relative placement, and
pixel-size tests are valuable starting cases, not proof of complete support.

The output side needs terminal capability detection, per-client image IDs and
upload caches, placement translation/clipping, layer ordering relative to text
and tmux UI, image removal and reattach replay, and animation scheduling or
faithful animation forwarding. Cache source data separately from terminal uploads.

Use the same terminal abstraction for normal panes and the static sidebar.
Their graphics must coexist without ID collisions or deletion of each other's
images. Preserve pane history and hidden images independently of client lifetime;
the first sidebar implementation may discard its own state on detach.

For file/shared-memory transports, resolve resources where the application runs,
not by forwarding paths to a remote outer terminal. Apply protocol rules and
bounded reads. Every filesystem/deletion test must use dedicated disposable
`/tmp` fixtures, assuming protections could fail.

Full conformance should be pinned to a dated protocol reference and tested
feature by feature, including queries and errors, chunk boundaries, all delete
selectors, virtual and relative placements, alpha/layers, animation, history,
alternate screens, resize, detach/reattach, nested tmux, SSH, and multiple clients
with different sizes/capabilities. Keep a distinction between protocol parsing,
internal state, and correct visible output.
