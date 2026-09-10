#!/usr/bin/env python3
"""Remove the entity-postgres JSON6902 patch entries from a kustomization.yaml.

Drops each 3-line `- op: replace / path: /spec/data/N/remoteRef/key / value: ...`
block whose value names entity-postgres. Matches on the VALUE, not the index, so it
does the right thing whatever the positions are.

    python3 fix-overlay-entity-patches.py <file>   -> rewrites in place, prints what it did
"""
import re, sys

OP    = re.compile(r'^(\s*)-\s+op:\s+replace\s*$')
PATH  = re.compile(r'^\s*path:\s*(/spec/data/\d+/remoteRef/key)\s*$')
VALUE = re.compile(r'^\s*value:\s*(\S+)\s*$')

def strip(lines):
    out, removed, i = [], [], 0
    while i < len(lines):
        m = OP.match(lines[i])
        if m and i + 2 < len(lines):
            pm = PATH.match(lines[i+1])
            vm = VALUE.match(lines[i+2])
            if pm and vm and vm.group(1).endswith("entity-postgres"):
                removed.append((pm.group(1), vm.group(1)))
                i += 3
                continue
        out.append(lines[i])
        i += 1
    return out, removed

def main():
    if len(sys.argv) != 2:
        print("usage: fix-overlay-entity-patches.py <kustomization.yaml>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    lines = open(path).read().splitlines(keepends=True)
    out, removed = strip(lines)
    if not removed:
        print("  %s: no entity-postgres patch entries -- unchanged" % path)
        return 0
    open(path, "w").write("".join(out))
    for p, v in removed:
        print("  %s: removed  %s -> %s" % (path, p, v))
    return 0

if __name__ == "__main__":
    sys.exit(main())
