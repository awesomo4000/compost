![Compo logo](img/compost-logo-small.png)

# compo

This is a terminal compositor.  This does the following:

- Display shells in separate windows within an existing terminal emulator session
- Allow shells to "float" or be tiled, with mouse resizing and snap positioning for float and tiled
- When tiled, sizer between windows can be dragged freely.
- Each pane has its own virtual terminal
- Passthrough kitty protocol and act right

## Isn't this just crappy tmux?

No, it lives outside tmux, so tmux can't affect it. This lets you have a combination of windows where some are outside tmux and some aren't. Static panes (like a program that controls tmux) stay put. My main setup with this is a sidebar on the left or right, a main window in the middle with my tmux session. The left sidebar is running tmm (https://github.com/awesomo4000/tmm/)  control the tmux in the middle.



## What problem this solving for me?

- Static layouts combined with tmux - If i place a sidebar style pane inside tmux, it goes away when i switch to a different window or session. Compo terminal windows don't go away with tmux changes since they live outside of tmux.
- Let me use a tmux control program without tmux bothering its placement by changing windows or sessions.
- Run remotely over ssh and passthrough kitty protocol
- Small control socket protocol for automation and testing of TUIs and stuff

#### What it doesn't do -

- Persistence (that is for tmux)

* Tons of customization

I mainly use this for long-running sessions where I leave the same terminal up for weeks, compo hosts a static sidebar or other static tools, while tmux does session switching, persistence, and all that jazz.


A Zig window-management core owns geometry, tiling, docking, floating windows, focus, and visibility without knowing about terminals. A terminal adapter supplies libghostty-vt emulation and Kitty graphics.

## Keyboard / Mouse

At open, **Ctrl+] Enter**  - create a floating shell

**Alt + mouse drag** - Drag a window around to position it (with snapping for placement / tiling)

**Alt + Ctrl + mouse drag** - Drag a winodw around to position it, maintain float

**Ctrl+] Tab/Shift-Tab** - Cycle through windows 

Hover on borders to see a highlight and resize them. Corners on floating windows allow resize in both directions.

## Building (needs zig 0.17.0)

**$ zig build**

**$ ./zig-out/bin/compo**



## Distribution goals

Keep SIMD enabled. Target fully static musl builds for broad Linux compatibility,
Windows builds needing only built-in system DLLs with no runtime installer, and macOS builds using the built-in libSystem. See the [distribution policy](docs/roadmap.md#distribution-policy) for baseline and release-validation requirements.

## Control protocol

The persistent local socket supports window discovery, creation, floating placement, layers, focus, stacking, and removal. Child shells receive its path in `COMPO_SOCKET`. Use `COMPO_HEADLESS=80x24` for a disposable host without a physical terminal. Screen observation and injected input are the next stage. See
[the current interface](docs/control-protocol.md) and [the development spec](specs/00-control-proto.md).
