# Testing upgrades

Status: proposed, 11/04/2026. Native Windows support comes before this refactor.

## Objective

Make most compositor behavior testable in memory with deterministic events and
an injected clock. Keep real OS integration tests for the contracts that a fake
cannot prove. Exercise the same production state transitions in both paths.

A passing suite means the implemented scenarios pass. It does not establish full
terminal-protocol conformance, compatibility with every outer terminal, or that
a clipboard request was accepted by the operating system.

## Current coverage

`zig build test` exercises geometry, nested tiling, docking previews, reserved
edges, floating windows, stacking, hit testing, visible regions, identity,
capacity/geometry rejection, fragmented input, prefix dispatch, terminal state,
Unicode, alternate screens, cursor updates, selection, clipboard callbacks,
image uploads/placements, modal occlusion, title animation, and renderer output.

Renderer tests feed emitted bytes into a second libghostty-vt instance and inspect
the reconstructed text, styles, cursor, and graphics state. This is a separate
terminal instance but not an independent terminal implementation. Shared bugs or
assumptions can therefore go undetected. Warmed text redraw tests also check
allocation reuse.

`mise run test-host` uses disposable PTYs, children, and Unix sockets to test
shell lifecycle, resize, signal handling, terminal restoration, routing, paste,
scrollback, borders, docking, focus, modals, numbered windows, startup scripts,
reload, control-client isolation, persistent connections, real Vim use, and tmux
clipboard forwarding. Separate tmux mouse/key tasks cover single-click focus and
fragmented/repeated application cursor keys. These tests capture terminal output;
they do not modify the user's actual desktop clipboard.

The complete unit and host suites plus tmux mouse/key tests passed on x86-64
Linux on 11/04/2026. Tests have also been developed and run on macOS. Native
Windows needs its own process, console, IPC, and shell integration coverage.

## Architecture for in-memory tests

Extract the state currently held in `shell.zig` globals into a compositor
instance. Give it explicit operations for input, child output, child exit,
root resize, control requests, and timer advancement. Retain the existing scene,
input decoder, VT adapter, renderer, and production command dispatcher.

Inject the boundaries:

- Clock: monotonic time, advanced explicitly in tests.
- Display output: a bounded byte sink with configurable write behavior.
- Child operations: spawn, write, resize, close, and exit notifications.
- Notifications and clipboard writes: recordable effects with explicit errors.
- Startup-script execution: a job interface reporting validation, output, and exit.

Use one production event loop to translate OS events into these operations. Test
adapters record effects and supply deterministic results; they must not implement
a second layout engine or simplified command dispatcher. Keep platform calls in
POSIX/Windows adapters. Avoid turning the whole application into a mock framework.

## Development chunks and acceptance gates

1. **Inventory and test entry points.** Document which tests run under each task,
   platform requirements, and unsupported cases. Add one aggregate validation
   entry point with explicit skips and useful failure reports. Gate: a missing
   required tool fails clearly; unsupported platforms never report a false pass.

2. **Instance and clock extraction.** Move compositor state into an instance and
   inject time/output without changing behavior. Gate: create two independent
   instances in one process; focus, selection, animation, and clipboard state do
   not cross instances. Existing PTY regressions still pass.

3. **Deterministic event scenarios.** Drive input, child output, resize, exit, and
   timers directly. Cover modal dismissal, paste across modal transitions,
   pointer capture, cancelled docking, stale references, number reuse, notices,
   synchronized-output deadlines, and reload transitions. Gate: no sleeps or
   processes are needed for these behavior tests; failures include the event
   sequence and relevant state.

4. **Generated layout and input tests.** Run seeded sequences of create, split,
   move, dock, resize, hide, reorder, focus, and close. Check unique identities,
   valid references, nonnegative rectangles, tiled partition constraints, stable
   numbering, topmost hit ownership, and visibility agreement after every step.
   Fragment input at all relevant byte boundaries. Gate: failures reproduce from
   a seed and can be reduced to a short event sequence. Store regressions, not
   thousands of redundant snapshots.

5. **Failure injection and load.** Exercise allocation failure, partial writes,
   interrupted/would-block I/O, slow control readers, queue limits, spawn/resize
   failures, child exit during requests, and repeated cleanup. Gate: operations
   either complete or report failure with valid remaining state; bounded queues
   and memory; a slow client cannot stall unrelated windows. Model OS failures in
   memory, then retain focused real-OS tests for each adapter contract.

6. **Graphics and rendering comparisons.** Expand Kitty cases for chunks,
   replacement/deletion, cropping, placement coordinates, scrolling, resize,
   overlapping windows, ID reuse, and cleanup. Assert image bytes and placement
   geometry as well as text. Compare incremental rendering with a fresh full
   render of the same state. Gate: both reconstruct equivalent visible state.
   Add independent terminal/protocol checks where practical; libghostty-vt
   round-trips alone are not conformance proof.

7. **Platform and outer-terminal matrix.** Keep a smaller real-process suite for
   macOS/Linux PTYs and Windows ConPTY, console modes, IPC, shell launch/quoting,
   signals or process termination, and cleanup. Windows targets are stock Windows
   Terminal with PowerShell, Git Bash, and cmd.exe, not WSL. Track shell and outer
   terminal separately. Test local and SSH paths. Gate: supported combinations
   have explicit results; unavailable graphics or clipboard capabilities are
   reported rather than implied to work.

8. **Performance and endurance.** Measure idle CPU, allocations after warmup,
   output size, input-to-render latency, many-window output fairness, control
   latency, and queue high-water marks. Use fixed workloads and record machine,
   compiler, and build mode. Keep timing benchmarks separate from correctness
   tests; correctness deadlines should tolerate scheduler noise. Gate: repeatable
   baselines and bounded growth in long-running tests, without fragile absolute
   latency assertions in the ordinary suite.

## What stays outside pure in-memory testing

Real PTY/ConPTY behavior, process creation and environment, terminal-mode
restoration, OS IPC permissions, descriptor/handle cleanup, and actual shell
behavior require OS tests. Real tmux tests remain valuable even after extracting
the event model. Windows has no assumed native tmux requirement.

A small manual or GUI-driven matrix must check font-dependent appearance,
perceived flicker, mouse behavior in the outer terminal, actual clipboard writes,
graphics support, and SSH disconnect behavior. Only test actual clipboard changes
in an explicitly designated test environment; ordinary automated tests capture
protocol output instead.

Use dedicated temporary directories and isolated process groups or Windows Job
Objects. Never discover or manipulate the developer's live compositor or tmux
sessions in automated tests. Security tests must remain harmless even if the
protection fails. Restore terminal modes and remove test-owned resources on
failure and timeout as well as success.

## Relationship to the control protocol

The snapshot, injection, subscription, replay, and cooperative frame-step APIs in
`00-control-proto.md` remain separate implementation work. Their future tests must
cover snapshot/subscription ordering, cancellation, stale targets, backpressure,
explicit stream gaps, graphics observations, and input isolation. Do not claim
coverage for those APIs before they exist.

A quiet output interval is not proof that an application processed an input.
Prefer explicit fixture acknowledgments and observable conditions. Deterministic
game replay needs fixed seeds, dimensions, and an application-controlled clock or
frame-step hook; a generic PTY cannot supply those guarantees.
