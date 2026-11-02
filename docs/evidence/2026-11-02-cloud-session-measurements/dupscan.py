"""Byte-identical files under a tree: how much would file-level dedup save?

Groups regular files by size, then by SHA-256; counts each extra copy's bytes.
Files that already share an inode (hardlinks) count once.
"""
import hashlib, os, sys
from collections import defaultdict

root = sys.argv[1]
by_size = defaultdict(list)
seen = set()
total = 0
for d, _, files in os.walk(root):
    for f in files:
        p = os.path.join(d, f)
        try:
            st = os.lstat(p)
        except OSError:
            continue
        if not os.path.isfile(p) or os.path.islink(p) or (st.st_dev, st.st_ino) in seen:
            continue
        seen.add((st.st_dev, st.st_ino))
        total += st.st_size
        if st.st_size >= 4096:
            by_size[st.st_size].append(p)

dup = 0
per_top = defaultdict(int)
for size, paths in by_size.items():
    if len(paths) < 2:
        continue
    by_hash = defaultdict(list)
    for p in paths:
        h = hashlib.sha256()
        with open(p, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        by_hash[h.digest()].append(p)
    for group in by_hash.values():
        for p in group[1:]:
            dup += size
            per_top[os.path.relpath(p, root).split(os.sep)[0]] += size

print(f"files: {total / 2**30:.2f} GiB, duplicate copies: {dup / 2**30:.2f} GiB ({100 * dup / total:.0f}%)")
for top, b in sorted(per_top.items(), key=lambda x: -x[1])[:8]:
    print(f"  {b / 2**30:6.2f} GiB  {top}")
