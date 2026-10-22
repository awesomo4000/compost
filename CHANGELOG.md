# Changelog

## 10/22/2026

- Added four corner resize handles with larger border hit areas and diagonal hover arrows; each resizes two edges while preserving the opposite corner. Fixed shared-divider dragging to preserve keyboard focus and use the active adjacent terminal border color.

- Added terminal borders with reserved content space, focus colors, and brighter hover feedback on draggable edges. Float-border dragging resizes only that edge; one shared divider resizes sidebar/main widths. Option-drag inside a float moves it. Removed Shift-Option resizing to preserve terminal rectangular selection. Added border rendering and interaction tests.

- Added Control-Alt-left-drag and Alt-Shift-left-drag as trackpad-friendly floating-window resize gestures, retaining Alt-right-drag.

- Added an opt-in third floating shell with click/cycle focus, hide/reveal, Alt-drag movement and resizing, dock constraints, and restoration of covered text and fully visible Kitty images. Moving preserves PTY dimensions; resizing updates them. Added floating-shell integration and renderer occlusion tests. Kept macOS as the active development target.

- Recorded the release policy: retain SIMD, ship static musl Linux executables with broad kernel/CPU compatibility, require only built-in Windows DLLs, and allow macOS libSystem. Require explicit platform baselines and clean-system validation.

- Replaced the C PTY host with Zig, using platform libc types and direct Zig compositor calls. Preserved raw-mode restoration, signal handling, shell startup, resizing, polling, and child cleanup; removed the C source build step.

- Retained renderer frame, scratch, and row-cache storage across updates, cached visibility regions, and removed the frame copy before host output. Added a counting-allocator regression for allocation-free warmed text redraws and repainting.

- Accelerated TUI rendering with contiguous text/style runs, libghostty-vt dirty-row tracking and stable row identities, a reusable encoding buffer, and pooled host allocations. Added incremental scrolling/style round-trips, an acknowledged full-screen redraw benchmark, and a real Vim editing test.

- Fixed redraw/focus-report feedback in the two-shell host. Outer input modes now belong to the host; unchanged surfaces, rows, and image placements are skipped, and only layout changes clear the screen. Added a PTY regression for focus feedback and typing without sidebar repainting.

- Added a live left dock and main shell with separate PTYs, Ctrl-] Tab and click focus, per-window mouse coordinates, drag capture, paste isolation, and independent graphics IDs. Closing either shell expands the survivor. Kept TMUXPP_SINGLE=1 for the original layout and added two-shell PTY tests.
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
