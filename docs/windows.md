# Native Windows

The Windows host is experimental. It runs native PowerShell, Git Bash, and
cmd.exe through ConPTY, with no WSL requirement. Development and automated
console tests currently use Windows build 26300 and Windows Terminal
1.24.12741.0 on `winny`.

## Run

From PowerShell in the checkout:

```powershell
.\zig-out\bin\compo.exe
```

The default shell is Windows PowerShell. Press `Ctrl-]`, then Enter, to open
one. Mouse border dragging, numbered focus, and the control CLI use the same
layout engine as macOS/Linux.

To select another shell for new windows:

```powershell
$env:COMPO_SHELL = 'C:\Program Files\Git\bin\bash.exe'
.\zig-out\bin\compo.exe
```

Or use `C:\Windows\System32\cmd.exe`. The control CLI also accepts `--shell`
per window. `--command` leaves the selected shell interactive afterward.

## Startup scripts

Use `--init layout.ps1` or `--init layout.sh`. The default file is
`%USERPROFILE%\.config\compo\init.ps1`. PowerShell execution policy still
applies. `.sh` scripts use Git Bash, defaulting to
`C:\Program Files\Git\bin\bash.exe`; `COMPO_BASH` overrides that path.

A PowerShell layout can contain:

```powershell
& $env:COMPO_BIN ctl --quiet create --tile --name main --focus
& $env:COMPO_BIN ctl --quiet create --tile --edge left --ratio 2500 --name tools
```

`Ctrl-] r` checks the script syntax, closes its existing windows, then runs it
again. The script and children receive `COMPO_SOCKET`; scripts also receive
`COMPO_BIN`. Control traffic remains newline-delimited JSON over a local
AF_UNIX socket in a temporary directory. Multiple control clients can connect.

## Build and test

The currently tested full executable is cross-compiled on macOS:

```sh
TMPDIR=/tmp mise exec -- zig build -Dtarget=x86_64-windows-gnu -Doptimize=fast
```

It retains libghostty-vt SIMD. PE import inspection found only Windows system
DLLs: Kernel32, ntdll, Winsock, BCrypt, and Universal CRT API sets. No separately
installed runtime DLL was needed on winny. The first native Zig 0.17 build failed
in the dependency C/C++ toolchain, before compiling the host. Native core tests
passed; the full native build still needs investigation. Do not interpret the
cross-build as proof that `zig build` works directly on Windows yet.

Run the Windows integration suite against the executable:

```powershell
python tests/windows_native.py
```

The suite creates an outer ConPTY and runs compo inside it, then drives native
shells in compo windows. It checks startup commands, subsequent keyboard input,
rendered output, resizing, shell exit, mouse focus, numbered focus, prefix
window creation, quit, and both PowerShell and Git Bash startup/reload scripts.
Tests own their child processes and write only to temporary directories.
They do not operate the user's Windows Terminal tabs.

## Boundaries still to verify

- Real Windows Terminal visual behavior, clipboard integration, IME, AltGr,
  modified function keys, and high-rate mouse input need desktop testing.
- This is not a claim of Kitty graphics support in Windows Terminal. The
  compositor retains its graphics model, but the outer terminal must support
  the emitted protocol. See the [Windows Terminal graphics request](https://github.com/microsoft/terminal/issues/8389).
- ConPTY normalizes a child application's output. Its behavior is not identical
  to a byte-transparent POSIX PTY.
- Testing on older supported Windows versions and a native release build remain
  to do.

ConPTY children explicitly clear inherited standard handles so redirected
parent output cannot bypass their terminal. This follows the Windows Terminal
maintainer's [handle guidance](https://github.com/microsoft/terminal/discussions/15814).

The complete three-window Git Bash layout is in `examples/init.ps1`. Copy it to
`%USERPROFILE%\.config\compo\init.ps1`; adjust the scratch working directory
if your checkout is elsewhere.

## Set the default shell from init.sh

```sh
#!/bin/sh
"$COMPO_BIN" ctl --quiet default-shell 'C:\Program Files\Git\bin\bash.exe'
"$COMPO_BIN" ctl --quiet create --tile --name main --focus
```

This also selects Git Bash for subsequent `Ctrl-] Enter` windows. Run
`compo ctl default-shell` to read the current default. Per-window `--shell`
overrides it. The setting belongs to the running compositor and survives layout
reloads; a new process starts with its environment/platform default again.
The path must be absolute. Executable launch errors are reported when opening a
window. The protocol operation is `config.shell`, with an optional `shell`
string for setting and no `shell` field for reading.
