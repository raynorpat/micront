"""
gdb_nt.py — NT 3.5 introspection commands under the `nt` namespace.

Sourced by `make gdb` and `agent_run.sh`.  Everything you'd ask gdb
about NT state lives here, organised as `nt <subcommand>`.

Subcommand groups (use `help nt` for the live list, or `help nt <name>`
for usage):

  state walks   nt process / thread / handles / objects / devstack / modules
  decoders      nt status <code|name>
  CPU snapshot  nt regs / stack / frame / seh / pcr / trapframe / iret / bugcheck
  symbols       nt addsym <name> <base>  /  nt findsym <addr>
  logs          nt decode [logfile]

Replaces the older gdb_drivers.py + gdb_users.py + the `define`-style
macros from gdb.init.  Single file by design — implementations are
short, helpers are shared, and one `make gdb` source line beats three.
"""

import gdb
import os
import re
import struct
import subprocess
import sys


# ----- module paths -----------------------------------------------------
_THIS_DIR  = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.dirname(os.path.dirname(_THIS_DIR))
SRC_ROOT   = os.path.join(_REPO_ROOT, "src")
NTSTATUS_H = os.path.join(_REPO_ROOT, "src", "NT", "PUBLIC", "SDK", "INC",
                          "NTSTATUS.H")
DECODE_AV  = os.path.join(_REPO_ROOT, "src", "tools", "decode_av.py")

# KPCR is at a fixed VA in NT 3.5 kernel mode.  Mirrors $kpcr in gdb.init.
KPCR_VA = 0xFFDFF000

PE_EXTS = (".exe", ".dll", ".sys", ".EXE", ".DLL", ".SYS")

# NT 3.5 _LDR_DATA_TABLE_ENTRY layout (NTLDR.H).  Same offsets work for
# kernel-mode (PsLoadedModuleList) and user-mode (PEB->Ldr->...) chains.
LDR_OFF_DLLBASE             = 0x18
LDR_OFF_BASEDLLNAME_LENGTH  = 0x2c
LDR_OFF_BASEDLLNAME_BUFFER  = 0x30


# ----- low-level memory helpers ----------------------------------------
def _read_u32(addr: int) -> int:
    raw = gdb.selected_inferior().read_memory(addr & 0xFFFFFFFF, 4).tobytes()
    return struct.unpack("<I", raw)[0]


def _read_u16(addr: int) -> int:
    raw = gdb.selected_inferior().read_memory(addr & 0xFFFFFFFF, 2).tobytes()
    return struct.unpack("<H", raw)[0]


def _read_unicode_string(buf_va: int, length: int) -> str:
    if buf_va == 0 or length == 0:
        return ""
    raw = gdb.selected_inferior().read_memory(buf_va & 0xFFFFFFFF,
                                              length).tobytes()
    try:
        return raw.decode("utf-16-le")
    except UnicodeDecodeError:
        return raw.hex()


def _reg(name: str) -> int:
    """Read a 32-bit register value, masking out the upper 32 bits gdb
    reports in x86_64-on-i386-code mode."""
    return int(gdb.parse_and_eval("$" + name)) & 0xFFFFFFFF


def _info_symbol(addr: int) -> None:
    """Print `info symbol <addr>` inline (one line)."""
    gdb.execute("info symbol 0x%x" % (addr & 0xFFFFFFFF), to_string=False)


# ----- PE inspection (used by symbols subcommands) ---------------------
def _read_pe_image_base_and_code(pe_path: str):
    """Return (image_base, code_lo_rva, code_hi_rva) for a PE32 file."""
    try:
        with open(pe_path, "rb") as f:
            data = f.read()
    except OSError:
        return None
    if data[:2] != b"MZ":
        return None
    try:
        e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
        if data[e_lfanew:e_lfanew + 4] != b"PE\x00\x00":
            return None
        n_sec    = struct.unpack_from("<H", data, e_lfanew + 6)[0]
        size_opt = struct.unpack_from("<H", data, e_lfanew + 20)[0]
        opt_off  = e_lfanew + 24
        if struct.unpack_from("<H", data, opt_off)[0] != 0x10B:   # PE32 only
            return None
        image_base = struct.unpack_from("<I", data, opt_off + 28)[0]
        sec_off    = opt_off + size_opt
        code_lo, code_hi = None, None
        for i in range(n_sec):
            base  = sec_off + 40 * i
            vsize = struct.unpack_from("<I", data, base + 8)[0]
            rva   = struct.unpack_from("<I", data, base + 12)[0]
            chars = struct.unpack_from("<I", data, base + 36)[0]
            if chars & 0x60000020:
                code_lo = rva if code_lo is None else min(code_lo, rva)
                code_hi = rva + vsize if code_hi is None else max(code_hi, rva + vsize)
        if code_lo is None:
            return None
    except (struct.error, IndexError):
        return None
    return image_base, code_lo, code_hi


def _find_pe_in_tree(name: str):
    """Return (pe_path, dwf_path) or None.  Case-insensitive name match."""
    name_lc = name.lower()
    for dirpath, _dirs, files in os.walk(SRC_ROOT):
        for fn in files:
            if fn.lower() != name_lc:
                continue
            if not fn.lower().endswith(PE_EXTS[:3]):
                continue
            pe = os.path.join(dirpath, fn)
            stem, _ext = os.path.splitext(fn)
            for dwf_cand in (stem + ".dwf", stem + ".DWF",
                             stem.lower() + ".dwf", stem.upper() + ".DWF"):
                dwf = os.path.join(dirpath, dwf_cand)
                if os.path.exists(dwf):
                    return pe, dwf
    return None


# ============================================================
# nt — prefix command
# ============================================================
class NtCmd(gdb.Command):
    """NT 3.5 introspection commands.

    Subcommand groups:
      state walks   nt process / thread / handles / objects / devstack / modules
      decoders      nt status
      CPU snapshot  nt regs / stack / frame / seh / pcr / trapframe / iret / bugcheck
      symbols       nt addsym / findsym
      logs          nt decode
    """

    def __init__(self):
        super().__init__("nt", gdb.COMMAND_USER, gdb.COMPLETE_NONE,
                         prefix=True)

    def invoke(self, argument, from_tty):
        gdb.execute("help nt", to_string=False)


# ============================================================
# CPU snapshot — formatted views of register / stack / frame state
# ============================================================
class NtRegsCmd(gdb.Command):
    """nt regs: register dump (32-bit-formatted from x86_64 gdbstub)."""

    def __init__(self):
        super().__init__("nt regs", gdb.COMMAND_USER)

    def invoke(self, argument, from_tty):
        print("EIP=%08x  ESP=%08x  EBP=%08x  CR2=%08x"
              % (_reg("rip"), _reg("rsp"), _reg("rbp"), _reg("cr2")))
        print("EAX=%08x  EBX=%08x  ECX=%08x  EDX=%08x"
              % (_reg("rax"), _reg("rbx"), _reg("rcx"), _reg("rdx")))
        print("ESI=%08x  EDI=%08x  CS=%04x SS=%04x DS=%04x FS=%04x"
              % (_reg("rsi"), _reg("rdi"),
                 int(gdb.parse_and_eval("$cs")),
                 int(gdb.parse_and_eval("$ss")),
                 int(gdb.parse_and_eval("$ds")),
                 int(gdb.parse_and_eval("$fs"))))


class NtStackCmd(gdb.Command):
    """nt stack [N]: dump N (default 32) dwords from current ESP."""

    def __init__(self):
        super().__init__("nt stack", gdb.COMMAND_USER)

    def invoke(self, argument, from_tty):
        n = 32
        a = argument.strip()
        if a:
            try:
                n = int(a, 0)
            except ValueError:
                print("usage: nt stack [N]"); return
        gdb.execute("x/%dxw $rsp" % n)


class NtFrameCmd(gdb.Command):
    """nt frame: walk saved EBPs to show the call chain.

    Manual unwind via [ebp+0]/[ebp+4]; stops at chain end or 16 frames.
    Useful when DWARF unwind misses (raw int handler, asm prologue).
    For most cases plain `bt` is what you want — DWARF .debug_frame
    is correct for the vast majority of kernel functions.
    """

    def __init__(self):
        super().__init__("nt frame", gdb.COMMAND_USER)

    def invoke(self, argument, from_tty):
        print("EBP chain (manual unwind):")
        ebp = _reg("rbp")
        for i in range(16):
            if ebp == 0:
                break
            try:
                next_ebp = _read_u32(ebp)
                ret_ip   = _read_u32(ebp + 4)
            except gdb.MemoryError:
                print("  #%d  ebp=0x%08x  <unreadable>" % (i, ebp))
                break
            print("  #%d  ebp=0x%08x  saved-eip=0x%08x  " % (i, ebp, ret_ip),
                  end="")
            try:
                _info_symbol(ret_ip)
            except gdb.error:
                print()
            ebp = next_ebp


class NtPcrCmd(gdb.Command):
    """nt pcr: KPCR fields (verifies KPCR mapping, dumps key globals)."""

    def __init__(self):
        super().__init__("nt pcr", gdb.COMMAND_USER)

    def invoke(self, argument, from_tty):
        try:
            self_addr = _read_u32(KPCR_VA + 0x1C)
        except gdb.MemoryError:
            print("KPCR @ 0x%08x: unreadable" % KPCR_VA); return
        if self_addr != KPCR_VA:
            print("KPCR.Self=0x%08x doesn't match expected 0x%08x"
                  % (self_addr, KPCR_VA))
            print("  KPCR_VA in gdb_nt.py may need updating")
            return
        print("KPCR @ 0x%08x:" % KPCR_VA)
        print("  ExceptionList (SEH head)  0x%08x" % _read_u32(KPCR_VA + 0x00))
        print("  StackLimit                0x%08x" % _read_u32(KPCR_VA + 0x08))
        print("  Self                      0x%08x" % self_addr)
        print("  Prcb                      0x%08x" % _read_u32(KPCR_VA + 0x20))


class NtSehCmd(gdb.Command):
    """nt seh: walk the SEH chain from KPCR.NtTib.ExceptionList."""

    def __init__(self):
        super().__init__("nt seh", gdb.COMMAND_USER)

    def invoke(self, argument, from_tty):
        rec = _read_u32(KPCR_VA + 0x00)
        print("SEH chain (KPCR @ 0x%08x):" % KPCR_VA)
        if rec in (0, 0xFFFFFFFF):
            print("  (empty)")
            return
        for i in range(32):
            if rec in (0, 0xFFFFFFFF):
                break
            try:
                next_rec = _read_u32(rec)
                handler  = _read_u32(rec + 4)
            except gdb.MemoryError:
                print("  [%d] rec=0x%08x  <unreadable>" % (i, rec))
                break
            print("  [%d] rec=0x%08x  handler=0x%08x  " % (i, rec, handler),
                  end="")
            try:
                _info_symbol(handler)
            except gdb.error:
                print()
            rec = next_rec


class NtTrapframeCmd(gdb.Command):
    """nt trapframe <addr>: decode KTRAP_FRAME at <addr>.

    Field offsets from KS386.INC (canonical struct-offset header genied
    in lock-step with NTOS/KE).  Total length 0x8C.
    """

    def __init__(self):
        super().__init__("nt trapframe", gdb.COMMAND_USER)

    def invoke(self, argument, from_tty):
        a = argument.strip()
        if not a:
            print("usage: nt trapframe <addr>"); return
        try:
            tf = int(a, 0) & 0xFFFFFFFF
        except ValueError:
            print("nt trapframe: can't parse '%s' as address" % a); return
        try:
            print("KTRAP_FRAME @ 0x%08x" % tf)
            print("  EIP=%08x  CS=%04x  EFlags=%08x"
                  % (_read_u32(tf + 0x68), _read_u32(tf + 0x6C) & 0xFFFF,
                     _read_u32(tf + 0x70)))
            print("  ESP=%08x  SS=%04x  EBP=%08x"
                  % (_read_u32(tf + 0x74), _read_u32(tf + 0x78) & 0xFFFF,
                     _read_u32(tf + 0x60)))
            print("  EAX=%08x  EBX=%08x  ECX=%08x  EDX=%08x"
                  % (_read_u32(tf + 0x44), _read_u32(tf + 0x5C),
                     _read_u32(tf + 0x40), _read_u32(tf + 0x3C)))
            print("  ESI=%08x  EDI=%08x  ErrCode=%08x"
                  % (_read_u32(tf + 0x58), _read_u32(tf + 0x54),
                     _read_u32(tf + 0x64)))
            print("  GS=%04x FS=%04x ES=%04x DS=%04x"
                  % (_read_u32(tf + 0x30) & 0xFFFF,
                     _read_u32(tf + 0x50) & 0xFFFF,
                     _read_u32(tf + 0x34) & 0xFFFF,
                     _read_u32(tf + 0x38) & 0xFFFF))
            print("  ExceptionList=%08x  PrevPrevMode=%08x"
                  % (_read_u32(tf + 0x4C), _read_u32(tf + 0x48)))
            print("  resolved EIP: ", end="")
            _info_symbol(_read_u32(tf + 0x68))
        except gdb.MemoryError as e:
            print("  <unreadable: %s>" % e)


class NtIretCmd(gdb.Command):
    """nt iret: decode the iret return frame at top of stack.

    Useful when stepping past an interrupt handler — shows where
    execution will jump back to (CS:EIP, EFlags, SS:ESP if cross-priv).
    """

    def __init__(self):
        super().__init__("nt iret", gdb.COMMAND_USER)

    def invoke(self, argument, from_tty):
        sp = _reg("rsp")
        try:
            print("iret frame @ 0x%08x:" % sp)
            print("  EIP    = %08x  " % _read_u32(sp), end="")
            _info_symbol(_read_u32(sp))
            print("  CS     = %04x" % (_read_u32(sp + 4) & 0xFFFF))
            print("  EFlags = %08x" % _read_u32(sp + 8))
            print("  ESP    = %08x  (if priv-change)" % _read_u32(sp + 12))
            print("  SS     = %04x  (if priv-change)"
                  % (_read_u32(sp + 16) & 0xFFFF))
        except gdb.MemoryError as e:
            print("  <unreadable: %s>" % e)


_BUGCHECK_NAMES = {
    0x0000000A: "IRQL_NOT_LESS_OR_EQUAL",
    0x0000001E: "KMODE_EXCEPTION_NOT_HANDLED",
    0x0000003B: "SYSTEM_SERVICE_EXCEPTION",
    0x00000050: "PAGE_FAULT_IN_NONPAGED_AREA",
    0x0000007B: "INACCESSIBLE_BOOT_DEVICE",
    0x0000007F: "UNEXPECTED_KERNEL_MODE_TRAP",
    0x000000C2: "BAD_POOL_CALLER",
    0x000000C5: "DRIVER_CORRUPTED_EXPOOL",
    0x000000D1: "DRIVER_IRQL_NOT_LESS_OR_EQUAL",
    0xCAFE5E1F: "KI_SEH_GUARD_BUGCHECK (MicroNT)",
}


class NtBugcheckCmd(gdb.Command):
    """nt bugcheck: decode KeBugCheckEx args at frame entry.

    Use when stopped at the entry of `KeBugCheckEx`: stdcall pushed
    Code + 4 params right-to-left, so [esp+4..20] hold them.
    """

    def __init__(self):
        super().__init__("nt bugcheck", gdb.COMMAND_USER)

    def invoke(self, argument, from_tty):
        sp = _reg("rsp")
        try:
            code = _read_u32(sp + 4)
            p1   = _read_u32(sp + 8)
            p2   = _read_u32(sp + 12)
            p3   = _read_u32(sp + 16)
            p4   = _read_u32(sp + 20)
            ret  = _read_u32(sp)
        except gdb.MemoryError as e:
            print("nt bugcheck: <unreadable: %s>" % e); return
        print("KeBugCheckEx call:")
        name = _BUGCHECK_NAMES.get(code, "")
        print("  Code:    0x%08x  %s" % (code, name))
        print("  Param 1: 0x%08x" % p1)
        print("  Param 2: 0x%08x" % p2)
        print("  Param 3: 0x%08x" % p3)
        print("  Param 4: 0x%08x" % p4)
        print("  Return:  0x%08x  " % ret, end="")
        _info_symbol(ret)


# ============================================================
# Decoders
# ============================================================
_status_cache: dict | None = None

_DEFINE_RE = re.compile(
    r'#define\s+(\w+)\s+\(\s*\(\s*NTSTATUS\s*\)\s*0x([0-9A-Fa-f]+)L?\s*\)'
)


def _load_ntstatus() -> dict:
    """Parse NTSTATUS.H once; return {code: (name, description)}."""
    global _status_cache
    if _status_cache is not None:
        return _status_cache
    table = {}
    if not os.path.exists(NTSTATUS_H):
        print("nt status: NTSTATUS.H not found at %s" % NTSTATUS_H)
        _status_cache = table
        return table
    try:
        with open(NTSTATUS_H, "r", encoding="latin-1") as f:
            lines = f.read().splitlines()
    except OSError as e:
        print("nt status: can't read NTSTATUS.H (%s)" % e)
        _status_cache = table
        return table
    cur_lines: list[str] = []
    in_msg = False
    pending = ""
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("// MessageText:"):
            in_msg = True
            cur_lines = []
            continue
        if in_msg:
            if stripped == "//" and cur_lines:
                in_msg = False
                pending = " ".join(s for s in cur_lines if s)
                continue
            if stripped == "//" and not cur_lines:
                continue
            if stripped.startswith("//"):
                cur_lines.append(stripped[2:].strip())
                continue
            in_msg = False
            pending = " ".join(s for s in cur_lines if s)
        m = _DEFINE_RE.search(line)
        if m:
            name = m.group(1)
            code = int(m.group(2), 16) & 0xFFFFFFFF
            table[code] = (name, pending or "")
            pending = ""
    _status_cache = table
    return table


def _decode_status_bits(code: int):
    severity = (code >> 30) & 0x3
    customer = (code >> 29) & 0x1
    facility = (code >> 16) & 0xfff
    severity_name = ["SUCCESS", "INFORMATIONAL", "WARNING", "ERROR"][severity]
    return severity, severity_name, customer, facility


class NtStatusCmd(gdb.Command):
    """nt status <code|name>: decode an NTSTATUS.

    <code> is hex (0xC0000005 or C0000005) or decimal.
    <name> is a STATUS_* symbol — case-insensitive substring match.
    """

    def __init__(self):
        super().__init__("nt status", gdb.COMMAND_USER)

    def invoke(self, argument, from_tty):
        arg = argument.strip()
        if not arg:
            print("usage: nt status <code|STATUS_*>")
            return
        tbl = _load_ntstatus()
        code = None
        try:
            code = int(arg, 0) & 0xFFFFFFFF
        except ValueError:
            try:
                code = int(arg, 16) & 0xFFFFFFFF
            except ValueError:
                pass
        if code is None:
            up = arg.upper()
            matches = [(c, n, m) for c, (n, m) in tbl.items() if up in n]
            if not matches:
                print("nt status: no NTSTATUS code or name matches '%s'" % arg)
                return
            if len(matches) > 8:
                print("nt status: %d names match '%s' — narrow the query"
                      % (len(matches), arg))
                for c, n, m in sorted(matches)[:5]:
                    print("    0x%08x  %s" % (c, n))
                print("    ... (%d more)" % (len(matches) - 5))
                return
            for c, n, m in sorted(matches):
                print("  0x%08x  %s" % (c, n))
                if m:
                    print("    %s" % m)
            return
        if code in tbl:
            name, msg = tbl[code]
            print("  0x%08x  %s" % (code, name))
            if msg:
                print("    %s" % msg)
            return
        # Severity-shifted lookup: try the same code with each upper-nibble
        # value.  STATUS_UNHANDLED_EXCEPTION at 0xC0000144 may be raised
        # as 0xD0000144 with bit 28 (hard-error flag) OR'd in.
        base = code & 0x0FFFFFFF
        for high in range(16):
            cand = (high << 28) | base
            if cand in tbl and cand != code:
                name, msg = tbl[cand]
                print("  0x%08x  <severity-shifted match: 0x%08x %s>"
                      % (code, cand, name))
                if msg:
                    print("    %s" % msg)
                sev, sev_name, cust, fac = _decode_status_bits(code)
                print("    raw bits: severity=%d (%s)  facility=0x%03x  customer=%s"
                      % (sev, sev_name, fac, "set" if cust else "clear"))
                return
        sev, sev_name, cust, fac = _decode_status_bits(code)
        print("  0x%08x  <unknown NTSTATUS>" % code)
        print("    severity=%d (%s)  facility=0x%03x  customer=%s"
              % (sev, sev_name, fac, "set" if cust else "clear"))


# ============================================================
# State walks — read NT kernel structures
# ============================================================
class NtModulesCmd(gdb.Command):
    """nt modules: walk PsLoadedModuleList; add-symbol-file each entry's .dwf.

    Lists every kernel module (ntoskrnl + hal + every loaded driver)
    and loads its symbols at the runtime DllBase.  ntoskrnl + hal are
    skipped from add-symbol-file (already loaded by `make gdb`); other
    modules get loaded with offset = (runtime DllBase) - (PE ImageBase).

    Requires: kernel past IoInitSystem (else PsLoadedModuleList is empty).
    """

    DEFAULT_DWF_DIR = os.path.join(_REPO_ROOT, "src", "NT", "PUBLIC",
                                   "SDK", "LIB", "I386")

    def __init__(self):
        super().__init__("nt modules", gdb.COMMAND_USER)

    def invoke(self, argument, from_tty):
        try:
            head_addr = int(gdb.parse_and_eval("&PsLoadedModuleList"))
        except gdb.error as e:
            print("nt modules: PsLoadedModuleList unresolved (%s)" % e)
            return

        cur     = _read_u32(head_addr)
        loaded  = 0
        skipped: list[str] = []
        guard   = 0
        dwf_dir = os.environ.get("MICRONT_DWF_DIR", self.DEFAULT_DWF_DIR)

        while cur != head_addr and guard < 256:
            try:
                base       = _read_u32(cur + LDR_OFF_DLLBASE)
                name_len   = _read_u16(cur + LDR_OFF_BASEDLLNAME_LENGTH)
                name_buf   = _read_u32(cur + LDR_OFF_BASEDLLNAME_BUFFER)
                name       = _read_unicode_string(name_buf, name_len)
                next_flink = _read_u32(cur)
            except gdb.error as e:
                print("  warn: bad LDR entry at 0x%x (%s)" % (cur, e))
                break
            if name and base:
                if name.lower() not in ("ntoskrnl.exe", "hal.dll"):
                    loaded += 1
                self._add_one(name, base, skipped, dwf_dir)
            cur = next_flink
            guard += 1

        print("nt modules: walked %d entries, added symbols for %d"
              % (loaded, loaded - len(skipped)))
        for s in skipped:
            print("  skipped: %s" % s)

    def _add_one(self, name: str, runtime_base: int,
                 skipped: list, dwf_dir: str) -> None:
        if name.lower() in ("ntoskrnl.exe", "hal.dll"):
            return
        stem = os.path.splitext(name)[0]
        pe   = os.path.join(dwf_dir, name)
        dwf  = os.path.join(dwf_dir, stem + ".dwf")
        if not os.path.exists(dwf):
            skipped.append("%s (no .dwf)" % name)
            return
        info = _read_pe_image_base_and_code(pe) if os.path.exists(pe) else None
        if info is None:
            skipped.append("%s (no PE base)" % name)
            return
        pe_base = info[0]
        slide = (runtime_base - pe_base) & 0xffffffff
        cmd = "add-symbol-file %s -o 0x%x" % (dwf, slide)
        print("  %s @ DllBase=0x%x  pe_base=0x%x  slide=0x%x"
              % (name, runtime_base, pe_base, slide))
        gdb.execute(cmd, to_string=True)


class _NtTodoCmd(gdb.Command):
    """Stub for not-yet-implemented `nt` subcommands."""

    def __init__(self, name: str, planned: str):
        super().__init__("nt " + name, gdb.COMMAND_USER)
        self._planned = planned

    def invoke(self, argument, from_tty):
        print("nt %s: %s" % (self.__doc__ or "", self._planned))


class NtProcessCmd(gdb.Command):
    """nt process [count]: walk PsActiveProcessHead, list EPROCESS entries.

    NOT YET IMPLEMENTED — planned as the foundation of nt thread / nt
    handles / nt devstack (which all anchor on EPROCESS).
    """

    def __init__(self):
        super().__init__("nt process", gdb.COMMAND_USER)

    def invoke(self, argument, from_tty):
        print("nt process: not yet implemented")
        print("  planned: walk PsActiveProcessHead → EPROCESS list")
        print("  output:  PID, ImageFileName, dir base, thread count, handles")


class NtThreadCmd(gdb.Command):
    """nt thread <eproc>: walk that process's thread list.

    NOT YET IMPLEMENTED.  Planned to follow `nt process` by walking
    EPROCESS->Pcb.ThreadListHead, dumping wait state and kernel stack.
    """

    def __init__(self):
        super().__init__("nt thread", gdb.COMMAND_USER)

    def invoke(self, argument, from_tty):
        print("nt thread: not yet implemented")


class NtHandlesCmd(gdb.Command):
    """nt handles <eproc>: walk that process's handle table.

    NOT YET IMPLEMENTED.  Planned to walk EPROCESS->ObjectTable.
    """

    def __init__(self):
        super().__init__("nt handles", gdb.COMMAND_USER)

    def invoke(self, argument, from_tty):
        print("nt handles: not yet implemented")


class NtObjectsCmd(gdb.Command):
    """nt objects [path]: walk the object namespace.

    NOT YET IMPLEMENTED.  Planned to walk OBJECT_DIRECTORY trees from
    the root `\\` directory (or a user-supplied subdir).
    """

    def __init__(self):
        super().__init__("nt objects", gdb.COMMAND_USER)

    def invoke(self, argument, from_tty):
        print("nt objects: not yet implemented")


class NtDevstackCmd(gdb.Command):
    """nt devstack <devobj>: follow the AttachedDevice chain.

    NOT YET IMPLEMENTED.  Planned to walk DEVICE_OBJECT->AttachedDevice
    until NULL, printing the driver name at each layer.
    """

    def __init__(self):
        super().__init__("nt devstack", gdb.COMMAND_USER)

    def invoke(self, argument, from_tty):
        print("nt devstack: not yet implemented")


# ============================================================
# Symbols — load .dwf at the right runtime address
# ============================================================
def _add_symbols(pe_path: str, dwf_path: str, runtime_base: int) -> bool:
    info = _read_pe_image_base_and_code(pe_path)
    if info is None:
        print("nt addsym: %s is not a PE32 we can read" % pe_path)
        return False
    pe_base, _lo, _hi = info
    slide = (runtime_base - pe_base) & 0xFFFFFFFF
    print("  binary:        %s" % pe_path)
    print("  symbols:       %s" % dwf_path)
    print("  PE base:       0x%08x" % pe_base)
    print("  runtime base:  0x%08x" % runtime_base)
    print("  slide:         0x%x" % slide)
    cmd = "add-symbol-file %s -o 0x%x" % (dwf_path, slide)
    try:
        gdb.execute(cmd, to_string=False)
    except gdb.error as e:
        print("nt addsym: gdb rejected add-symbol-file (%s)" % e)
        return False
    return True


class NtAddsymCmd(gdb.Command):
    """nt addsym <name|path> <runtime_base>: load PE symbols at runtime base.

    <name> looks up a binary in the source tree (any matching PE+.dwf
    under src/); <path> can be supplied instead for binaries outside
    the tree.  <runtime_base> is the actual VA the binary is loaded at
    (typically read from a serial-log crash address minus PE base).

    Slides the .dwf so gdb resolves runtime addresses correctly.
    """

    def __init__(self):
        super().__init__("nt addsym", gdb.COMMAND_USER)

    def invoke(self, argument, from_tty):
        parts = argument.split()
        if len(parts) != 2:
            print("usage: nt addsym <name|path> <runtime_base>")
            return
        target, base_s = parts
        try:
            runtime_base = int(base_s, 0)
        except ValueError:
            print("nt addsym: bad runtime_base '%s'" % base_s)
            return
        # Try treat as path first; if not a file, fall back to tree scan.
        if os.path.exists(target):
            stem, _ext = os.path.splitext(target)
            for cand in (stem + ".dwf", stem + ".DWF"):
                if os.path.exists(cand):
                    _add_symbols(target, cand, runtime_base)
                    return
            print("nt addsym: no .dwf next to %s" % target)
            return
        hit = _find_pe_in_tree(target)
        if hit is None:
            print("nt addsym: no PE+.dwf found for '%s' in %s" % (target, SRC_ROOT))
            return
        pe, dwf = hit
        _add_symbols(pe, dwf, runtime_base)


class NtFindsymCmd(gdb.Command):
    """nt findsym <addr>: which PE owns this address?

    Scans every PE+.dwf under src/, prints those whose code section
    could contain `addr` (assuming common relocations: 0 slide, or
    +0xC00000 which is link.exe's pattern).  Diagnostic helper for
    serial-log addresses where you don't yet know the process.
    """

    KNOWN_RELOCATIONS = (
        0x00000000,    # not relocated
        0x00C00000,    # link.exe: PE 0x00400000 → runtime 0x01000000
    )

    def __init__(self):
        super().__init__("nt findsym", gdb.COMMAND_USER)

    def invoke(self, argument, from_tty):
        try:
            addr = int(argument.strip(), 0)
        except ValueError:
            print("usage: nt findsym <addr>")
            return
        hits = []
        for dirpath, _dirs, files in os.walk(SRC_ROOT):
            for fn in files:
                if not fn.lower().endswith(PE_EXTS[:3]):
                    continue
                pe = os.path.join(dirpath, fn)
                info = _read_pe_image_base_and_code(pe)
                if info is None:
                    continue
                pe_base, code_lo, code_hi = info
                stem, _ext = os.path.splitext(fn)
                dwf = os.path.join(dirpath, stem + ".dwf")
                has_dwf = os.path.exists(dwf)
                for slide in self.KNOWN_RELOCATIONS:
                    lo = pe_base + code_lo + slide
                    hi = pe_base + code_hi + slide
                    if lo <= addr < hi:
                        hits.append((fn, pe, dwf if has_dwf else None,
                                     pe_base, slide))
        if not hits:
            print("nt findsym: 0x%x not in any PE's code section" % addr)
            print("            (slides considered: %s)"
                  % ", ".join("0x%x" % s for s in self.KNOWN_RELOCATIONS))
            return
        for fn, pe, dwf, pe_base, slide in hits:
            slide_note = " (relocated +0x%x)" % slide if slide else ""
            print("  %s%s" % (fn, slide_note))
            print("    PE base:  0x%08x" % pe_base)
            print("    path:     %s" % pe)
            if dwf:
                print("    symbols:  %s" % dwf)
                print("    paste:    nt addsym %s 0x%08x" % (fn, pe_base + slide))
            else:
                print("    .dwf:     <missing>  (run splitsym + dbg2dwf)")


# ============================================================
# Logs
# ============================================================
class NtDecodeCmd(gdb.Command):
    """nt decode [logfile]: shell out to decode_av.py against the log.

    Symbolicates `qemu.log` (next to boot.sh by default, or the path
    you pass) inline in the gdb session.  Shows resolved frames,
    annotated heap-fill patterns, paste-ready gdb commands.
    """

    def __init__(self):
        super().__init__("nt decode", gdb.COMMAND_USER)

    def invoke(self, argument, from_tty):
        log = argument.strip() or os.path.join(SRC_ROOT, "..", "qemu.log")
        if not os.path.exists(log):
            print("nt decode: log not found: %s" % log); return
        if not os.path.exists(DECODE_AV):
            print("nt decode: %s missing" % DECODE_AV); return
        try:
            r = subprocess.run([sys.executable or "python3", DECODE_AV, log],
                               capture_output=True, text=True, timeout=60)
        except (subprocess.SubprocessError, FileNotFoundError) as e:
            print("nt decode: failed to run decode_av.py (%s)" % e); return
        if r.stdout:
            print(r.stdout, end="")
        if r.stderr:
            sys.stderr.write(r.stderr)


# ============================================================
# Register everything
# ============================================================
NtCmd()

# Decoders
NtStatusCmd()

# State walks
NtModulesCmd()
NtProcessCmd()
NtThreadCmd()
NtHandlesCmd()
NtObjectsCmd()
NtDevstackCmd()

# CPU snapshot
NtRegsCmd()
NtStackCmd()
NtFrameCmd()
NtPcrCmd()
NtSehCmd()
NtTrapframeCmd()
NtIretCmd()
NtBugcheckCmd()

# Symbols
NtAddsymCmd()
NtFindsymCmd()

# Logs
NtDecodeCmd()

print("gdb_nt.py: registered `nt` (17 subcommands; `help nt` for the list)")
