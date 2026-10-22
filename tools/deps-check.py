#!/usr/bin/env python3
"""Read-only check of the pinned release and upstream embedder hooks. Requires gh."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
HOOK_FILE = "src/terminal/stream_terminal.zig"
WATCHES = (
    ("OSC 7501 program-status hook (canary)", "program_status:"),
    ("OSC 3008 hierarchical-context hook", "hierarchical_context:"),
)


def api(endpoint):
    return json.loads(subprocess.check_output(["gh", "api", endpoint], text=True))


def main():
    pin = json.loads((ROOT / "vendor/libghostty-vt.json").read_text())
    archive = ROOT / "vendor" / pin["asset"]
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    if actual != pin["sha256"]:
        raise RuntimeError("Pinned archive checksum mismatch")
    with tarfile.open(archive) as tar:
        stream = tar.extractfile(pin["archive_root"] + "/" + HOOK_FILE)
        if stream is None:
            raise RuntimeError("Missing hook source in archive")
        local = stream.read().decode()
    release = api(f'repos/{pin["repository"]}/releases/tags/{pin["release"]}')
    asset = next(a for a in release["assets"] if a["name"] == pin["asset"])
    digest = asset.get("digest")
    print(f'Pinned commit: {pin["commit"]}')
    print(f'Latest asset updated: {asset["updated_at"]}')
    if not digest:
        print("Release digest unavailable; freshness is unknown")
    else:
        print("Archive: " + ("up to date" if digest == "sha256:" + actual else "new release available"))
    # A commit SHA avoids mixing changing main snapshots between file requests.
    head = api(f'repos/{pin["repository"]}/commits/main')["sha"]
    import base64
    upstream_file = api(f'repos/{pin["repository"]}/contents/{HOOK_FILE}?ref={head}')
    upstream = base64.b64decode(upstream_file["content"]).decode()
    print(f"Upstream main checked: {head}")
    for label, pattern in WATCHES:
        print(f'{label}: pinned={pattern in local}, main={pattern in upstream}')
    if "program_status:" not in local or "program_status:" not in upstream:
        raise RuntimeError("OSC 7501 canary absent; investigate API changes before trusting hook checks")
    print("Hook checks inspect declarations; they do not establish protocol conformance.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, StopIteration, RuntimeError,
            subprocess.CalledProcessError, tarfile.TarError) as exc:
        print(f"Dependency check failed: {exc}", file=sys.stderr)
        sys.exit(1)
