# Roadmap

## Near term

Develop and validate on macOS first. Linux and Windows release work is deferred
until the compositor functionality is further along; the distribution policy
below remains the eventual target.

- Build a standalone Zig compositor with a terminal-independent geometry and
  window-management library. Test the core without tmux or terminal I/O.
- Start with a shell filling the root rectangle, then add docked walls, tiling,
  and constrained floating windows. Separate stacking from space reservation.
- Use libghostty-vt terminal adapters and design Kitty graphics rendering,
  clipping, and restoration into the initial terminal integration.
- Keep the host alive through display disconnects and restore drawing and input
  on reattach. Evaluate dtach as an initial transport.
- Host multiple tmux clients with targeted sidebar controllers and an optional
  aggregate controller. Preserve the user's ordinary tmux bindings.
- Copy and adapt useful tmm code without making tmm a dependency.
- Continue the tmux graphics audit and implement fork changes where needed for
  end-to-end support. Track capabilities and conformance explicitly.

See the current [compositor design](compositor-design.md). Earlier embedded-fork
research remains in [sidebar design](sidebar-design.md) and
[VT integration](vt-integration.md); see also the [graphics audit](kitty-graphics.md).

## Longer term

- Build tmux entirely with the Zig 0.17.0 build system. Cover source selection,
  platform detection, generated parser sources, compatibility code, dependency
  linkage, libghostty-vt, tests, installation, and cross compilation. This is a
  replacement build, not a Zig wrapper that invokes autotools. Toolchain and
  dependency compatibility must be evaluated when undertaking the migration.
- A fully working native Windows port, beyond WSL. Audit PTY/ConPTY behavior,
  process/job lifecycle, event I/O, local client/server transport, signals and
  terminal modes, paths/encoding, clipboard, and install/run behavior. Verify
  session persistence, the static sidebar, regular bindings, and graphics on
  Windows terminals. A successful cross compile is not sufficient.

These are recorded tasks, not implemented features or promises about current
upstream Windows or Zig compatibility.

## Distribution policy

Keep libghostty-vt SIMD acceleration enabled. Prefer self-contained releases;
removing libc itself is not a goal when it can be bundled statically.

- Linux: ship fully static musl executables per CPU architecture, including
  required dependency code. Aim for broad compatibility across distributions
  and older kernels without depending on the installed glibc or shared libraries.
  Choose and document a minimum kernel and CPU baseline, avoid native-CPU-only
  release builds, and use runtime SIMD dispatch where supported. Validate on
  older supported kernels as well as current distributions; static linking
  alone does not guarantee compatibility with every historical Linux version.
- Windows: depend only on the minimum necessary built-in system DLLs. Bundle
  runtime and third-party library code statically so users need no additional
  DLL downloads or runtime installers. Document the minimum Windows version
  required by ConPTY and other APIs, and test native releases on that baseline.
- macOS: linking the built-in libSystem is acceptable. Avoid separately installed
  third-party dynamic libraries and document the minimum supported macOS version.

Release checks must inspect actual executable dependencies and run on clean
systems. Cross-compilation alone is not proof of runtime compatibility. These
are release goals; the current builds have not established the full support matrix.
