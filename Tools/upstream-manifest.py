#!/usr/bin/env python3
"""Write (or check) the upstream line manifest the fork's "only adds" pin reads.

The fork's rule (IT-2001, lead 14): it never changes or removes a line of a file
that exists upstream; what Scape needs is added beside it. The test
`UpstreamOnlyAddsTests` checks that rule without git or network: it reads this
manifest, one 32-bit FNV-1a hash per upstream line, and requires each upstream
file's hash sequence (less a closed allow-list) to be a subsequence of the
file's lines at HEAD.

Usage (from the repository root):
    python3 -I Tools/upstream-manifest.py write   # regenerate from UPSTREAM
    python3 -I Tools/upstream-manifest.py check   # verify the checked-in copy

After an upstream merge, set UPSTREAM to the merged upstream commit, run
`write`, delete the old manifest, and point the test's `manifestName` at the
new one. The manifest header records this script's SHA-256 and the test
checks it, so an edit here means a rewrite of the manifest.
"""

import hashlib
import os
import subprocess
import sys

UPSTREAM = "d4f52faaa"
SCOPE = "Sources/SwiftTerm"
MANIFEST = "Tests/UpstreamManifest/" + UPSTREAM + ".lines"


def fnv1a32(data):
    value = 0x811C9DC5
    for byte in data:
        value ^= byte
        value = (value * 0x01000193) & 0xFFFFFFFF
    return value


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True).stdout


def render():
    commit = git("rev-parse", UPSTREAM + "^{commit}").decode().strip()
    with open(os.path.abspath(__file__), "rb") as handle:
        script_sha = hashlib.sha256(handle.read()).hexdigest()
    paths = git("ls-tree", "-r", "--name-only", commit, "--", SCOPE).decode().splitlines()
    out = [
        "# upstream-lines v1",
        "# upstream " + commit,
        "# generator Tools/upstream-manifest.py sha256 " + script_sha,
        "# one block per file: '= <path> <line count>', then one hex FNV-1a 32 hash per line,",
        "# eight per row; lines are the file's bytes split on LF (a trailing LF ends with an empty line).",
    ]
    for path in sorted(paths):
        lines = git("show", commit + ":" + path).split(b"\n")
        hashes = ["%08x" % fnv1a32(line) for line in lines]
        out.append("= %s %d" % (path, len(hashes)))
        for start in range(0, len(hashes), 8):
            out.append(" ".join(hashes[start:start + 8]))
    return "\n".join(out) + "\n"


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode not in ("write", "check"):
        sys.exit("usage: upstream-manifest.py write|check")
    os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    text = render()
    if mode == "write":
        os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)
        with open(MANIFEST, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        print("wrote", MANIFEST, len(text), "bytes")
        return
    with open(MANIFEST, encoding="utf-8") as handle:
        current = handle.read()
    if current != text:
        sys.exit("MISMATCH: " + MANIFEST + " is not what this script writes from " + UPSTREAM)
    print("OK", MANIFEST, "matches", UPSTREAM)


if __name__ == "__main__":
    main()
