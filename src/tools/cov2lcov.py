#!/usr/bin/env python3
"""
cov2lcov.py -- turn a qcov execution histogram into lcov coverage.

Joins three inputs:

  * a qcov trace      (--trace)   per-block execution histogram from the
                                  qcov QEMU plugin (src/tools/qcov.c)
  * a boot serial log (--serial)  the module load map: each `IOSYS:` line
                                  gives a module's runtime base + size
                                  (boot-efi `staged` lines are a fallback)
  * the .dwf DWARF    (--src-root) one per module, found in the source
                                  tree, carrying the line-number table

and emits an lcov .info file (--out) for genhtml / coveralls.

Address model
-------------
A .dwf's line table is linked at the PE's preferred ImageBase -- an
address in the table is `ImageBase + RVA`.  At run time the kernel
places the module at some other base, so for module M:

    slide    = runtime_base(M) - ImageBase(M)
    dwf_addr = executed_pc - slide

ImageBase is read from the PE sitting next to the .dwf; runtime_base
comes from the serial log.  This is the relocation `nt addsym` applies
(gdb_nt.py), inverted.

DWARF is read by shelling out to `readelf --debug-dump=rawline`, so
there is no Python package dependency -- matching qcov.c's stance.  The
rawline dump carries the per-CU directory + file tables, so every source
path is exact (the absolute build path the converter baked in, made
repo-relative here); no basename guessing is needed.
"""

import argparse
import bisect
import os
import re
import struct
import subprocess
import sys

# Defaults line up with `make coverage` output (build/cov/).
_THIS_DIR  = os.path.dirname(os.path.abspath(__file__))
_SRC_ROOT  = os.path.dirname(_THIS_DIR)
_REPO_ROOT = os.path.dirname(_SRC_ROOT)
_COV_DIR   = os.path.join(_REPO_ROOT, "build", "cov")

PE_EXTS = (".sys", ".exe", ".dll")


def _relpath(path):
    """Make an absolute build path repo-relative when it lies inside the
    repo, so genhtml / coveralls get stable paths; leave it otherwise."""
    prefix = _REPO_ROOT + os.sep
    return path[len(prefix):] if path.startswith(prefix) else path


_dir_cache = {}


def _canon_case(rel_path):
    """Resolve a repo-relative path to its real on-disk casing.

    The DWARF tables lowercase basenames and sometimes whole directory
    components, and embed `..` segments from compilers invoked in a
    sibling directory (`CONFIG/UP/../i386/init386.c`).  Normalise the
    `..`, then walk the path component by component, case-folding each
    against the real directory listing -- so genhtml, on a case-
    sensitive filesystem, can find the file."""
    rel_path = os.path.normpath(rel_path)
    if rel_path.startswith("..") or os.path.isabs(rel_path):
        return rel_path                     # outside the repo; leave it
    resolved = []
    for part in rel_path.split(os.sep):
        here = os.path.join(_REPO_ROOT, *resolved)
        listing = _dir_cache.get(here)
        if listing is None:
            try:
                listing = {fn.lower(): fn for fn in os.listdir(here)}
            except OSError:
                listing = {}
            _dir_cache[here] = listing
        real = listing.get(part.lower())
        if real is None:
            return rel_path                 # can't resolve; best effort
        resolved.append(real)
    return os.sep.join(resolved)


# ---------------------------------------------------------------------------
# Module load map -- parsed from the serial log
# ---------------------------------------------------------------------------

# IOSYS: 'vionet.SYS' 3.65.2605.6 (0x0000ec8f) base=0xfa070000 size=0x4000
_IOSYS_RE = re.compile(
    r"IOSYS:\s+'([^']+)'.*?\(0x([0-9a-fA-F]+)\)\s+"
    r"base=0x([0-9a-fA-F]+)\s+size=0x([0-9a-fA-F]+)")

# boot!pe_stage: staged FASTFAT.SYS at phys 0x7D6000 (base=0x807D6000 size=0x1E040 ...)
_STAGED_RE = re.compile(
    r"staged\s+(\S+)\s+at phys\s+0x[0-9a-fA-F]+\s+"
    r"\(base=0x([0-9a-fA-F]+)\s+size=0x([0-9a-fA-F]+)")


class Module:
    """One loaded module: name + runtime placement, filled in later with
    its .dwf path, PE ImageBase and parsed line table."""

    __slots__ = ("name", "stem", "base", "size", "checksum",
                 "dwf", "imagebase", "lines", "table", "addrs",
                 "funcs", "func_los", "func_count")

    def __init__(self, name, base, size, checksum=None):
        self.name      = name
        self.stem      = os.path.splitext(name)[0].lower()
        self.base      = base
        self.size      = size
        self.checksum  = checksum
        self.dwf       = None      # path to <stem>.dwf
        self.imagebase = None      # PE preferred ImageBase
        self.lines     = None      # set of (source_path, line) -- denominator
        self.table     = None      # sorted [(addr, path_or_None, line_or_None)]
        self.addrs     = None      # parallel [addr] for bisect lookup

    @property
    def end(self):
        return self.base + self.size


def parse_modules(serial_path):
    """Build the module map from the serial log.  `IOSYS:` lines are
    authoritative (they cover the kernel's disk-loaded drivers too); a
    `staged` line is used only for a name `IOSYS:` did not report."""
    mods = {}
    staged = {}
    with open(serial_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = _IOSYS_RE.search(line)
            if m:
                name, chk, base, size = m.groups()
                if name not in mods:
                    mods[name] = Module(name, int(base, 16), int(size, 16),
                                        int(chk, 16))
                continue
            m = _STAGED_RE.search(line)
            if m:
                name, base, size = m.groups()
                staged.setdefault(name, (int(base, 16), int(size, 16)))

    # Fold in staged-only modules (matched on stem, IOSYS casing varies).
    have = {mod.stem for mod in mods.values()}
    for name, (base, size) in staged.items():
        stem = os.path.splitext(name)[0].lower()
        if stem not in have:
            mods[name] = Module(name, base, size)
            have.add(stem)

    return list(mods.values())


# ---------------------------------------------------------------------------
# Locating the .dwf and its PE ImageBase
# ---------------------------------------------------------------------------

def index_dwf(src_root):
    """Map lowercased stem -> .dwf path for every .dwf in the tree.  On a
    stem collision the newest file wins (stale build outputs lose)."""
    index = {}
    for dirpath, _, files in os.walk(src_root):
        for fn in files:
            if fn.lower().endswith(".dwf"):
                stem = os.path.splitext(fn)[0].lower()
                path = os.path.join(dirpath, fn)
                old = index.get(stem)
                if old is None or os.path.getmtime(path) > os.path.getmtime(old):
                    index[stem] = path
    return index


def pe_imagebase(dwf_path):
    """Read the preferred ImageBase from the PE sitting next to the .dwf
    (same dir, same stem, .sys/.exe/.dll).  Returns None if not found."""
    dwf_dir  = os.path.dirname(dwf_path)
    dwf_stem = os.path.splitext(os.path.basename(dwf_path))[0].lower()
    for fn in os.listdir(dwf_dir):
        stem, ext = os.path.splitext(fn)
        if stem.lower() == dwf_stem and ext.lower() in PE_EXTS:
            with open(os.path.join(dwf_dir, fn), "rb") as f:
                data = f.read(1024)
            e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
            if data[e_lfanew:e_lfanew + 4] != b"PE\0\0":
                continue
            # PE32 optional header: ImageBase at offset 0x1C, i.e. file
            # offset e_lfanew + 4 (sig) + 20 (COFF header) + 0x1C.
            return struct.unpack_from("<I", data, e_lfanew + 0x18 + 0x1C)[0]
    return None


# ---------------------------------------------------------------------------
# DWARF line table -- via `readelf --debug-dump=rawline`
# ---------------------------------------------------------------------------

def read_line_table(dwf_path):
    """Parse the .dwf line table.

    rawline is the authoritative dump: per compilation unit it carries
    the directory + file-name tables (the absolute build paths the
    converter baked in) followed by the line-number program.  Walking it
    gives an exact source path for every row -- no basename guessing.

    Returns (table, addrs, lines):
      table -- sorted [(addr, path, line)]; an end-of-sequence row is
               (addr, None, None) so a lookup landing past a sequence
               resolves to a gap rather than the wrong line.
      addrs -- parallel list of just the addresses, for bisect lookup
               (the table tuples can't be compared -- they hold None).
      lines -- set of (path, line): the lcov denominator.
    """
    out = subprocess.run(
        ["readelf", "--debug-dump=rawline", dwf_path],
        capture_output=True, text=True, check=True).stdout

    table = []
    lines = set()
    mode  = None                  # 'dir' | 'file' | 'stmt'
    dirs  = {}                    # per-CU directory index -> repo path
    files = {}                    # per-CU file index -> source path
    addr, line, cur_file = 0, 1, 1

    def emit():
        path = files.get(cur_file)
        if path is not None:
            table.append((addr, path, line))
            lines.add((path, line))

    for raw in out.splitlines():
        t = raw.strip()
        if "The Directory Table" in t:
            mode, dirs = "dir", {}
            continue
        if "The File Name Table" in t:
            mode, files = "file", {}
            continue
        if t == "Line Number Statements:":
            mode, addr, line, cur_file = "stmt", 0, 1, 1
            continue

        if mode == "dir":
            toks = t.split()
            if toks and toks[0].isdigit():
                dirs[int(toks[0])] = _relpath(" ".join(toks[1:]))
        elif mode == "file":
            # Row: Entry  Dir  Time  Size  Name  (a leading 'Entry' header
            # row and blank lines fall through harmlessly).
            toks = t.split()
            if len(toks) >= 5 and toks[0].isdigit():
                d      = dirs.get(int(toks[1]))
                name   = " ".join(toks[4:])
                path   = (d + "/" + name) if d else _relpath(name)
                files[int(toks[0])] = _canon_case(path)
        elif mode == "stmt":
            body = raw.partition("]")[2].strip()
            if not body:
                continue
            if body.startswith("Special opcode"):
                addr = int(body.split("to 0x")[1].split()[0], 16)
                if "Line by" in body:
                    line = int(body.rsplit("to ", 1)[1].split()[0])
                emit()
            elif body == "Copy" or body.startswith("Copy "):
                emit()
            elif body.startswith("Advance PC") and "to 0x" in body:
                addr = int(body.split("to 0x")[1].split()[0], 16)
            elif body.startswith("Advance Line"):
                line = int(body.rsplit("to ", 1)[1].split()[0])
            elif body.startswith("Set File Name to entry"):
                cur_file = int(body.split("entry ")[1].split()[0])
            elif "set Address to 0x" in body:
                addr = int(body.split("to 0x")[1].split()[0], 16)
            elif "End of Sequence" in body:
                table.append((addr, None, None))
                addr, line, cur_file = 0, 1, 1

    table.sort(key=lambda e: e[0])
    return table, [e[0] for e in table], lines


def lookup_line(table, addrs, addr):
    """Resolve a dwf-space address to (path, line), or None if it falls
    in a gap between sequences."""
    i = bisect.bisect_right(addrs, addr) - 1
    if i < 0:
        return None
    _, path, line = table[i]
    if path is None:                                   # past end of seq
        return None
    return path, line


# ---------------------------------------------------------------------------
# DWARF function symbols -- via `readelf -sW`
# ---------------------------------------------------------------------------

def read_symbols(dwf_path):
    """FUNC symbols from the .dwf ELF -> sorted [(lo, hi, name)].

    dbg2dwf emits one FUNC symbol per kernel/driver function, in the
    same ImageBase-relative address space as the line table.  A symbol
    range therefore looks up against the line table (for its source
    file + opening line) and against dwf-space hit addresses (for
    execution).  Size-0 symbols -- bare asm labels -- carry no range
    and are skipped.
    """
    # errors="replace": a stray non-ASCII byte in a mangled symbol name
    # must not abort the whole symbol scan.
    out = subprocess.run(
        ["readelf", "-sW", dwf_path],
        capture_output=True, text=True, errors="replace", check=True).stdout

    funcs = {}
    for raw in out.splitlines():
        # Num: Value Size Type Bind Vis Ndx Name
        toks = raw.split()
        if len(toks) < 8 or not toks[0].rstrip(":").isdigit():
            continue
        if toks[3] != "FUNC":
            continue
        try:
            lo, size = int(toks[1], 16), int(toks[2])
        except ValueError:
            continue
        if size > 0:
            funcs[(toks[7], lo)] = (lo, lo + size, toks[7])
    return sorted(funcs.values())


# ---------------------------------------------------------------------------
# qcov trace
# ---------------------------------------------------------------------------

def parse_trace(trace_path):
    """Read the qcov trace into {instruction_addr: total_exec_count}.

    Every instruction of a block shares that block's execution count;
    counts accumulate across block records (a vaddr may be retranslated).
    """
    hits = {}
    blocks = 0
    with open(trace_path, encoding="ascii", errors="replace") as f:
        first = f.readline().strip()
        if not first.startswith("qcov-trace"):
            sys.exit("cov2lcov: %s is not a qcov trace" % trace_path)
        for line in f:
            toks = line.split()
            if len(toks) < 3:
                continue
            count = int(toks[0], 16)
            blocks += 1
            for tok in toks[2:]:
                addr = int(tok, 16)
                hits[addr] = hits.get(addr, 0) + count
    return hits, blocks


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--trace",    default=os.path.join(_COV_DIR, "qcov.trace"))
    ap.add_argument("--serial",   default=os.path.join(_COV_DIR, "serial.log"))
    ap.add_argument("--src-root", default=_SRC_ROOT)
    ap.add_argument("--out",      default=os.path.join(_COV_DIR, "coverage.info"))
    ap.add_argument("--verbose",  action="store_true",
                    help="list every module and its resolution status")
    args = ap.parse_args()

    modules = parse_modules(args.serial)
    if not modules:
        sys.exit("cov2lcov: no IOSYS/staged module lines in %s" % args.serial)

    dwf_index = index_dwf(args.src_root)

    # Resolve each module's .dwf, ImageBase and line table.
    resolved = []
    for mod in modules:
        mod.dwf = dwf_index.get(mod.stem)
        if mod.dwf is None:
            if args.verbose:
                print("  %-16s no .dwf in tree" % mod.name, file=sys.stderr)
            continue
        mod.imagebase = pe_imagebase(mod.dwf)
        if mod.imagebase is None:
            if args.verbose:
                print("  %-16s .dwf found but no sibling PE for ImageBase"
                      % mod.name, file=sys.stderr)
            continue
        mod.table, mod.addrs, mod.lines = read_line_table(mod.dwf)
        mod.funcs      = read_symbols(mod.dwf)
        mod.func_los   = [f[0] for f in mod.funcs]
        mod.func_count = [0] * len(mod.funcs)
        resolved.append(mod)
        if args.verbose:
            print("  %-16s base=0x%08x ImageBase=0x%08x slide=0x%08x  %s"
                  % (mod.name, mod.base, mod.imagebase,
                     (mod.base - mod.imagebase) & 0xFFFFFFFF,
                     os.path.relpath(mod.dwf, _REPO_ROOT)), file=sys.stderr)

    hits, blocks = parse_trace(args.trace)

    # Range index for "which module owns this executed address".
    resolved.sort(key=lambda m: m.base)
    los = [m.base for m in resolved]

    # line_cov[path][line] = max execution count seen on that line.
    line_cov = {}
    n_outside = n_no_line = n_resolved = 0

    for addr, count in hits.items():
        i = bisect.bisect_right(los, addr) - 1
        if i < 0 or addr >= resolved[i].end:
            n_outside += 1                  # firmware / unmapped
            continue
        mod = resolved[i]
        dwf_addr = (addr - mod.base + mod.imagebase) & 0xFFFFFFFF

        # Function attribution: the FUNC symbol whose range covers this
        # address ran.  Done independently of line resolution -- a
        # prologue address with no line row still proves the function
        # executed.
        j = bisect.bisect_right(mod.func_los, dwf_addr) - 1
        if j >= 0 and dwf_addr < mod.funcs[j][1] and count > mod.func_count[j]:
            mod.func_count[j] = count

        hit = lookup_line(mod.table, mod.addrs, dwf_addr)
        if hit is None:
            n_no_line += 1                  # in module, no line info (asm/INIT)
            continue
        n_resolved += 1
        bucket = line_cov.setdefault(hit[0], {})
        bucket[hit[1]] = max(bucket.get(hit[1], 0), count)

    # Seed every instrumentable line at 0 so unhit lines show in the report.
    for mod in resolved:
        for path, line in mod.lines:
            line_cov.setdefault(path, {}).setdefault(line, 0)

    # Project per-symbol execution onto source files.  A function's FN
    # line is the source line of its entry address (reusing the line
    # table); its FNDA count is the max seen anywhere in its range, so
    # FNDA > 0 exactly when the function executed.
    func_cov = {}                       # path -> {name: [line, count]}
    for mod in resolved:
        for j, (lo, _hi, name) in enumerate(mod.funcs):
            loc = lookup_line(mod.table, mod.addrs, lo)
            if loc is None:
                continue                # entry in a line-table gap (asm)
            path, line = loc
            slot = func_cov.setdefault(path, {})
            cnt  = mod.func_count[j]
            prev = slot.get(name)
            if prev is None:
                slot[name] = [line, cnt]
            elif cnt > prev[1]:         # same name twice -- keep the hit
                prev[1] = cnt

    # Emit lcov.  Files with no source on disk -- CRT and compiler-
    # runtime carry their original build paths, absent from this repo --
    # are dropped from the .info: they aren't MicroNT code, genhtml
    # can't render them, and a missing SF is a hard error under lcov
    # 2.x.  They are still listed in a sidecar (below), not lost.
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    nosrc = []                          # (path, lf, lh) -- no source in repo
    total_lf = total_lh = 0
    total_fnf = total_fnh = 0
    with open(args.out, "w") as f:
        f.write("TN:qcov\n")
        for path in sorted(line_cov):
            counts = line_cov[path]
            lf = len(counts)
            lh = sum(1 for c in counts.values() if c > 0)
            abs_path = path if os.path.isabs(path) \
                       else os.path.join(_REPO_ROOT, path)
            if not os.path.isfile(abs_path):
                nosrc.append((path, lf, lh))
                continue
            f.write("SF:%s\n" % path)
            # Functions first (FN/FNDA/FNF/FNH), ordered by source line.
            fns = func_cov.get(path, {})
            for name in sorted(fns, key=lambda n: (fns[n][0], n)):
                f.write("FN:%d,%s\n" % (fns[name][0], name))
            for name in sorted(fns, key=lambda n: (fns[n][0], n)):
                f.write("FNDA:%d,%s\n" % (fns[name][1], name))
            fnf = len(fns)
            fnh = sum(1 for v in fns.values() if v[1] > 0)
            f.write("FNF:%d\nFNH:%d\n" % (fnf, fnh))
            for line in sorted(counts):
                f.write("DA:%d,%d\n" % (line, counts[line]))
            f.write("LF:%d\nLH:%d\nend_of_record\n" % (lf, lh))
            total_lf  += lf
            total_lh  += lh
            total_fnf += fnf
            total_fnh += fnh

    # Sidecar: code that executed but has no source in the repo (mostly
    # the prebuilt CRT under /nt/private/crt32nt + compiler-runtime asm).
    # Kept out of the .info so genhtml stays happy, recorded here so the
    # excluded coverage stays visible -- importing the crt32nt source
    # tree would fold it back into the report.
    nosrc_path = os.path.splitext(args.out)[0] + ".nosrc.txt"
    if nosrc:
        with open(nosrc_path, "w") as f:
            f.write("# Executed code excluded from %s -- no source in repo.\n"
                    % os.path.basename(args.out))
            f.write("# Import the crt32nt source tree to fold these in.\n")
            f.write("# lines   hit  path\n")
            for path, lf, lh in sorted(nosrc):
                f.write("%6d %5d  %s\n" % (lf, lh, path))

    # Summary.
    pct  = (100.0 * total_lh  / total_lf)  if total_lf  else 0.0
    fpct = (100.0 * total_fnh / total_fnf) if total_fnf else 0.0
    print("cov2lcov: %d modules in map, %d resolved (.dwf + ImageBase)"
          % (len(modules), len(resolved)), file=sys.stderr)
    print("cov2lcov: %d blocks, %d distinct addrs -- %d resolved to a line, "
          "%d in a module without line info, %d outside all modules"
          % (blocks, len(hits), n_resolved, n_no_line, n_outside),
          file=sys.stderr)
    print("cov2lcov: %.1f%% line coverage (%d / %d) across %d files -> %s"
          % (pct, total_lh, total_lf, len(line_cov) - len(nosrc), args.out),
          file=sys.stderr)
    print("cov2lcov: %.1f%% function coverage (%d / %d)"
          % (fpct, total_fnh, total_fnf), file=sys.stderr)
    if nosrc:
        print("cov2lcov: %d files executed but excluded (no source) -> %s"
              % (len(nosrc), nosrc_path), file=sys.stderr)


if __name__ == "__main__":
    main()
