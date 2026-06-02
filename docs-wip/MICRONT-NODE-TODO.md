# MicroNT — Node.js (win-x86) missing Win32 surface

Goal: run stock `node.exe` (the last 32-bit-x86 Node) on MicroNT — opening the npm
ecosystem alongside Go and Rust. Surface measured from
**`stuff/oldstuff/node-v22.22.3-win-x86/node.exe`** (76 MB; V8 + libuv + OpenSSL,
statically linked C++). Unlike Go, Node **links its imports directly** — the PE
import table is authoritative (`pefile` / `i686-w64-mingw32-objdump -p`), **no
delay-loads**. Runtime extension-function lookups (`AcceptEx`/`ConnectEx` via
`WSAIoctl`) are the one exception, same as Go.

Measured: **417 imports across 11 DLLs**, ~145 net-new vs MicroNT today. Node is a
**materially bigger lift than Go or Rust** — but a large fraction is shared with
that effort or honestly stubbable. The one genuinely new must-have is the **Vista
sync primitive family** (SRWLOCK + CONDITION_VARIABLE).

## DLLs and deltas (measured)
| DLL | imports | have | **need** | nature |
|-----|--------:|-----:|---------:|--------|
| kernel32 | 292 | 196 | **96** | the bulk; clustered below |
| advapi32 | 38 | 14 | **24** | CryptoAPI CSP + ETW + SID/ACL |
| ws2_32 | 44 | 32 | **12** | overlapped core (same as Go) |
| dbghelp | 13 | 0 | **13** | NEW — diagnostics, **stubbable** |
| crypt32 | 9 | 0 | **9** | NEW — cert store (same as Go) |
| iphlpapi | 8 | 0 | **8** | NEW — net iface (same as Go) |
| user32 | 9 | 3 | **6** | **resolved — 6 inert stubs** (below) |
| ole32 | 1 | 0 | **1** | `CoTaskMemFree` → free |
| userenv | 1 | 0 | **1** | `GetUserProfileDirectoryW` (shared) |
| shell32 | 1 | 0 | **1** | `SHGetKnownFolderPath` (profile dir) |
| winmm | 1 | 0 | **1** | `timeGetTime` → tick count |

`mswsock` is an **implicit** runtime dependency (AcceptEx/ConnectEx via
`WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER)`), not in the static table — same as Go.

## Shared with Go/Rust (not incremental)
- **ws2_32 overlapped core** (`WSARecv`/`WSASend`/`...From`/`...To`/`WSASocketW`/`A`/
  `WSAIoctl`/`WSAGetOverlappedResult`/`WSADuplicateSocketW`) + `GetAddrInfoW`/
  `FreeAddrInfoW`/`GetNameInfoW`. → `MODERN-IPSTACK.md`.
- **mswsock** AcceptEx/ConnectEx; **crypt32** cert store; **iphlpapi**
  `GetAdaptersAddresses`; **userenv** `GetUserProfileDirectoryW`. All already on the
  Go/Rust lists.
- **kernel32**: `AddVectoredExceptionHandler`, `SwitchToThread`, `SetWaitableTimer`,
  `CreateWaitableTimerExW`, `GetQueuedCompletionStatusEx`, `PostQueuedCompletionStatus`,
  `SetFileCompletionNotificationModes`, `CancelIo`, `InitOnceBeginInitialize`/`Complete`,
  `Compare­StringOrdinal`, the file-Ex/64 set, `GetSystemTimePreciseAsFileTime`,
  `GetProcessId` — all already in the Go/Rust kernel32 deltas.

## The one big new requirement: Vista sync primitives (kernel32, 15)
libuv and V8 **hard-require** these — there is no fallback:
```
InitializeSRWLock  AcquireSRWLockExclusive/Shared  ReleaseSRWLockExclusive/Shared
TryAcquireSRWLockExclusive/Shared
InitializeConditionVariable  SleepConditionVariableCS  SleepConditionVariableSRW
WakeConditionVariable  WakeAllConditionVariable
TryEnterCriticalSection  InitializeCriticalSectionAndSpinCount  InitializeCriticalSectionEx
```
Rust only needed `WaitOnAddress`; Node needs the whole family. **Liftable**: the nxdk
`lib/winapi/sync.c` referenced in `MICRONT-RUST-TODO.md` implements CRITICAL_SECTION /
SRWLOCK / CONDITION_VARIABLE over classic NT primitives (NtCreateEvent/Semaphore) —
MIT, vintage-aligned, the intended source. This is the headline kernel32 work item.

## kernel32 — +96 grouped
- **Vista sync (15)** — above. *Required, liftable from nxdk.*
- **Fibers (5):** `CreateFiberEx` `ConvertThreadToFiberEx` `ConvertFiberToThread`
  `SwitchToFiber` `DeleteFiber` — V8 coroutines; pure userland stack-switching.
- **FLS (4):** `FlsAlloc`/`Free`/`GetValue`/`SetValue` — fiber-local storage → back with TLS.
- **SLIST (2):** `InitializeSListHead` `InterlockedPushEntrySList` — lock-free list
  (thread pool); needs the asm (mind `ml 6.11 no 486 mnemonics` — emit opcodes via db).
- **Thread pool (4):** `RegisterWaitForSingleObject` `UnregisterWait`/`Ex` `QueueUserWorkItem`.
- **Job objects (3):** `CreateJobObjectW` `AssignProcessToJobObject`
  `SetInformationJobObject` — `child_process`. **Real kernel work — wanted anyway**
  (the `NtCreateJobObject` wishlist item in `project_win32_userland`).
- **IOCP (3):** `GetQueuedCompletionStatusEx` `PostQueuedCompletionStatus`
  `SetFileCompletionNotificationModes` — = `MODERN-IPSTACK.md` gaps 2 & 7; libuv is
  IOCP-to-the-core (will stress this harder than Go).
- **NLS/locale-Ex (~14):** `GetLocaleInfoEx` `LCMapStringEx` `CompareStringEx`
  `LCIDToLocaleName` `LocaleNameToLCID` `ResolveLocaleName` `GetDateFormatEx`
  `GetTimeFormatEx` `GetNumberFormatEx` `GetCurrencyFormatEx` `GetGeoInfoW`
  `GetUserGeoID` `GetDynamicTimeZoneInformation` — ICU/V8. Thin over existing NLS or
  honest invariant-locale stubs.
- **File Ex/64 + cancel + fs.watch (~12):** `FindFirstFileExW` `GetFileAttributesExW`
  `GetFileInformationByHandleEx` `SetFileInformationByHandle` `GetFileSizeEx`
  `SetFilePointerEx` `GetFinalPathNameByHandleW` `ReOpenFile` `CancelIoEx`
  (libuv-critical) `CancelSynchronousIo` `ReadDirectoryChangesW` (`fs.watch` →
  `NtNotifyChangeDirectoryFile`) `GetNamedPipeClientProcessId`/`ServerProcessId`.
- **Process/module info (6):** `GetProcessId` `GetProcessIoCounters` `GetModuleHandleExW`
  `K32EnumProcessModules` `K32GetModuleBaseNameW` `K32GetProcessMemoryInfo` (psapi
  folded into kernel32).
- **Timing (3):** `GetTickCount64` `GetSystemTimePreciseAsFileTime` `QueryThreadCycleTime`.
- **VEH/backtrace (3):** `AddVectoredExceptionHandler` `RemoveVectoredExceptionHandler`
  `RtlCaptureStackBackTrace`.
- **Trivial (~22):** `EncodePointer`/`DecodePointer` (per-process XOR cookie),
  `GetNativeSystemInfo` `GlobalMemoryStatusEx` `GetCurrentProcessorNumber`
  `IsDebuggerPresent` `IsProcessorFeaturePresent` `HeapSize`/`HeapQueryInformation`
  `VerSetConditionMask`/`VerifyVersionInfoW` `CreateHardLinkW`/`CreateSymbolicLinkW`
  `InitOnceExecuteOnce` `NeedCurrentDirectoryForExePathW` `CompareStringEx` …

## advapi32 — +24
- **CryptoAPI CSP (9):** `CryptCreateHash` `CryptDecrypt` `CryptDestroyHash`/`Key`
  `CryptExportKey` `CryptGetProvParam` `CryptGetUserKey` `CryptSetHashParam`
  `CryptSignHashW` `CryptEnumProvidersW`. Legacy CSP surface, beyond our RNG-only path.
  Node bundles OpenSSL (own crypto) so these are the CAPI-engine/cert path — likely
  **stub-tolerant**, but scope it (don't assume one-liner).
- **ETW (4):** `EventRegister`/`Unregister`/`SetInformation`/`WriteTransfer` → no-op.
- **SID/ACL/token (8):** `AllocateAndInitializeSid` `FreeSid` `GetSecurityInfo`
  `SetSecurityInfo` `SetEntriesInAclA` `OpenProcessToken` `GetUserNameW` — stub
  permissive for bring-up (fits `project_security_model_direction`); implement
  correctly later.
- **Misc (3):** `RegGetValueW` (thin over Reg*), `RegisterEventSourceW`/`ReportEventW`
  (event log → stub).

## ws2_32 — +12
Overlapped core, identical to the Go set: `WSARecv`/`WSASend`/`WSARecvFrom`/`WSASendTo`/
`WSASocketW`/`WSASocketA`/`WSAIoctl`/`WSAGetOverlappedResult`/`WSADuplicateSocketW` +
`GetAddrInfoW`/`FreeAddrInfoW`/`GetNameInfoW`. → `MODERN-IPSTACK.md`. (`GetNameInfoW`
is the one not in the Go list — reverse resolver.)

## New DLLs
- **dbghelp (13):** `Sym*`, `StackWalk64`, `MiniDumpWriteDump`, `UnDecorateSymbolName`
  — crash stack-traces + `--report` + heap dumps. **Diagnostics-only — stub to fail
  gracefully**; Node runs without symbolized traces.
- **crypt32 (9):** cert store (`Cert*`) — outbound TLS verify. Same as Go; lowest net
  priority.
- **iphlpapi (8):** `GetAdaptersAddresses` (`os.networkInterfaces`) + newer
  `if_nametoindex`/`if_indextoname`/`ConvertInterfaceLuid*`/`GetBestRoute2`/
  `NotifyIpInterfaceChange`/`CancelMibChangeNotify2` (some NT6+; the notify pair →
  stub no-change). Real-ish impl for iface enumeration.
- **ole32 (1):** `CoTaskMemFree` → `free` (pairs with `SHGetKnownFolderPath`'s alloc).
- **userenv (1):** `GetUserProfileDirectoryW` — shared with Rust/Go.
- **shell32 (1):** `SHGetKnownFolderPath` — modern known-folder (home/appdata); return
  the profile dir, allocate via CoTaskMem so `CoTaskMemFree` matches.
- **winmm (1):** `timeGetTime` → millisecond tick.

## user32 — RESOLVED: 6 inert stubs, console untouched
The 6 imports (`MessageBoxW`, `GetMessageA`, `DispatchMessageA`, `TranslateMessage`,
`MapVirtualKeyW`, `GetSystemMetrics`) are **dead at runtime** — needed only so the
loader resolves the table. Two sources, both harmless:
- **OpenSSL** `OPENSSL_isservice` → `MessageBoxW` (+`GetSystemMetrics`). Add `MessageBoxW`
  beside the existing `MessageBoxA` stub (`USER32/STUB.C`: tee to stderr, return `IDOK`).
- **libuv TTY** `uv__tty_console_resize_message_loop_thread` → the GetMessage loop +
  `MapVirtualKeyW`. **Never entered**: `uv_guess_handle` only returns `UV_TTY` for a
  `FILE_TYPE_CHAR` handle whose `GetConsoleMode` succeeds. On MicroNT stdio are pipe/
  file handles (`GetFileType` → `FILE_TYPE_PIPE`/`DISK` → `UV_NAMED_PIPE`/`UV_FILE`),
  and even on `FILE_TYPE_CHAR`, `GetConsoleMode` is `STUB_BOOL`→FALSE (`STDIO.C:225`)
  → `UV_FILE`. Three paths in, none reach `UV_TTY`; the loop thread never spawns.

So: `GetMessageA`→return 0 (`WM_QUIT`), `DispatchMessageA`/`TranslateMessage`/
`MapVirtualKeyW`/`GetSystemMetrics`→0, `MessageBoxW`→stderr+`IDOK`. **No Windows
Console is ever implemented** (explicit non-goal). Signals are unaffected — Ctrl+C/
Break route through `SetConsoleCtrlHandler` (kernel32, present), not the pump.

## Sequencing
Node gates on more than Go, but most of it is the same critical mass:
1. **Vista sync (nxdk lift)** + fibers/FLS/SLIST + thread pool — the kernel32 core.
2. **IOCP + ws2_32 overlapped + mswsock** — shared with `MODERN-IPSTACK.md` (do once).
3. **Job objects** (`NtCreateJobObject` + accounting) — wanted independently.
4. **user32 6 stubs**, **dbghelp stubs**, **ETW/SID stubs**, **ole32/winmm/shell32/
   userenv one-liners** — cheap unblockers.
5. **NLS-Ex** thin/stub; **crypt32/iphlpapi** with the Go work.

## Conformance / payoff
npm is the prize. Once the surface ships, Node's own test suite + real npm packages
are the acceptance oracle (`project_dll_acceptance_testing`). libuv exercises the
IOCP/cancel edges even harder than Go — a strong battle-test for the async core.

## Cross-refs
- `MICRONT-DLL-TODO.md` — authoritative DLL registry (Node = third consumer)
- `MICRONT-GO-TODO.md` / `MICRONT-RUST-TODO.md` — sibling toolchain deltas
- `MODERN-IPSTACK.md` — the shared net/IOCP gate (ws2_32 overlapped, mswsock, NtSetIoCompletion)
- memory: `project_win32_userland` (Job objects wishlist), `project_dll_acceptance_testing`
