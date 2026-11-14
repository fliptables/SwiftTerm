#!/usr/bin/env python3
"""Print the per-feed-call wrapper functions of a release build and the calls out of them.

The fork's rule for the per-feed path (IT-2001): a feed with nothing dirty runs
upstream's instructions and no others. The parser itself is upstream's byte for
byte (pinned by a test); this script covers the thin layer around it, where an
addition can change what the optimiser inlines: `Terminal.feed(byteArray:)`,
`feed(buffer:)`, `parse(buffer:)`, their `$defer`, and
`reconcileSynchronizedOutputWatchdog()`, plus any merged (`Tm`) copies.

It needs a RELEASE binary that links SwiftTerm (it is not a test: a debug build
inlines nothing). Build the profiler as the findings record says, e.g.

    swift build -c release --package-path Tools/SwiftTermBenchmarks \\
        --product SwiftTermProfile

then run

    python3 -I Tools/feed-path-disasm.py <path to SwiftTermProfile>

and compare the "calls out" lines, and the instruction count of the not-dirty
path counted by hand from the listing, with the numbers the findings record
quotes for upstream (d4f52faaa) and for the fork. macOS (otool, swift-demangle).
"""

import re
import subprocess
import sys

WANTED = (
    "Terminal.feed(byteArray:)",
    "Terminal.feed(buffer:)",
    "Terminal.parse(buffer:)",
    "Terminal.parseBorrowed(_:)",
    "$defer #1 () in Terminal.parse(buffer:)",
    "$defer #1 () in Terminal.parseBorrowed(_:)",
    "Terminal.reconcileSynchronizedOutputWatchdog()",
)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    listing = subprocess.run(["otool", "-tV", sys.argv[1]], check=True,
                             capture_output=True, text=True).stdout
    funcs, current, body = {}, None, []
    for line in listing.splitlines():
        if line.endswith(":") and not line.startswith(("\t", " ", "(")):
            if current is not None:
                funcs[current] = body
            current, body = line[:-1], []
        elif current is not None:
            body.append(line)
    if current is not None:
        funcs[current] = body
    names = list(funcs)
    demangled = subprocess.run(["xcrun", "swift-demangle", "--simplified"],
                               input="\n".join(names), check=True,
                               capture_output=True, text=True).stdout.splitlines()
    for name, pretty in zip(names, demangled):
        if pretty not in WANTED:
            continue
        code = [l for l in funcs[name] if "\tnop" not in l]
        calls = []
        for l in code:
            m = re.search(r"\t(bl|b|blr|br)\t(\S+)(?:\s*; (.*))?$", l)
            if m and (m.group(1) in ("bl", "blr", "br") or not m.group(2).startswith("0x")):
                calls.append(m.group(1) + " " + (m.group(3) or m.group(2)))
        print(f"#### {pretty}  ({name})  {len(code)} instructions")
        print("calls out: " + (", ".join(calls) if calls else "none"))
        for l in code:
            print(l)
        print()


if __name__ == "__main__":
    main()
