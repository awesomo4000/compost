# Linux development

Use the repository-pinned Zig version through mise. On a fresh checkout:

```sh
mise trust
mise install
mise run bootstrap
mise exec -- zig build -Doptimize=fast -j2
./zig-out/bin/compo
```

The bootstrap step imports the vendored libghostty-vt archive into Zig 0.17's
local package directory. It is needed even if the archive was fetched into the
global cache previously. Subsequent builds reuse the local packages.

For an interactive SSH launch, allocate a terminal:

```sh
ssh -t titmouse-winny 'cd ~/src/compost && exec ./zig-out/bin/compo'
```

Compo runs on the remote machine. Clipboard writes travel back to the local
terminal through OSC 52, and graphics require support in that outer terminal.
Use Linux paths in startup scripts, such as `/bin/bash`, instead of macOS
Homebrew paths.

Validation requires Python 3 and tmux for the tmux integration tests:

```sh
mise exec -- zig build test -Doptimize=safe -j2
mise run test-host
mise run test-tmux-mouse
mise run test-tmux-keys
```

The normal native build links against the host C library. This is not yet the
planned portable static Linux release artifact.

Validated on titmouse-winny on 11/04/2026: x86-64 Linux 6.8, glibc 2.39,
Zig 0.17.0, Python 3.12.3, and tmux 3.4. The fast build, safe unit suite,
all host integration tests, and tmux mouse/key regressions passed. `ldd`
reports only libc and the ELF loader as runtime dependencies.
