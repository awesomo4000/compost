# Dependencies

## libghostty-vt

Only the standalone `libghostty-vt-source.tar.gz` release asset is vendored.
No full Ghostty checkout was downloaded. The terminal adapter imports it through
a local archive dependency with a Zig package hash. The geometry core remains
independent of it. PNG decoding reuses the archive's existing Wuffs module through
its pinned build module imports, so this integration needs checking on updates.

Metadata and checksum are recorded in [libghostty-vt.json](libghostty-vt.json).
The checked release is `1.3.2-main+f54340a`, commit
`f54340ad77814fe319d136e5e915d6a48de8dd23`. The 4,241,877-byte asset was updated
at `2026-10-21T21:12:55Z`. Its manifest requires Zig **0.17.0**.

Source: [Ghostty rolling tip release](https://github.com/ghostty-org/ghostty/releases/tag/tip).
The tip assets are replaced frequently, so keep the archive and its hash locally
rather than declaring the mutable download URL as a reproducible dependency.
The downloaded SHA-256 matches the digest published in GitHub release metadata.

Both the Zig and C ABI upstream library test binaries compiled successfully
with Zig 0.17.0 on this Apple Silicon Mac without source changes. The compositor's
nine core tests passed in both debug and safe modes; its demo and formatting
checks also passed. The port scanner reported no parse, breaking-change, or
silent-change hits in the compositor sources or build script.

The full upstream `test-lib-vt` run completed with 3,220 passes and 28 skips in
the Zig interface suite, and 3,707 passes and 28 skips in the C ABI suite. Each
suite had one failure and one reported leak in the same test:
`image load: temporary file outside directory prefix is rejected`.

The disposable checkout and its test fixtures lived under `/tmp`. The test
expects a file in a sibling `temp-suffix` directory to be rejected, but
`LoadingImage.isPathInTempDir` explicitly accepts all of `/tmp` and, on Darwin,
`/private/tmp`. Thus this fixture passes the global temporary-root allowance.
The unexpected successful allocation is not freed by the error-expecting test.
This run is not a clean upstream test pass. The observed failure is consistent
with the test location and implementation, not a compiler incompatibility.
The archive was not patched, and the test was not moved outside disposable
temporary storage to work around it.

The released `src/terminal/stream_terminal.zig` declares `program_status:`, the
OSC 7501 embedder hook. It does not declare `hierarchical_context:`, the OSC 3008
embedder hook watched by tmm. The distinction matters: parser support does not
imply an embedder callback. tmm's `tools/deps-check.sh` uses OSC 7501 as its known
working canary while watching for OSC 3008.

`mise run deps-check` verifies the local archive checksum, compares the current
release digest, and checks both hooks against a fixed snapshot of upstream main.
Network/API errors fail the check instead of being reported as absent hooks.
This checks declarations, not complete runtime protocol behavior.

## Updating the archive

Download only the named release asset into a temporary directory, inspect its
archive root and compiler requirement, and compare its SHA-256 with GitHub's
asset digest. Update the local archive and JSON metadata together after deciding
to adopt it. Do not replace the pin automatically just because tip has moved.

For standalone upstream tests, unpack the archive into a disposable directory
and run the pinned compiler there:

```sh
mise exec zig@0.17.0 -- zig build test-lib-vt -Demit-lib-vt=true
```

This builds the library test targets, not the GUI application. Declared build
dependencies may still need downloading. The upstream archive retains its own
license files and package metadata.

## tmux

`tmux/` is the user's upstream Git checkout. Its build and validation notes are
in the project README. It has not been migrated to Zig's build system yet.
