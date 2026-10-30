# Changelog

## 10/30/2026

- Make the compositor prefix configurable with --prefix or COMPO_PREFIX, retaining Ctrl-] by default. Help labels and literal-prefix forwarding use the configured key.

## 10/29/2026

- Rounded both title-art o glyphs with symmetric outlines and counters at every supported size, and balanced the c top and bottom. Successful reload validation now replays the title animation; --no-title skips both startup and reload animation.

- Added a procedural Zig COMPO title modal over empty and scripted startups, without startup help. Tiles settle on entry and drift/fade on dismissal; consume dismissal input, clip underlying terminal content, and restore it afterward. Added --no-title, compact wordmark fallback, and idle animation suppression.

- Documented session alternation when reloading layouts with tmm and untargeted tmux attach. Reproduced with real tmm even when its control clients attach before the visible client; left resolution for tmm investigation.

- Added Ctrl-] r and control-socket startup metadata/reload commands. Remember the absolute init path and launch directory, check shell syntax before replacing windows, and keep the compositor available on reload failure. Recorded a shared startup/help modal on Ctrl-] ? or /.

- Keep outer cursor visibility and shape stable across redraws, forwarding changes only when needed. Honor per-window synchronized updates with a one-second timeout; layout/focus changes cancel pending holds so geometry remains responsive. Added a real-PTY regression for fragmented updates, independent panes, visibility, shape, and timeout recovery.

## 10/28/2026

- Added xinitrc-style startup scripts, explicit --init/--no-init options, live-name targeting, and quiet control commands. Scripts arrange windows over the ready control socket without a bootstrap pane; failures report bounded diagnostics and clean up the desktop.

- Keep application-mode arrows and other SS3 keys intact across input reads. Limit idle flushing to standalone Escape and check input readiness first, preventing partial keys from exiting tmux copy mode or leaving stray arrow letters. Added fragmented/repeated-key and real-tmux copy-mode regressions.

- Preserve border and application hover when the outer terminal reports held-button motion without a captured press. Normalize these events to no-button hover instead of dropping them; retain modifiers and genuine drag gestures.

- Ignore held-button motion without a captured press so all-motion mouse clients cannot acquire an orphan drag that consumes their next click. Added a real-tmux reproduction for this failure.

- Added main and control-client help flags, opt-in button-routing diagnostics with COMPO_TRACE_MOUSE, and an isolated real-tmux regression for single-click pane switching without clipboard output.

- Added native `compo ctl` window commands and persistent NDJSON streaming. Added tiled placements with target, edge, and ratio; float/tile conversion; neighboring PTY resize; and per-window commands that leave an interactive shell.

- Renamed all legacy startup environment variables to use the COMPO_ prefix. Updated the host, PTY fixtures, and usage examples.

- Documented and tested startup commands that leave an interactive Bash shell using an exec handoff. Recorded startup layout scripts and numbered pane selection with Ctrl-] , on the roadmap.

## 10/27/2026

- Merged scrollback and copy/paste onto main. Added short-lived muted teal copy/paste character counts in each window top border, including shared dividers. Track bracketed paste across input chunks and keep it targeted at its starting window.

- Added bounded per-window scrollback, shell wheel browsing, and Ctrl-] [ history mode using libghostty-vt viewport state. Keep mouse-aware application wheel input intact and return to live output on typing outside history mode.

- Fixed plain focus clicks creating a one-cell selection. Selection now starts only after dragging to a different cell.

- Added pane-local drag selection and explicit Ctrl-] y copy through the outer terminal clipboard using OSC 52, including over SSH where supported. Ctrl-] c enables selection for mouse-aware apps. Keep application clipboard effects disabled and preserve normal bracketed paste.

- Added muted teal inactive terminal cursor highlights. Cursor-only output moves the marker and restores the old cell; focus and cursor visibility changes remove it. Preserve underlying text and clip markers behind other windows.

## 10/23/2026

- Fixed floats being constrained by sidebar reservations. Alt-Control-left-drag now moves without docking or resizing, and Ctrl-] Tab raises and redraws the selected window within its layer. Border resizing remains available.

- Connected the control socket to window list/get/create/place/focus/raise/lower/close operations, with stable instance/window references, named PTY children, launch failure reporting, exact floating placement, numeric layers, and a fixed-size headless host. Added lifecycle and layer tests. Changed the blank desktop logo to `compo`.

## 10/22/2026

- Added the first persistent control-protocol slice: private per-instance Unix sockets, version negotiation, ping, bounded nonblocking multi-client I/O, child socket discovery, and normal-exit cleanup. Added protocol and real-PTY connection regressions. Window control remains the next development stage.

- Added the default aurora border style with a pink/violet/teal RGB gradient, rounded floating corners, muted inactive windows, and brighter hover handles. Shared dividers follow adjacent focus. Retained the original style through `COMPO_BORDER_STYLE=plain`.

- Renamed the compositor executable to `compo`; updated build output, documentation, and PTY tests.

- Fixed mouse forwarding for applications that negotiate SGR pixel mode 1016, including Vaxis/tmm. Translate outer cell reports into pane-local pixel coordinates while preserving hover, wheel, release, and drag capture. Added a Vaxis-style negotiation regression.

- Replaced opaque drop previews with a 25% tint over retained cell colors. Preserved text, Unicode, styles, and original colors on movement/cancellation. Kitty images remain visible and untinted. Removed the extra preview window and added renderer restoration and image-retention tests.

- Added broad directional drop zones within tiles, with workspace-edge priority and a central floating-placement area. Tiles now share borders with connected junctions; dragging a divider resizes both sides, preserves keyboard focus, and supports Escape cancellation.

- Buffered dependency diagnostics while stderr is a terminal so unsupported VT probes cannot overwrite composed windows. Flush diagnostics after restoring the terminal; redirected stderr still receives logs immediately. Added a PTY regression covering the startup warnings and Kitty error-reply routing.

- Fixed the first edge drop to occupy the selected half of the desktop instead of filling the screen. Replaced the saturated blue docking preview with a muted gray-blue shade.

- Added an empty desktop, Ctrl-] Enter shell creation, Ctrl-] q shutdown, and reusable PTY slots. Added drag-to-tile previews, nested target splits, reserved wall drops, Option-drag undocking with remembered floating sizes, and Escape cancellation. Layout changes preserve running children. Kept the earlier layouts behind environment options and added geometry and desktop PTY regressions.

- Added four corner resize handles with larger border hit areas and diagonal hover arrows; each resizes two edges while preserving the opposite corner. Fixed shared-divider dragging to preserve keyboard focus and use the active adjacent terminal border color.

- Added terminal borders with reserved content space, focus colors, and brighter hover feedback on draggable edges. Float-border dragging resizes only that edge; one shared divider resizes sidebar/main widths. Option-drag inside a float moves it. Removed Shift-Option resizing to preserve terminal rectangular selection. Added border rendering and interaction tests.

- Added Control-Alt-left-drag and Alt-Shift-left-drag as trackpad-friendly floating-window resize gestures, retaining Alt-right-drag.

- Added an opt-in third floating shell with click/cycle focus, hide/reveal, Alt-drag movement and resizing, dock constraints, and restoration of covered text and fully visible Kitty images. Moving preserves PTY dimensions; resizing updates them. Added floating-shell integration and renderer occlusion tests. Kept macOS as the active development target.

- Recorded the release policy: retain SIMD, ship static musl Linux executables with broad kernel/CPU compatibility, require only built-in Windows DLLs, and allow macOS libSystem. Require explicit platform baselines and clean-system validation.

- Replaced the C PTY host with Zig, using platform libc types and direct Zig compositor calls. Preserved raw-mode restoration, signal handling, shell startup, resizing, polling, and child cleanup; removed the C source build step.

- Retained renderer frame, scratch, and row-cache storage across updates, cached visibility regions, and removed the frame copy before host output. Added a counting-allocator regression for allocation-free warmed text redraws and repainting.

- Accelerated TUI rendering with contiguous text/style runs, libghostty-vt dirty-row tracking and stable row identities, a reusable encoding buffer, and pooled host allocations. Added incremental scrolling/style round-trips, an acknowledged full-screen redraw benchmark, and a real Vim editing test.

- Fixed redraw/focus-report feedback in the two-shell host. Outer input modes now belong to the host; unchanged surfaces, rows, and image placements are skipped, and only layout changes clear the screen. Added a PTY regression for focus feedback and typing without sidebar repainting.

- Added a live left dock and main shell with separate PTYs, Ctrl-] Tab and click focus, per-window mouse coordinates, drag capture, paste isolation, and independent graphics IDs. Closing either shell expands the survivor. Kept COMPO_SINGLE=1 for the original layout and added two-shell PTY tests.
- Added an interactive full-root POSIX shell host, retained-cell renderer, and basic Kitty image output with independent outer image IDs and upload reuse. Added installed binaries under zig-out/bin, renderer round-trip tests, and disposable-PTY checks for input, resize, child exit, graphics output, and terminal restoration. Interactive multi-window hosting and complete graphics composition remain pending.
- Integrated the pinned libghostty-vt archive through a content-hashed Zig dependency and added a terminal adapter separate from the geometry core. Added retained screen state, per-surface replies, OSC 7501 callbacks, resize reporting, and raw/chunked PNG Kitty image handling using the bundled Wuffs decoder.
- Added focused terminal tests and `mise run demo-vt`, a headless replay of text and image output. PTY shell hosting and outer-terminal rendering remain pending.

## 10/21/2026

- Pinned Zig 0.17.0 with mise and the package manifest. Downloaded and checksum-verified the latest standalone libghostty-vt release at f54340a, which also requires Zig 0.17.0. Added a read-only release and OSC embedder-hook watcher based on the checks used in tmm.
- Verified core tests in debug and safe modes and compiled both upstream libghostty-vt interface test suites with Zig 0.17.0. Recorded the shared upstream temporary-file test failure caused by its /tmp fixture location; the other 6,927 tests passed, with 56 skips across the two suites.
- Implemented the terminal-independent Zig geometry and window-management core with split-tree tiling, ordered docks, constrained floats, visibility regions, focus, and pointer capture. Added a headless layout demo and passed all nine tests with Zig 0.16.0. Terminal rendering and shell integration remain pending.
- Revised the design toward a standalone Zig compositor with a terminal-independent window-management core, docked walls, tiling, constrained floats, early Kitty graphics, and reconnectable display attachment. Supersedes the initial embedded-compositor plan.

- Adopted a per-client compositor design with docked and floating surfaces, asymmetric corner ownership, z-order, clipping, damage tracking, and input capture. Added an early overlapping-workspace proof to the implementation sequence.
- Specified a client-owned shell sidebar that survives window/session changes and restarts after detach/reattach, with ordinary controller programs running inside it.
- Mapped direct server access to the control-client machinery it replaces in tmm. Recorded tmm as code to copy/adapt selectively, not a dependency.
- Added libghostty-vt integration notes and a Kitty graphics gap audit. Clean-built with images enabled and passed four existing Kitty regressions; native Kitty output remains unimplemented upstream.
- Recorded longer-term Zig 0.17.0 build-system replacement and native Windows portability work.
- Updated the experiment config to load `~/.tmux.conf` first, retaining the user's Ctrl-a prefix, pane navigation, split bindings, and styling.
- Adopted the user's clean checkout in `vendor/tmux` at `a864c419900182fe624abf73db72ae6f1b0ab9a5`. It already includes native side status, superseding the initial geometry implementation plan.
- Archived the earlier root-level snapshot and build output under `/tmp/tmuxpp-original-baseline-2i3slw3m` and updated documentation to use the vendor checkout.
- Built the new baseline and added `config/sidebar.conf` for an isolated native-sidebar experiment. Verified configuration loading and the new-session binding.
- The earlier socket restriction was resolved by running isolated runtime checks with elevated permissions.
- Passed upstream sidebar rendering, mouse, resize, list scrolling, and terminal margin regressions on the vendor checkout. No upstream C changes were needed.
- Imported the tmux source snapshot at `48bbaa1172051a3c05626a588491429b9ca2ffc4`, verifying all 637 files against upstream Git blob hashes.
- Documented the client-owned sidebar design, geometry changes, implementation sequence, and verification requirements.
- Initially added local build and isolated launch instructions before discovering native side status in the newer checkout.
- Built the initial unmodified baseline successfully. Its first runtime smoke test was blocked by sandbox denial of Unix socket creation.
