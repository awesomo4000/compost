# tmux++

An experiment in a standalone terminal compositor that can host shells, tmux
clients, and controller sidebars. A Zig window-management core owns geometry,
tiling, docking, floating windows, focus, and visibility without knowing about
terminals. A terminal adapter supplies libghostty-vt emulation and Kitty graphics.

The [compositor design](docs/compositor-design.md) describes the current direction.
The host starts with an empty desktop. Create floating shells, drag them into
nested tiles, or reserve edge walls for controllers. Each shell keeps the same
process while its layout changes. Detach/reattach remains future work.

The POSIX host uses libghostty-vt for retained terminal screens and basic Kitty
placements. The optional tmux config below separately demonstrates upstream
format-based side status. See the [roadmap](docs/roadmap.md) for remaining work.

## Run the core

The project pins Zig 0.17.0 through `mise.toml` and declares the same minimum
in `build.zig.zon`. The longer-term migration of tmux's own build is separate.

```sh
mise install
mise run test
mise run demo
mise run demo-vt
```

The demo prints a static layout with numbered windows. It needs no terminal
control, tmux server, or libghostty-vt. The core supports split-tree tiles,
ordered edge docks, constrained floats, independent always-on-top ordering,
visibility regions, focus, and pointer capture. See [core API notes](docs/core-api.md)
for ownership, bounds, and initial limitations.

## Run the shell

```sh
mise run shell
```

The desktop starts empty. **Ctrl-] then Enter** creates a floating `$SHELL`.
Click a window, or press **Ctrl-] then Tab**, to switch focus. Ctrl-] twice
sends a literal Ctrl-] to the shell. Ordinary keys, including your tmux prefix,
pass through to the focused shell.

- Option-left-drag moves a window. On a tiled border it pulls the tile out.
- Drag over the directional zones of a tile to split it, or near a workspace
  edge to split the whole layout. A muted gray-blue preview shows the target.
  Release to dock; Escape cancels the drag. New splits divide the target equally.
- Hold Control during an Option-drag to a workspace edge to create a reserved wall.
- Drag a shared tile divider to resize both sides; drag a floating border or
  corner to resize that float.
- `exit` closes a shell; closing the last returns to the desktop.
- **Ctrl-] then q** quits the compositor and closes all its shells.

`TMUXPP_LEGACY=1` starts the earlier sidebar/main layout.
`TMUXPP_SINGLE=1` starts a full-root shell; `TMUXPP_FLOAT=1` starts sidebar,
main, and floating shells. `TMUXPP_DESKTOP=1` forces an empty desktop when
using command environment variables for testing.

To install optimized binaries at predictable paths:

```sh
mise exec -- zig build -Doptimize=fast
./zig-out/bin/tmuxpp-shell
```

Use `-Doptimize=small` for the smaller build. `zig build` also installs
`terminal-demo` and `layout-demo` under `zig-out/bin/`.

The legacy left dock is up to 24 columns wide and shrinks on narrow displays. This host
is tested on macOS. An optional floating shell is available with `TMUXPP_FLOAT=1`; Alt-left-drag
moves it, dragging a border resizes that edge, and Ctrl-] then `f` hides or shows it.
Borders brighten on hover; the dock and main terminal share one draggable divider.
Detach/reattach and complete Kitty graphics rendering are not implemented. See
[shell host notes](docs/shell-host.md) for the exact supported behavior.

`demo-vt` replays terminal output, shows the retained text screen, and confirms
that a Kitty image is retained. It is a headless replay, not an interactive shell
or image renderer. `zig build test-core` and `zig build test-vt` run the two layers
separately; `mise run test` also runs renderer round-trip tests. `mise run test-host`
builds the shell and runs disposable-PTY integration checks. See [terminal adapter notes](docs/terminal-adapter.md).

The standalone libghostty-vt release is pinned in `vendor/` and used by the terminal
adapter. It also requires Zig 0.17.0. Run `mise run deps-check` to check for
release updates and the OSC 7501/3008 embedder hooks. See [dependency notes](vendor/README.md).

## Optional tmux reference checkout

The standalone compositor builds without a tmux checkout. The separate upstream
experiment uses a local Git checkout in `vendor/tmux`, currently at
`a864c419900182fe624abf73db72ae6f1b0ab9a5` from https://github.com/tmux/tmux.
It reports `next-3.9` and already includes native side status. No C changes are
needed to try its session/window list. See [the design notes](docs/sidebar-design.md)
for what exists and what remains to investigate.

The root repository tracks the compositor and its pinned libghostty-vt archive.
Local reference checkouts under `vendor/tmux/` and `x/` are ignored. To reproduce
the optional tmux experiment in a fresh checkout:

```sh
git clone https://github.com/tmux/tmux.git vendor/tmux
git -C vendor/tmux checkout a864c419900182fe624abf73db72ae6f1b0ab9a5
```

## Build the optional tmux reference

Requires a C compiler, make, autoconf, automake, pkg-config, libevent, and curses.
The image-enabled build also uses libpng and zlib.

```sh
cd vendor/tmux
TMPDIR=/tmp ./autogen.sh
TMPDIR=/tmp ./configure --enable-images --prefix=/tmp/tmuxpp-install
make clean
make -j4
./tmux -V
```

The unmodified checkout builds successfully on this Mac. Do not install over
system tmux during the experiment.

## Try upstream side status

From the project root, launch an isolated server with the experiment config:

```sh
experiment_dir=$(mktemp -d /tmp/tmuxpp.XXXXXX)
./vendor/tmux/tmux -S "$experiment_dir/socket" -f "$PWD/config/sidebar.conf" new-session -s work
```

The config first loads `~/.tmux.conf`, preserving your regular prefix, bindings,
shell, and styling, then enables the built-in left sidebar at 24 columns.
Click session/window rows to navigate. With only one session, upstream shows
its windows directly. With your current config, `Ctrl-a N` creates another
session. `Ctrl-a )` selects the next session and `Ctrl-a (` selects the previous
session. Your `Ctrl-a h/j/k/l` pane navigation and split bindings stay available.

Each launch uses a separate socket, so it does not affect existing tmux servers.
The sidebar uses global session defaults; per-session overrides, including
upstream divider dragging, can change its width between sessions.

## Validation

The unmodified checkout passed `side-status.sh`, `side-status-mouse.sh`,
`side-status-resize.sh`, `side-status-scroll.sh`, and `side-status-margins.sh`
on this Mac, using disposable servers under fresh `/tmp` directories. The
experiment config also loaded successfully and registered the prefix + N binding.
The vendor checkout has no tracked changes. Interactive testing in your usual
terminal and the rest of the upstream suite remain to be done.

A clean image-enabled rebuild also passed four Kitty input/decode/placement/
lifecycle regressions. This does not establish complete Kitty support; the
native Kitty output backend is still a stub. See [the audit](docs/kitty-graphics.md).

## Distribution goals

Keep SIMD enabled. Target fully static musl builds for broad Linux compatibility,
Windows builds needing only built-in system DLLs with no runtime installer, and
macOS builds using the built-in libSystem. See the [distribution policy](docs/roadmap.md#distribution-policy)
for baseline and release-validation requirements.
