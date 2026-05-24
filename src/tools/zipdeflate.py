#!/usr/bin/env python3
"""Recompress a zip's members with DEFLATE.

The MicroNT build emits STORED (uncompressed) zips — the pure-Lua writer
doesn't compress.  The vmlinuz loader, however, inflates DEFLATE members
(puff.c) so users can add files to a shipped initrd.zip with a standard
`zip`.  This utility rewrites every member of a zip with DEFLATE, so we can
produce a fully-compressed initrd.zip to exercise that loader path.

Usage:
    zipdeflate.py IN.zip [OUT.zip]      # OUT defaults to IN (in place)

Member names and contents are preserved; only the storage method changes.
"""
import sys
import zipfile


def recompress(src_path, dst_path):
    with zipfile.ZipFile(src_path, "r") as zin:
        members = [(info.filename, zin.read(info.filename))
                   for info in zin.infolist()]
    with zipfile.ZipFile(dst_path, "w", zipfile.ZIP_DEFLATED,
                         compresslevel=9) as zout:
        for name, data in members:
            zout.writestr(name, data, zipfile.ZIP_DEFLATED)
    return len(members)


def main(argv):
    if len(argv) not in (2, 3):
        sys.stderr.write(__doc__)
        return 2
    src = argv[1]
    dst = argv[2] if len(argv) == 3 else argv[1]
    n = recompress(src, dst)
    print("zipdeflate: %d members -> %s (DEFLATE)" % (n, dst))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
