# MicroNT — CPython (win32) missing Win32 surface

Goal: run a stock Windows CPython on MicroNT. Three candidate builds are staged in
`stuff/oldstuff/`, spanning three CRT eras. Imports measured with `pefile` from the
**static import tables** of every `.exe` / `.dll` / `.pyd` in each tree (the extension
modules link their imports directly — the table is authoritative; only py3.14's
`_wmi` uses a delay-load, for `ole32`).

The headline: **the gap is dominated by the CRT era, not by CPython itself.** The
interpreter's own Win32 needs barely move across versions; what moves is the C runtime
underneath it (`msvcr71` → `msvcr90` → Universal CRT) and a tail of modern kernel32.

## The three candidates

| tree | version | CRT (bundled?) | kernel32 need | advapi32 | ws2_32 | verdict |
|------|---------|----------------|--------------:|---------:|-------:|---------|
| `py254` | 2.5.4 | `msvcr71.dll` ✅ drop-in | **1** | 3 | **0** | **works today** (RNG added → OpenSSL ok) |
| `py2718` | 2.7.18 | `msvcr90.dll` ✅ drop-in | **5** | 0 | 1 | small step (5+1 real; rest stub-to-load) |
| `python-3.14.5` | 3.14.5 | `vcruntime140` ✅ + **UCRT ❌** | **80** | 9 | 14 | major lift (UCRT + Vista sync + IOCP) |

`need` = imported but not in MicroNT's current `.def` exports (`kernel32` 608, `advapi32`
54, `ws2_32` 36, measured against the live defs). `user32`/`gdi32` deltas are **tkinter
only** (GUI; explicit non-goal, same posture as Node's console) and excluded above.

## py254 — the beachhead (already booting)

Confirmed working; the measurement explains *why* it's so close:
- **kernel32: need 1** — `HeapSize`. That's the entire core-interpreter gap.
- **ws2_32: need 0** — the socket surface (`socket`/`bind`/`recv`/.../`gethostbyname`,
  classic BSD core) is a **subset of MicroNT's existing 36-export ws2_32**. No overlapped,
  no events. This is the era our `wsock32`-derived ws2_32 was built for.
- **advapi32: need 3** — `GetUserNameA`, `InitializeSecurityDescriptor`,
  `SetSecurityDescriptorDacl` (stub-permissive for bring-up per
  `project_security_model_direction`).
- **CRT**: `msvcr71.dll` ships in-tree — a **drop-in MS binary**, no work. Every `.pyd`
  imports it; the matching VC7.1 startup path is the one already exercised by the
  `python2.5/msvcr71` bring-up (`project_spawn_env_required`).
- **OpenSSL** is **statically linked into `_ssl.pyd` / `_hashlib.pyd`** (no `libssl`/
  `libcrypto` in tree); its only external entropy need is satisfied now that the RNG path
  lands (the user-noted fix). `_ssl`/`select` pull a few symbols from `wsock32.dll`
  (`recv`/`send`/`select`/`shutdown`/`closesocket`/`__WSAFDIsSet`) — provide `wsock32` as
  a thin forwarder onto ws2_32, or add the alias exports.

**Net for py254: `HeapSize` + 3 advapi32 secdesc stubs + a `wsock32` shim.** Essentially done.

## py2718 — the working target (explicit per-file/per-symbol checklist)

**Headless module set** (what we ship; everything else dropped):
`python.exe`/`pythonw.exe` + `python27.dll` + `msvcr90.dll` (drop-in, + `Microsoft.VC90.CRT.manifest`
— loader ignores the manifest, binds the flat name) + `_socket` `_ssl` `select`
`_multiprocessing` `_ctypes` `_hashlib` `_elementtree` `bz2` `pyexpat` `unicodedata`
`_sqlite3`(+bundled `sqlite3.dll`).

**Explicitly NOT shipped** (and the surface they alone pulled): `_msi` (msi/cabinet/rpcrt4),
`winsound` (winmm), `_tkinter`+`tcl85`/`tk85` (user32/gdi32/ole/oleaut GUI), `_bsddb`
(the advapi32 SD pair + the `WSARecv`/`WSASend`/`WSAEvent*` async-socket surface),
`_testcapi`/`_ctypes_test`, `w9xpopen`. **Dropping these is what takes ws2_32 from 9→1 and
advapi32 from 6→0** — the "overlapped/event-select" surface was `_bsddb`/Tk, never the
interpreter. Headless py2.7 sockets are the *same classic blocking BSD core as py2.5* + one symbol.

### Tier 1 — real, must implement (6 symbols). This is the whole functional gap.
> `HeapSize` was a **false positive** — already exported as `kernel32.def → HeapSize = NTDLL.RtlSizeHeap`
> (RtlSizeHeap is in ntdll; heap works). The analyzer's `.def` parser skipped it: its keyword
> skip-list holds `HEAPSIZE` (a module-def *directive*) which collides with the export *name*
> `HeapSize`. Fixed in `tools/py*` analysis; same false-positive exists in the Node/Rust lists.

**`kernel32` (5)** — note 2 of 5 are demanded by the **CRT (`msvcr90`)**, not Python:
- [ ] `IsDebuggerPresent` — `msvcr90` + ~every `.pyd`. **`return FALSE;`** — NT 3.5's PEB
  (`NTPSAPI.H:117`) is the early layout with **no `BeingDebugged` field** (2nd member is `Mutant`),
  so there's nothing to read. One-liner, final.
- [ ] `GetFileAttributesExW` — `python27.dll`, `sqlite3.dll` (`os.stat` → needs **size**).
  **Has a tail:** real impl uses `NtQueryFullAttributesFile` (→ `FILE_NETWORK_OPEN_INFORMATION`:
  times + `EndOfFile`), which **does not exist in MicroNT** (you only have `NtQueryAttributesFile`
  = basic info, *no size*; used by current `GetFileAttributesW` at `FILEMISC.C:316`). **Restore the
  `NtQueryFullAttributesFile` syscall** (original NT 3.1+, stripped under import-only-what-you-build;
  kernel body = the `NtQueryAttributesFile` path with `FileNetworkOpenInformation`), then port the
  wrapper verbatim from srv03.
- [ ] `GetFileAttributesExA` — `python27.dll`. `UNICODE_STRING` thunk over the W form (mirror
  the existing `GetFileAttributesA`, `FILEMISC.C:205`).
- [ ] `InitializeCriticalSectionAndSpinCount` — `msvcr90` (CRT). **~3-line no-op wrapper** over
  `RtlInitializeCriticalSection`: NT 3.5's `RTL_CRITICAL_SECTION` (`NTURTL.H:50`) has **no SpinCount
  field** (last member is `Reserved`; SpinCount is 3.51/4.0+). Spin only helps on MP — dropping it is
  legal. Add `RtlInitializeCriticalSectionAndSpinCount` (C) in `NTOS/DLL/RESOURCE.C`; kernel32 forwards.
- [ ] `TryEnterCriticalSection` — `sqlite3.dll`. Add `RtlTryEnterCriticalSection` as **C in
  `NTOS/DLL/RESOURCE.C`** (non-blocking → no asm). **Careful:** match the exact `LockCount` sign
  convention used by the asm fast paths in `NTOS/DLL/I386/CRITSECT.ASM` (NT-3.5: `-1 == free`,
  increment-to-acquire) or you corrupt locks Enter/Leave then mishandle. Port srv03 `resource.c`'s
  TryEnter re-encoded to that convention; kernel32 forwards. **Do NOT lift srv03's Enter/Leave** —
  they wait on keyed events MicroNT lacks; keep MicroNT's `LockSemaphore` path.

**`ws2_32` (1)** — the only net-new socket symbol; you already have the BSD core + `ioctlsocket`/`select`:
- [ ] `WSAIoctl` — `_socket.pyd` (`socket.ioctl()`). **Synchronous-only scope:** py2.7 only issues
  `SIO_KEEPALIVE_VALS` (→ AFD per-socket keepalive; real, small) and `SIO_RCVALL` (→ `WSAEOPNOTSUPP`;
  no promiscuous on a single-NIC non-router host, `deployment_scope`), always `lpOverlapped=NULL`.
  **Trap:** `WSAIoctl` is also the gateway for `SIO_GET_EXTENSION_FUNCTION_POINTER` (AcceptEx/ConnectEx)
  and overlapped/IOCP IOCTLs — **explicitly reject those here** so this one symbol can't pull in the
  `MODERN-IPSTACK.md`/mswsock overlapped stack.

NOTE: on Python 2.5 the only code that uses WSAIoctl is:

See: https://github.com/pzxbc/python2/blob/5ac6d4d74c716e9455b3b3df14f575e75927f41e/Modules/socketmodule.c#L3043

```c
static PyObject*
sock_ioctl(PySocketSockObject *s, PyObject *arg)
{
    unsigned long cmd = SIO_RCVALL;
    PyObject *argO;
    DWORD recv;

    if (!PyArg_ParseTuple(arg, "kO:ioctl", &cmd, &argO))
        return NULL;

    switch (cmd) {
    case SIO_RCVALL: {
        unsigned int option = RCVALL_ON;
        if (!PyArg_ParseTuple(arg, "kI:ioctl", &cmd, &option))
            return NULL;
        if (WSAIoctl(s->sock_fd, cmd, &option, sizeof(option),
                         NULL, 0, &recv, NULL, NULL) == SOCKET_ERROR) {
            return set_error();
        }
        return PyLong_FromUnsignedLong(recv); }
    case SIO_KEEPALIVE_VALS: {
        struct tcp_keepalive ka;
        if (!PyArg_ParseTuple(arg, "k(kkk):ioctl", &cmd,
                        &ka.onoff, &ka.keepalivetime, &ka.keepaliveinterval))
            return NULL;
        if (WSAIoctl(s->sock_fd, cmd, &ka, sizeof(ka),
                         NULL, 0, &recv, NULL, NULL) == SOCKET_ERROR) {
            return set_error();
        }
        return PyLong_FromUnsignedLong(recv); }
    default:
        PyErr_Format(PyExc_ValueError, "invalid ioctl command %d", cmd);
        return NULL;
    }
}
```

### Tier 2 — must *resolve* so the `.pyd` maps, but inert on the headless path (stubs)
**OpenSSL `RAND_screen()` entropy fallback** — `_ssl.pyd` **and** `_hashlib.pyd` link the same
`rand_win.c`; it screenshots the desktop to hash pixels for seed. **Dead under our RNG**
(`project_rng_subsystem`) — stub to fail and OpenSSL uses the real `RAND_bytes` source:
- [ ] `user32!GetDC` — `_ssl.pyd`, `_hashlib.pyd`  *(the other OpenSSL user32 imports —
  `GetProcessWindowStation`/`GetUserObjectInformationW`/`MessageBoxA` — are already in our 49)*
- [ ] `user32!ReleaseDC` — `_ssl.pyd`, `_hashlib.pyd`
- [ ] `gdi32!CreateCompatibleBitmap` — `_ssl.pyd`, `_hashlib.pyd`
- [ ] `gdi32!GetDIBits` — `_ssl.pyd`, `_hashlib.pyd`
- [ ] `gdi32!GetDeviceCaps` — `_ssl.pyd`, `_hashlib.pyd`
- [ ] `gdi32!GetObjectA` — `_ssl.pyd`, `_hashlib.pyd`
- [ ] `gdi32!DeleteObject` — `_ssl.pyd`, `_hashlib.pyd`

**`crypt32` (7), `_ssl.pyd`** — Windows system cert store for `ssl.create_default_context()`.
Stub to an empty store (`ssl` still works with explicit `cafile=`/`CERT_NONE`); real impl
later, shared with Go/Node:
- [ ] `CertOpenStore`  [ ] `CertCloseStore`  [ ] `CertEnumCertificatesInStore`
  [ ] `CertEnumCRLsInStore`  [ ] `CertFreeCertificateContext`  [ ] `CertFreeCRLContext`
  [ ] `CertGetEnhancedKeyUsage`

**ctypes COM support** — `_ctypes.pyd`; basic ctypes (cdll/windll/structs) never calls these,
needed only to load the module:
- [ ] `ole32!ProgIDFromCLSID`
- [ ] `oleaut32!SysAllocStringLen`  [ ] `oleaut32!SysFreeString`  [ ] `oleaut32!SysStringLen`
  [ ] `oleaut32!GetErrorInfo`

**advapi32: 0 — nothing owed.** ✅

**Net for py2.7: implement 5 kernel32 + `WSAIoctl` (6 real — `IsDebuggerPresent` is a one-liner,
the critsect pair is C in `RESOURCE.C`, and `GetFileAttributesEx` restores the
`NtQueryFullAttributesFile` syscall); add 19 stub exports — `gdi32` 5, `crypt32` 7, `oleaut32` 4,
`ole32` 1, `user32` 2 — so `_ssl`/`_hashlib`/`_ctypes` load.** No `MODERN-IPSTACK.md` dependency.

## python-3.14.5 — major lift (three new axes)

This is a different machine. Three largely-independent bodies of work:

### 1. The Universal CRT (the big one, and it's *not* bundled)
Only `vcruntime140.dll` ships in-tree. The actual libc — **231 unique symbols** — is
imported via the UCRT apiset forwarders and is **absent from the tree**, expected as a
system component (`ucrtbase.dll`):
```
api-ms-win-crt-{math 54, stdio 47, runtime 43, string 30, heap 10, time 10,
                conio 8, convert 7, environment 6, filesystem 5, process 5,
                locale 3, utility 1}  + api-ms-win-core-path 2
```
MicroNT must **provide the Universal CRT** (ship `ucrtbase` + the `api-ms-win-crt-*`
apiset forwarders, or a host DLL exporting the union). This is the gating dependency for
*any* modern (VS2015+) native binary, so it pays for itself beyond Python — but it's the
single largest item here. (`msvcrt.dll` is **not** UCRT; py254/py2718 sidestep this entirely.)

### 2. kernel32 +80 — the modern thread/async/fs tail
Same families Node forced, now hard-required by CPython 3.14:
- **Vista sync (12):** SRWLOCK (`InitializeSRWLock`, `Acquire/Release…Exclusive/Shared`)
  + CONDITION_VARIABLE (`InitializeConditionVariable`, `Sleep…CS/SRW`, `Wake…`). **Shared
  with Node** — lift once from nxdk `sync.c` (see `MICRONT-NODE-TODO.md`).
- **Fibers (5)** `CreateFiberEx`/`ConvertThreadToFiberEx`/`ConvertFiberToThread`/
  `SwitchToFiber`/`DeleteFiber`; **FLS (3)** `FlsAlloc`/`Free`/`SetValue`; **SLIST (3)**
  `InitializeSListHead`/`InterlockedPushEntrySList`/`InterlockedFlushSList` (asm — mind
  `ml 6.11 no 486 mnemonics`).
- **IOCP/async (3):** `PostQueuedCompletionStatus` (+ `CancelIoEx`, `SetWaitableTimerEx`)
  — `asyncio` ProactorEventLoop via `_overlapped.pyd`. = `MODERN-IPSTACK.md` gaps.
- **ProcThreadAttribute list (4)** + **Toolhelp32 (4)** (`CreateToolhelp32Snapshot`,
  `Module32First/NextW`) + **Pss snapshot (3)** + **volume enum (6)** (`FindFirstVolumeW`…,
  `GetVolumePathNamesForVolumeNameW`) — `subprocess`/`os`/`shutil`. Mostly thin-or-stub.
- **Thread pool (3)** `RegisterWaitForSingleObject`/`UnregisterWait`/`Ex`; **VEH (2)**;
  **locale-Ex** `LCMapStringEx`/`CompareStringOrdinal`; **timing** `GetTickCount64`/
  `GetSystemTimePreciseAsFileTime`; `EncodePointer`/`DecodePointer`; `GetModuleHandleExW`;
  `Add/RemoveDllDirectory`; `CreateHardLinkW`/`CreateSymbolicLinkW`; `CopyFile2`.

### 3. New extension surface
- **`_overlapped.pyd`** → IOCP/ws2_32 overlapped (the asyncio proactor core).
- **`_socket.pyd`** now pulls **`iphlpapi` (5)** — `if_nametoindex`/`if_indextoname`/
  `ConvertInterfaceLuidToNameW`/`GetIfTable2Ex`/`FreeMibTable` (iface scoping). Same
  `iphlpapi` cluster as Go/Node.
- **`_wmi.pyd`** → COM: `ole32` (`CoCreateInstance`/`CoInitializeEx`/`CoSetProxyBlanket`,
  delay-loaded) + `oleaut32` + **`propsys` (1)**. The only real COM consumer — **stubbable**
  (the `platform`/`_wmi` module degrades gracefully).
- **`python314.dll` core** itself now imports **`version.dll` (3)** (`GetFileVersionInfo*`),
  **`bcrypt` (1)** `BCryptGenRandom`, and a little ws2_32 directly — unlike 2.5/2.7 whose
  cores touched neither.
- **ws2_32 +14** — full modern set incl. `getaddrinfo`/`freeaddrinfo`/`getnameinfo`/
  `inet_ntop`/`inet_pton`/`WSASocketW`/`WSAConnect`/`WSAStringToAddressW`.
- **`_ssl`/`_hashlib`/`_ctypes`** now use **external** `libssl-3`/`libcrypto-3` (OpenSSL 3)
  and `libffi-8` (all bundled, drop-in) rather than static — so OpenSSL 3's own Win32
  needs (`bcrypt BCryptGenRandom`, `crypt32` cert store) ride along.

## CRT is the spine
The cleanest way to read all three: **the Win32 delta tracks the Visual C++ runtime, not
the Python version.**
- `msvcr71` (py254) and `msvcr90` (py2718) are **full drop-in MS DLLs already in-tree** —
  zero CRT work, and they keep the interpreter on the *classic* NT surface our DLLs already
  cover. This is why py254 boots with a one-symbol gap.
- The UCRT (py3.14) is a **system component we must supply** and drags in the modern
  kernel32 tail with it. Everything hard about py3.14 is downstream of that one decision.

## Extension-module dependency map (which `.pyd` pulls what)
Almost every `.pyd` imports only `pythonXX.dll` + the CRT. The external Win32 surface
concentrates in a handful:

| extension | extra deps | notes |
|-----------|-----------|-------|
| `_socket` | ws2_32 (+ iphlpapi, py3.14) | the sockets core |
| `_ssl` | ws2_32/`wsock32`, crypt32 (+ libssl/crypto, py3.14) | TLS; OpenSSL static ≤2.7, dynamic 3.14 |
| `select` | ws2_32/`wsock32` | `select()` |
| `_multiprocessing` | ws2_32 | 2.7+ (named-pipe/socket IPC) |
| `_overlapped` | ws2_32 (IOCP) | **py3.14 only** — asyncio proactor |
| `_ctypes` | ole32, oleaut32 (+ libffi, py3.14) | FFI |
| `_uuid` | rpcrt4 (`UuidCreate*`) | py3.14 |
| `_wmi` | ole32(delay)/oleaut32/propsys | **py3.14 only — COM; stubbable** |
| `_msi` | msi, cabinet, rpcrt4 | installer; **non-goal** |
| `winsound` | winmm (`PlaySound`) | trivial/stub |
| `_tkinter` | tcl/tk, user32, gdi32 | **GUI — non-goal** |
| `_sqlite3` | sqlite3.dll (bundled) | sqlite3 is a clean leaf (CRT only; 3.14 vcruntime) |

## Sequencing
1. **py254** — close the trivial gap: `kernel32!HeapSize`, 3 advapi32 secdesc stubs, a
   `wsock32`→ws2_32 forwarder. Then drive CPython's own test suite as the acceptance
   oracle (`project_dll_acceptance_testing`). **Beachhead — do first.**
2. **py2718** — implement 6 trivial kernel32 + `WSAIoctl`, then ~16 stub exports
   (`gdi32`/`crypt32`/`ole32`/`oleaut32`/`user32`) so `_ssl`/`_hashlib`/`_ctypes` load. **No
   net-gate dependency** (the overlapped/event-select surface was `_bsddb`/Tk, not shipped).
   Per-file/per-symbol checklist above — tap them off one by one.
3. **python-3.14** — only worth starting once the **Universal CRT** is a decided, shipped
   component; then the kernel32 Vista-sync/fiber/IOCP tail is **mostly shared with Node**
   (do once), and `_wmi`/`version`/`iphlpapi` are stubs or shared clusters.

## Conformance / payoff
py254 is a near-immediate win that also exercises the classic socket + (static) OpenSSL
path end-to-end. py3.14 is the door to the modern PyPI wheel ecosystem — but it's really
"ship the Universal CRT" wearing a Python costume, and that unlock is far broader than
Python alone.

## Cross-refs
- `MICRONT-DLL-TODO.md` — authoritative per-DLL/per-symbol registry (regenerate
  `tools/dll-surface.py` to fold CPython in as a fourth consumer)
- `MICRONT-NODE-TODO.md` — the **shared** Vista-sync + fiber/FLS/SLIST + IOCP kernel32 work
- `MODERN-IPSTACK.md` — ws2_32 overlapped / IOCP gate (py2.7 `WSARecv/Send/Ioctl`, py3.14 `_overlapped`)
- memory: `project_win32_userland`, `project_spawn_env_required` (msvcr71 startup),
  `project_rng_subsystem` (OpenSSL entropy), `feedback_win32_demand_driven`,
  `project_dll_acceptance_testing`
