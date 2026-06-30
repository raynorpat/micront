#!/usr/bin/env python3
"""Assemble a composite OLE public header (objbase.h / ole2.h) the way the
NT TYPES project's makefile.inc does: a hand-written prologue (.X) + the
MIDL-generated component headers (with #include / "//  File:" lines stripped,
but their __xxx_h__ guards kept so the embedded copy self-suppresses against
the standalone header) + a hand-written epilogue (.Y) of API prototypes.

Usage: assemble_ole_header.py <objbase|ole2> <types_subdir> <gen_dir> <out.h>
  objbase: <subdir>/OBJBASE.X + gen/{wtypes,unknwn}.h + fwd(gen/com.h) + gen/com.h + <subdir>/OBJBASE.Y
  ole2:    <subdir>/OLE2.X    + fwd(gen/ole2x.h) + gen/ole2x.h + <subdir>/OLE2.Y
"""
import re, sys

# MIDL stamps "generated ... at <weekday> <date>" into each header; normalize
# it so regeneration is byte-deterministic and doesn't churn the committed file.
_TS = re.compile(r'^(\s*\*?\s*at )\w{3} \w{3} .* \d{4}\s*$')
def _norm(line):
    return _TS.sub(r'\1<generated>', line)

def _read(path):
    return [_norm(l.rstrip("\n")) for l in open(path, encoding="latin-1")]

def strip(path):
    # makefile sed: -e "/^#include/d" -e "/\/\/  File:/d"
    return [l for l in _read(path)
            if not l.startswith("#include") and "//  File:" not in l]

def forward_sed(path):
    # forward.sed: emit the typedef line following a "/* Forward Declarations */"
    # marker. New-format MIDL puts the typedefs in __X_FWD_DEFINED__ blocks
    # (marker followed by a blank line), so this yields nothing for those —
    # the guarded forwards then arrive with the appended body, which is correct.
    lines = _read(path)
    out, i = [], 0
    while i < len(lines):
        if "/* Forward Declarations */" in lines[i] and i + 1 < len(lines) \
                and lines[i + 1].startswith("typedef"):
            out.append(lines[i + 1]); i += 2; continue
        i += 1
    return out

def main():
    kind, sub, gen, out = sys.argv[1:5]
    R = []
    if kind == "objbase":
        R += _read(f"{sub}/OBJBASE.X")
        R += strip(f"{gen}/wtypes.h")
        R += strip(f"{gen}/unknwn.h")
        R += ["", "// Forward declarations for typedefs in this file"]
        R += forward_sed(f"{gen}/com.h")
        R += strip(f"{gen}/com.h")
        R += _read(f"{sub}/OBJBASE.Y")
        footer = "__objbase_H__"
    elif kind == "ole2":
        R += _read(f"{sub}/OLE2.X")
        R += ["", "// Forward declarations for typedefs in this file"]
        R += forward_sed(f"{gen}/ole2x.h")
        R += strip(f"{gen}/ole2x.h")
        R += _read(f"{sub}/OLE2.Y")
        footer = "__ole2_H__"
    else:
        sys.exit(f"unknown kind: {kind}")
    R += ["#ifndef RC_INVOKED", '#include "poppack.h"', "#endif // RC_INVOKED",
          f"#endif     // {footer}"]
    # NT source tree is CRLF; emit CRLF so the file matches its neighbors.
    open(out, "w", encoding="latin-1", newline="").write("\r\n".join(R) + "\r\n")
    iface = sum(1 for l in R if l.startswith("typedef interface"))
    print(f"  assembled {out}: {len(R)} lines, {iface} interfaces")

if __name__ == "__main__":
    main()
