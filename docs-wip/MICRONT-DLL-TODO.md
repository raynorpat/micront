# MicroNT — DLL registry & acceptance map

Authoritative, cross-cutting list of the user-mode DLLs MicroNT ships or owes,
**broken down per-DLL per-symbol** so we can work the surface methodically. The
per-language docs (`MICRONT-RUST-TODO.md`, `MICRONT-GO-TODO.md`, `MICRONT-NODE-TODO.md`)
hold the narrative rationale per toolchain; this is the authoritative checklist.

> **Generated** by `tools/dll-surface.py` from the real sample binaries
> (`stuff/testrust`, `stuff/gostuff`, `stuff/oldstuff/node-*`) + MicroNT `.def`
> exports. Re-run after samples change. Hand-edits to the per-symbol sections will
> be overwritten — edit the generator (notably the `HDR` doc-link map) instead.

## Testing philosophy
- **Kernel functionality** — our own tests (`test/`, `src/cr/`, IOCP suite, NTFS smoke):
  own correctness of the underlying syscall/AFD/IOCP/FS machinery.
- **DLL acceptance** — the real bar: run a real, unmodified app and either drop in an
  authoritative MS DLL or run our own impl, and confirm it works. The app (and its own
  test suite) is the oracle; we don't hand-author behavioural tests for documented surface.

## How to read the per-symbol lists
- `- [ ]` = **need** (not exported today; a work item). `- [x]` = **have** (exported,
  still owes an acceptance pass).
- Consumer tag: `rust`, `go(all)`/`go:caddy/...`, `node`.
- `— [MS](…)` links the authoritative learn.microsoft.com reference. Links are added
  to **Need** items first (verified headers in the generator's `HDR` map); coverage
  grows as we work each DLL. Unmapped funcs get no link rather than a guessed one.
- Symbol sets are measured: Rust/Node from the static import table (they link directly),
  Go from static imports **plus** dynamically-resolved proc-name strings.

## Status legend
OWNED-FULL · OWNED-PARTIAL · NEW · HOST-ONLY

## Navigation (priority order)
| DLL | status | need | have |
|-----|--------|-----:|-----:|
| `ws2_32` | OWNED-PARTIAL | 15 | 34 |
| `mswsock` | NEW | 4 | 0 |
| `iphlpapi` | NEW | 11 | 0 |
| `dnsapi` | NEW | 2 | 0 |
| `winmm` | NEW | 3 | 0 |
| `kernel32` | OWNED-FULL | 102 | 216 |
| `ntdll` | OWNED-FULL | 1 | 9 |
| `advapi32` | OWNED-PARTIAL | 27 | 14 |
| `crypt32` | NEW | 13 | 0 |
| `netapi32` | NEW | 3 | 0 |
| `userenv` | NEW | 1 | 0 |
| `bcryptprimitives` | OWNED-FULL | 0 | 1 |
| `dbghelp` | NEW | 13 | 0 |
| `ole32` | NEW | 1 | 0 |
| `shell32` | OWNED-PARTIAL | 1 | 0 |
| `user32` | OWNED-PARTIAL | 6 | 3 |
| `msvcrt` | NEW | 31 | 0 |
| `api-ms-win-core-synch-l1-2-0` | NEW | 3 | 0 |

`need`/`have` count only consumer-touched symbols. The net cluster (`ws2_32` overlapped,
`mswsock`, `iphlpapi`, `dnsapi`) is gated as one unit behind `MODERN-IPSTACK.md`.

---

## Per-DLL per-symbol breakdown
### `ws2_32` — OWNED-PARTIAL  ·  need 15 / have 34
ABI: `BASE/WS2_32/WS2_32.DEF` (36, BSD core) · overlapped core — MODERN-IPSTACK gate

**Need (15):**
- [ ] `FreeAddrInfoW` — go(all) node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/ws2tcpip/nf-ws2tcpip-freeaddrinfow)
- [ ] `GetAddrInfoW` — go(all) node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/ws2tcpip/nf-ws2tcpip-getaddrinfow)
- [ ] `GetNameInfoW` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/ws2tcpip/nf-ws2tcpip-getnameinfow)
- [ ] `WSADuplicateSocketW` — rust node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsaduplicatesocketw)
- [ ] `WSAEnumProtocolsW` — go(all) — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsaenumprotocolsw)
- [ ] `WSAGetOverlappedResult` — go(all) node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsagetoverlappedresult)
- [ ] `WSARecv` — rust go(all) node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsarecv)
- [ ] `WSARecvFrom` — go(all) node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsarecvfrom)
- [ ] `WSASend` — rust go(all) node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsasend)
- [ ] `WSASendTo` — go(all) node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsasendto)
- [ ] `WSASocket` — go:frpc/frps/soft
- [ ] `WSASocketA` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsasocketa)
- [ ] `WSASocketW` — rust go:frpc/frps/soft node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsasocketw)
- [ ] `freeaddrinfo` — rust — [MS](https://learn.microsoft.com/en-us/windows/win32/api/ws2tcpip/nf-ws2tcpip-freeaddrinfo)
- [ ] `getaddrinfo` — rust — [MS](https://learn.microsoft.com/en-us/windows/win32/api/ws2tcpip/nf-ws2tcpip-getaddrinfo)

**Have (34), confirm under acceptance:**
- [x] `WSACleanup` — rust go(all) node
- [x] `WSAGetLastError` — rust node
- [x] `WSAIoctl` — go(all) node
- [x] `WSASetLastError` — node
- [x] `WSAStartup` — rust go(all) node
- [x] `accept` — rust go(all) node
- [x] `bind` — rust go(all) node
- [x] `closesocket` — rust go(all) node
- [x] `connect` — rust go(all) node
- [x] `gethostbyaddr` — node
- [x] `gethostbyname` — go(all) node
- [x] `gethostname` — node
- [x] `getpeername` — rust go(all) node
- [x] `getprotobyname` — go(all)
- [x] `getservbyname` — go(all) node
- [x] `getservbyport` — node
- [x] `getsockname` — rust go(all) node
- [x] `getsockopt` — rust go(all) node
- [x] `htonl` — node
- [x] `htons` — node
- [x] `inet_addr` — node
- [x] `inet_ntoa` — node
- [x] `ioctlsocket` — rust node
- [x] `listen` — rust go(all) node
- [x] `ntohl` — node
- [x] `ntohs` — node
- [x] `recv` — rust node
- [x] `recvfrom` — rust go(all) node
- [x] `select` — rust go(all) node
- [x] `send` — rust node
- [x] `sendto` — rust go(all) node
- [x] `setsockopt` — rust go(all) node
- [x] `shutdown` — rust go(all) node
- [x] `socket` — go(all) node

### `mswsock` — NEW  ·  need 4 / have 0
ABI: new DLL · AcceptEx/ConnectEx; via WSAIoctl GUID

**Need (4):**
- [ ] `AcceptEx` — go(all) — [MS](https://learn.microsoft.com/en-us/windows/win32/api/mswsock/nf-mswsock-acceptex)
- [ ] `ConnectEx` — go(all) — [MS](https://learn.microsoft.com/en-us/windows/win32/api/mswsock/nf-mswsock-connectex)
- [ ] `GetAcceptExSockaddrs` — go(all) — [MS](https://learn.microsoft.com/en-us/windows/win32/api/mswsock/nf-mswsock-getacceptexsockaddrs)
- [ ] `TransmitFile` — go(all) — [MS](https://learn.microsoft.com/en-us/windows/win32/api/mswsock/nf-mswsock-transmitfile)


### `iphlpapi` — NEW  ·  need 11 / have 0
ABI: new DLL · iface enumeration at net init

**Need (11):**
- [ ] `CancelMibChangeNotify2` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-cancelmibchangenotify2)
- [ ] `ConvertInterfaceIndexToLuid` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-convertinterfaceindextoluid)
- [ ] `ConvertInterfaceLuidToNameW` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-convertinterfaceluidtonamew)
- [ ] `GetAdaptersAddresses` — go(all) node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/iphlpapi/nf-iphlpapi-getadaptersaddresses)
- [ ] `GetAdaptersInfo` — go(all) — [MS](https://learn.microsoft.com/en-us/windows/win32/api/iphlpapi/nf-iphlpapi-getadaptersinfo)
- [ ] `GetBestInterfaceEx` — go:soft — [MS](https://learn.microsoft.com/en-us/windows/win32/api/iphlpapi/nf-iphlpapi-getbestinterfaceex)
- [ ] `GetBestRoute2` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-getbestroute2)
- [ ] `GetIfEntry` — go(all) — [MS](https://learn.microsoft.com/en-us/windows/win32/api/iphlpapi/nf-iphlpapi-getifentry)
- [ ] `NotifyIpInterfaceChange` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-notifyipinterfacechange)
- [ ] `if_indextoname` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-if_indextoname)
- [ ] `if_nametoindex` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-if_nametoindex)


### `dnsapi` — NEW  ·  need 2 / have 0
ABI: new DLL · resolver

**Need (2):**
- [ ] `DnsQuery_W` — go(all) — [MS](https://learn.microsoft.com/en-us/windows/win32/api/windns/nf-windns-dnsquery_w)
- [ ] `DnsRecordListFree` — go(all) — [MS](https://learn.microsoft.com/en-us/windows/win32/api/windns/nf-windns-dnsrecordlistfree)


### `winmm` — NEW  ·  need 3 / have 0
ABI: new DLL · timers; Node timeGetTime + Go timeBegin/EndPeriod

**Need (3):**
- [ ] `timeBeginPeriod` — go:frpc/frps/soft — [MS](https://learn.microsoft.com/en-us/windows/win32/api/timeapi/nf-timeapi-timebeginperiod)
- [ ] `timeEndPeriod` — go:frpc/frps/soft — [MS](https://learn.microsoft.com/en-us/windows/win32/api/timeapi/nf-timeapi-timeendperiod)
- [ ] `timeGetTime` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/timeapi/nf-timeapi-timegettime)


### `kernel32` — OWNED-FULL  ·  need 102 / have 216
ABI: `BASE/CLIENT/KERNEL32.SRC` (608) · Node adds Vista-sync/fibers/jobs/locale-Ex

**Need (102):**
- [ ] `AcquireSRWLockExclusive` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-acquiresrwlockexclusive)
- [ ] `AcquireSRWLockShared` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-acquiresrwlockshared)
- [ ] `AddVectoredExceptionHandler` — rust go(all) node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/errhandlingapi/nf-errhandlingapi-addvectoredexceptionhandler)
- [ ] `AssignProcessToJobObject` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/jobapi2/nf-jobapi2-assignprocesstojobobject)
- [ ] `CancelIo` — rust node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-cancelio)
- [ ] `CancelIoEx` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-cancelioex)
- [ ] `CancelSynchronousIo` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-cancelsynchronousio)
- [ ] `CompareStringEx` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/stringapiset/nf-stringapiset-comparestringex)
- [ ] `CompareStringOrdinal` — rust node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/stringapiset/nf-stringapiset-comparestringordinal)
- [ ] `ConvertFiberToThread` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-convertfibertothread)
- [ ] `ConvertThreadToFiberEx` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-convertthreadtofiberex)
- [ ] `CopyFileExW` — rust
- [ ] `CreateFiberEx` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createfiberex)
- [ ] `CreateHardLinkW` — rust node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createhardlinkw)
- [ ] `CreateJobObjectW` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createjobobjectw)
- [ ] `CreateSymbolicLinkW` — rust node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createsymboliclinkw)
- [ ] `CreateToolhelp32Snapshot` — rust
- [ ] `CreateWaitableTimerA` — go:caddy — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createwaitabletimera)
- [ ] `CreateWaitableTimerExW` — rust go:soft node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createwaitabletimerexw)
- [ ] `DecodePointer` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-decodepointer)
- [ ] `DeleteFiber` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-deletefiber)
- [ ] `DeleteProcThreadAttributeList` — rust
- [ ] `EncodePointer` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-encodepointer)
- [ ] `FindFirstFileExW` — rust node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-findfirstfileexw)
- [ ] `FlsAlloc` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/fibersapi/nf-fibersapi-flsalloc)
- [ ] `FlsFree` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/fibersapi/nf-fibersapi-flsfree)
- [ ] `FlsGetValue` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/fibersapi/nf-fibersapi-flsgetvalue)
- [ ] `FlsSetValue` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/fibersapi/nf-fibersapi-flssetvalue)
- [ ] `GetCurrencyFormatEx` — node
- [ ] `GetCurrentProcessorNumber` — node
- [ ] `GetDateFormatEx` — node
- [ ] `GetDynamicTimeZoneInformation` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/timezoneapi/nf-timezoneapi-getdynamictimezoneinformation)
- [ ] `GetFileInformationByHandleEx` — rust node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getfileinformationbyhandleex)
- [ ] `GetFileSizeEx` — rust node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfilesizeex)
- [ ] `GetFinalPathNameByHandleW` — rust node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew)
- [ ] `GetGeoInfoW` — node
- [ ] `GetLocaleInfoEx` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winnls/nf-winnls-getlocaleinfoex)
- [ ] `GetModuleHandleExW` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getmodulehandleexw)
- [ ] `GetNamedPipeClientProcessId` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getnamedpipeclientprocessid)
- [ ] `GetNamedPipeServerProcessId` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getnamedpipeserverprocessid)
- [ ] `GetNativeSystemInfo` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-getnativesysteminfo)
- [ ] `GetNumberFormatEx` — node
- [ ] `GetProcessId` — rust node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocessid)
- [ ] `GetProcessIoCounters` — node
- [ ] `GetQueuedCompletionStatusEx` — go:soft node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-getqueuedcompletionstatusex)
- [ ] `GetSystemTimePreciseAsFileTime` — rust node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-getsystemtimepreciseasfiletime)
- [ ] `GetTickCount64` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-gettickcount64)
- [ ] `GetTimeFormatEx` — node
- [ ] `GetUserGeoID` — node
- [ ] `GlobalMemoryStatusEx` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-globalmemorystatusex)
- [ ] `HeapQueryInformation` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/heapapi/nf-heapapi-heapqueryinformation)
- [ ] `InitOnceBeginInitialize` — rust node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-initoncebegininitialize)
- [ ] `InitOnceComplete` — rust node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-initoncecomplete)
- [ ] `InitOnceExecuteOnce` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-initonceexecuteonce)
- [ ] `InitializeConditionVariable` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-initializeconditionvariable)
- [ ] `InitializeCriticalSectionEx` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-initializecriticalsectionex)
- [ ] `InitializeProcThreadAttributeList` — rust
- [ ] `InitializeSListHead` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/interlockedapi/nf-interlockedapi-initializeslisthead)
- [ ] `InitializeSRWLock` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-initializesrwlock)
- [ ] `InterlockedPushEntrySList` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/interlockedapi/nf-interlockedapi-interlockedpushentryslist)
- [ ] `IsProcessorFeaturePresent` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-isprocessorfeaturepresent)
- [ ] `K32EnumProcessModules` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-enumprocessmodules)
- [ ] `K32GetModuleBaseNameW` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-getmodulebasenamew)
- [ ] `K32GetProcessMemoryInfo` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-getprocessmemoryinfo)
- [ ] `LCIDToLocaleName` — node
- [ ] `LCMapStringEx` — node
- [ ] `LocaleNameToLCID` — node
- [ ] `Module32FirstW` — rust
- [ ] `Module32NextW` — rust
- [ ] `NeedCurrentDirectoryForExePathW` — node
- [ ] `PostQueuedCompletionStatus` — go:soft node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-postqueuedcompletionstatus)
- [ ] `QueryThreadCycleTime` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/realtimeapiset/nf-realtimeapiset-querythreadcycletime)
- [ ] `QueueUserWorkItem` — node
- [ ] `ReOpenFile` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-reopenfile)
- [ ] `ReadDirectoryChangesW` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-readdirectorychangesw)
- [ ] `RegisterWaitForSingleObject` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-registerwaitforsingleobject)
- [ ] `ReleaseSRWLockExclusive` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-releasesrwlockexclusive)
- [ ] `ReleaseSRWLockShared` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-releasesrwlockshared)
- [ ] `RemoveVectoredExceptionHandler` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/errhandlingapi/nf-errhandlingapi-removevectoredexceptionhandler)
- [ ] `ResolveLocaleName` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winnls/nf-winnls-resolvelocalename)
- [ ] `RtlCaptureContext` — rust
- [ ] `RtlCaptureStackBackTrace` — node
- [ ] `SetFileCompletionNotificationModes` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setfilecompletionnotificationmodes)
- [ ] `SetFileInformationByHandle` — rust node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfileinformationbyhandle)
- [ ] `SetFilePointerEx` — rust node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfilepointerex)
- [ ] `SetInformationJobObject` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/jobapi2/nf-jobapi2-setinformationjobobject)
- [ ] `SetProcessPriorityBoost` — go(all)
- [ ] `SetThreadStackGuarantee` — rust
- [ ] `SetWaitableTimer` — rust go(all) node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-setwaitabletimer)
- [ ] `SleepConditionVariableCS` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-sleepconditionvariablecs)
- [ ] `SleepConditionVariableSRW` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-sleepconditionvariablesrw)
- [ ] `SwitchToFiber` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-switchtofiber)
- [ ] `SwitchToThread` — rust go:frpc/frps/soft node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-switchtothread)
- [ ] `TryAcquireSRWLockExclusive` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-tryacquiresrwlockexclusive)
- [ ] `TryAcquireSRWLockShared` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-tryacquiresrwlockshared)
- [ ] `UnregisterWait` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-unregisterwait)
- [ ] `UnregisterWaitEx` — node
- [ ] `UpdateProcThreadAttribute` — rust
- [ ] `VerSetConditionMask` — node
- [ ] `VerifyVersionInfoW` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-verifyversioninfow)
- [ ] `WakeAllConditionVariable` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-wakeallconditionvariable)
- [ ] `WakeConditionVariable` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-wakeconditionvariable)

**Have (216), confirm under acceptance:**
- [x] `AreFileApisANSI` — node
- [x] `CloseHandle` — rust go(all) node
- [x] `CompareStringW` — node
- [x] `ConnectNamedPipe` — node
- [x] `CopyFileW` — node
- [x] `CreateDirectoryW` — rust node
- [x] `CreateEventA` — go(all) node
- [x] `CreateEventW` — rust
- [x] `CreateFileA` — go:soft node
- [x] `CreateFileMappingA` — rust node
- [x] `CreateFileMappingW` — node
- [x] `CreateFileW` — rust node
- [x] `CreateIoCompletionPort` — go(all) node
- [x] `CreateMutexA` — rust
- [x] `CreateMutexW` — node
- [x] `CreateNamedPipeA` — node
- [x] `CreateNamedPipeW` — node
- [x] `CreatePipe` — rust
- [x] `CreateProcessW` — rust node
- [x] `CreateRemoteThread` — node
- [x] `CreateSemaphoreA` — node
- [x] `CreateSemaphoreW` — rust
- [x] `CreateThread` — rust go(all) node
- [x] `DebugBreak` — node
- [x] `DeleteCriticalSection` — rust node
- [x] `DeleteFileA` — node
- [x] `DeleteFileW` — rust node
- [x] `DeviceIoControl` — rust node
- [x] `DuplicateHandle` — rust go(all) node
- [x] `EnterCriticalSection` — rust node
- [x] `EnumSystemLocalesW` — node
- [x] `ExitProcess` — rust go(all) node
- [x] `ExitThread` — node
- [x] `ExpandEnvironmentStringsA` — node
- [x] `FileTimeToSystemTime` — node
- [x] `FillConsoleOutputAttribute` — node
- [x] `FillConsoleOutputCharacterW` — node
- [x] `FindClose` — rust node
- [x] `FindFirstFileW` — node
- [x] `FindNextFileW` — rust node
- [x] `FindResourceA` — node
- [x] `FlushFileBuffers` — rust node
- [x] `FlushViewOfFile` — node
- [x] `FormatMessageA` — node
- [x] `FormatMessageW` — rust node
- [x] `FreeEnvironmentStringsW` — rust go(all) node
- [x] `FreeLibrary` — rust node
- [x] `FreeLibraryAndExitThread` — node
- [x] `GetACP` — node
- [x] `GetCPInfo` — node
- [x] `GetCommandLineA` — node
- [x] `GetCommandLineW` — rust node
- [x] `GetConsoleCursorInfo` — node
- [x] `GetConsoleMode` — rust go(all) node
- [x] `GetConsoleOutputCP` — rust node
- [x] `GetConsoleScreenBufferInfo` — node
- [x] `GetConsoleTitleW` — node
- [x] `GetCurrentDirectoryW` — rust node
- [x] `GetCurrentProcess` — rust go(all) node
- [x] `GetCurrentProcessId` — rust go(all) node
- [x] `GetCurrentThread` — rust node
- [x] `GetCurrentThreadId` — rust node
- [x] `GetDiskFreeSpaceA` — node
- [x] `GetDiskFreeSpaceW` — node
- [x] `GetDriveTypeW` — node
- [x] `GetEnvironmentStringsW` — rust go(all) node
- [x] `GetEnvironmentVariableA` — node
- [x] `GetEnvironmentVariableW` — rust node
- [x] `GetExitCodeProcess` — rust node
- [x] `GetExitCodeThread` — node
- [x] `GetFileAttributesA` — node
- [x] `GetFileAttributesExW` — node
- [x] `GetFileAttributesW` — rust node
- [x] `GetFileInformationByHandle` — rust node
- [x] `GetFileSize` — node
- [x] `GetFileType` — rust node
- [x] `GetFullPathNameA` — node
- [x] `GetFullPathNameW` — rust node
- [x] `GetLastError` — rust node
- [x] `GetLocalTime` — node
- [x] `GetLocaleInfoW` — node
- [x] `GetLongPathNameW` — node
- [x] `GetModuleFileNameW` — rust go:frpc/frps/soft node
- [x] `GetModuleHandleA` — rust node
- [x] `GetModuleHandleW` — rust node
- [x] `GetNamedPipeHandleStateA` — node
- [x] `GetNumberOfConsoleInputEvents` — node
- [x] `GetOEMCP` — node
- [x] `GetOverlappedResult` — rust node
- [x] `GetPriorityClass` — node
- [x] `GetProcAddress` — rust go(all) node
- [x] `GetProcessAffinityMask` — go(all) node
- [x] `GetProcessHeap` — rust node
- [x] `GetProcessTimes` — node
- [x] `GetQueuedCompletionStatus` — go:caddy/frpc/frps
- [x] `GetShortPathNameW` — node
- [x] `GetStartupInfoA` — rust
- [x] `GetStartupInfoW` — node
- [x] `GetStdHandle` — rust go(all) node
- [x] `GetStringTypeW` — node
- [x] `GetSystemDirectoryA` — go:soft node
- [x] `GetSystemDirectoryW` — rust
- [x] `GetSystemInfo` — rust go(all) node
- [x] `GetSystemTime` — node
- [x] `GetSystemTimeAsFileTime` — go(all) node
- [x] `GetTempFileNameA` — node
- [x] `GetTempPathA` — node
- [x] `GetTempPathW` — rust node
- [x] `GetThreadContext` — go:caddy/soft node
- [x] `GetThreadPriority` — node
- [x] `GetThreadTimes` — node
- [x] `GetTickCount` — node
- [x] `GetTimeZoneInformation` — node
- [x] `GetUserDefaultLCID` — node
- [x] `GetWindowsDirectoryW` — rust
- [x] `HeapAlloc` — rust node
- [x] `HeapCompact` — node
- [x] `HeapCreate` — node
- [x] `HeapDestroy` — node
- [x] `HeapFree` — rust node
- [x] `HeapReAlloc` — rust node
- [x] `HeapSize` — node
- [x] `HeapValidate` — node
- [x] `InitializeCriticalSection` — rust node
- [x] `InitializeCriticalSectionAndSpinCount` — node
- [x] `IsDebuggerPresent` — node
- [x] `IsValidCodePage` — node
- [x] `IsValidLocale` — node
- [x] `LCMapStringW` — node
- [x] `LeaveCriticalSection` — rust node
- [x] `LoadLibraryA` — rust go(all) node
- [x] `LoadLibraryExA` — node
- [x] `LoadLibraryExW` — node
- [x] `LoadLibraryW` — go(all) node
- [x] `LoadResource` — node
- [x] `LocalFree` — node
- [x] `LockFile` — node
- [x] `LockFileEx` — rust node
- [x] `LockResource` — node
- [x] `MapViewOfFile` — rust node
- [x] `MapViewOfFileEx` — node
- [x] `MoveFileExW` — rust node
- [x] `MultiByteToWideChar` — rust node
- [x] `OpenFileMappingW` — node
- [x] `OpenProcess` — node
- [x] `OutputDebugStringA` — node
- [x] `OutputDebugStringW` — node
- [x] `PeekNamedPipe` — node
- [x] `QueryPerformanceCounter` — rust go:frpc/frps/soft node
- [x] `QueryPerformanceFrequency` — rust go:frpc/frps/soft node
- [x] `RaiseException` — node
- [x] `ReadConsoleA` — node
- [x] `ReadConsoleInputW` — node
- [x] `ReadConsoleW` — rust node
- [x] `ReadFile` — rust node
- [x] `ReadFileEx` — rust
- [x] `ReleaseMutex` — rust
- [x] `ReleaseSemaphore` — rust node
- [x] `RemoveDirectoryW` — rust node
- [x] `ResetEvent` — node
- [x] `ResumeThread` — go:caddy/soft node
- [x] `RtlUnwind` — node
- [x] `SetConsoleCtrlHandler` — go(all) node
- [x] `SetConsoleCursorInfo` — node
- [x] `SetConsoleCursorPosition` — node
- [x] `SetConsoleMode` — node
- [x] `SetConsoleTextAttribute` — node
- [x] `SetConsoleTitleW` — node
- [x] `SetCurrentDirectoryW` — rust node
- [x] `SetEndOfFile` — node
- [x] `SetEnvironmentVariableW` — rust node
- [x] `SetErrorMode` — go(all) node
- [x] `SetEvent` — go(all) node
- [x] `SetFileAttributesW` — rust node
- [x] `SetFilePointer` — node
- [x] `SetFileTime` — rust node
- [x] `SetHandleInformation` — rust node
- [x] `SetLastError` — rust node
- [x] `SetNamedPipeHandleState` — node
- [x] `SetPriorityClass` — node
- [x] `SetStdHandle` — node
- [x] `SetThreadAffinityMask` — node
- [x] `SetThreadContext` — go:soft
- [x] `SetThreadPriority` — go:caddy node
- [x] `SetUnhandledExceptionFilter` — rust go(all) node
- [x] `SizeofResource` — node
- [x] `Sleep` — rust node
- [x] `SleepEx` — rust
- [x] `SuspendThread` — go:caddy/soft node
- [x] `SystemTimeToFileTime` — node
- [x] `SystemTimeToTzSpecificLocalTime` — node
- [x] `TerminateProcess` — rust node
- [x] `TlsAlloc` — rust node
- [x] `TlsFree` — rust node
- [x] `TlsGetValue` — rust node
- [x] `TlsSetValue` — rust node
- [x] `TryEnterCriticalSection` — node
- [x] `UnhandledExceptionFilter` — node
- [x] `UnlockFile` — rust node
- [x] `UnlockFileEx` — node
- [x] `UnmapViewOfFile` — rust node
- [x] `VirtualAlloc` — go(all) node
- [x] `VirtualFree` — go(all) node
- [x] `VirtualLock` — node
- [x] `VirtualProtect` — rust node
- [x] `VirtualQuery` — rust go:frpc/frps/soft node
- [x] `WaitForMultipleObjects` — rust go:soft
- [x] `WaitForSingleObject` — rust go(all) node
- [x] `WaitForSingleObjectEx` — rust node
- [x] `WaitNamedPipeW` — node
- [x] `WideCharToMultiByte` — rust node
- [x] `WriteConsoleInputW` — node
- [x] `WriteConsoleW` — rust go(all) node
- [x] `WriteFile` — go(all) node
- [x] `WriteFileEx` — rust
- [x] `lstrlenW` — rust

### `ntdll` — OWNED-FULL  ·  need 1 / have 9
ABI: `NTOS/DLL/NTDLLDEF.SRC` (904) · syscall floor

**Need (1):**
- [ ] `RtlGetNtVersionNumbers` — go:soft

**Have (9), confirm under acceptance:**
- [x] `NtCreateFile` — go:soft
- [x] `NtCreateNamedPipeFile` — rust
- [x] `NtOpenFile` — rust
- [x] `NtQueryInformationProcess` — go:soft
- [x] `NtReadFile` — rust
- [x] `NtSetInformationFile` — go:soft
- [x] `NtWaitForSingleObject` — go(all)
- [x] `NtWriteFile` — rust
- [x] `RtlNtStatusToDosError` — rust

### `advapi32` — OWNED-PARTIAL  ·  need 27 / have 14
ABI: `BASE/ADVAPI/ADVAPI32.DEF` (54) · RNG done; Node adds CAPI CSP + ETW + SID

**Need (27):**
- [ ] `AllocateAndInitializeSid` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-allocateandinitializesid)
- [ ] `CryptCreateHash` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-cryptcreatehash)
- [ ] `CryptDecrypt` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-cryptdecrypt)
- [ ] `CryptDestroyHash` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-cryptdestroyhash)
- [ ] `CryptDestroyKey` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-cryptdestroykey)
- [ ] `CryptEnumProvidersW` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-cryptenumprovidersw)
- [ ] `CryptExportKey` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-cryptexportkey)
- [ ] `CryptGetProvParam` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-cryptgetprovparam)
- [ ] `CryptGetUserKey` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-cryptgetuserkey)
- [ ] `CryptSetHashParam` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-cryptsethashparam)
- [ ] `CryptSignHashW` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-cryptsignhashw)
- [ ] `EventRegister` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/evntprov/nf-evntprov-eventregister)
- [ ] `EventSetInformation` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/evntprov/nf-evntprov-eventsetinformation)
- [ ] `EventUnregister` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/evntprov/nf-evntprov-eventunregister)
- [ ] `EventWriteTransfer` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/evntprov/nf-evntprov-eventwritetransfer)
- [ ] `FreeSid` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-freesid)
- [ ] `GetSecurityInfo` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-getsecurityinfo)
- [ ] `GetUserNameW` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getusernamew)
- [ ] `LookupAccountNameW` — go(all) — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-lookupaccountnamew)
- [ ] `LookupAccountSidW` — go(all) — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-lookupaccountsidw)
- [ ] `OpenProcessToken` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocesstoken)
- [ ] `RegGetValueW` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-reggetvaluew)
- [ ] `RegisterEventSourceW` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-registereventsourcew)
- [ ] `ReportEventW` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-reporteventw)
- [ ] `RtlGenRandom` — go:soft
- [ ] `SetEntriesInAclA` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setentriesinacla)
- [ ] `SetSecurityInfo` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setsecurityinfo)

**Have (14), confirm under acceptance:**
- [x] `CryptAcquireContextW` — go(all) node
- [x] `CryptGenRandom` — go(all) node
- [x] `CryptReleaseContext` — go(all) node
- [x] `DeregisterEventSource` — node
- [x] `RegCloseKey` — node
- [x] `RegEnumKeyExA` — node
- [x] `RegEnumKeyExW` — node
- [x] `RegNotifyChangeKeyValue` — node
- [x] `RegOpenKeyExA` — node
- [x] `RegOpenKeyExW` — node
- [x] `RegQueryInfoKeyW` — node
- [x] `RegQueryValueExA` — node
- [x] `RegQueryValueExW` — node
- [x] `SystemFunction036` — go:frpc/frps/soft node

### `crypt32` — NEW  ·  need 13 / have 0
ABI: new DLL · cert store / TLS verify

**Need (13):**
- [ ] `CertCloseStore` — go(all) node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-certclosestore)
- [ ] `CertDuplicateCertificateContext` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-certduplicatecertificatecontext)
- [ ] `CertEnumCertificatesInStore` — go(all) node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-certenumcertificatesinstore)
- [ ] `CertFindCertificateInStore` — go:soft node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-certfindcertificateinstore)
- [ ] `CertFreeCertificateContext` — go(all) node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-certfreecertificatecontext)
- [ ] `CertGetCertificateChain` — go(all) — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-certgetcertificatechain)
- [ ] `CertGetCertificateContextProperty` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-certgetcertificatecontextproperty)
- [ ] `CertGetEnhancedKeyUsage` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-certgetenhancedkeyusage)
- [ ] `CertOpenStore` — go(all) node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-certopenstore)
- [ ] `CertOpenSystemStoreW` — go(all) node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-certopensystemstorew)
- [ ] `CertVerifyCertificateChainPolicy` — go(all) — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-certverifycertificatechainpolicy)
- [ ] `CryptProtectData` — go:soft — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-cryptprotectdata)
- [ ] `CryptUnprotectData` — go:soft — [MS](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-cryptunprotectdata)


### `netapi32` — NEW  ·  need 3 / have 0
ABI: new DLL · os/user

**Need (3):**
- [ ] `NetApiBufferFree` — go(all)
- [ ] `NetGetJoinInformation` — go(all)
- [ ] `NetUserGetInfo` — go(all)


### `userenv` — NEW  ·  need 1 / have 0
ABI: new DLL · home dir

**Need (1):**
- [ ] `GetUserProfileDirectoryW` — rust go(all) node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/userenv/nf-userenv-getuserprofiledirectoryw)


### `bcryptprimitives` — OWNED-FULL  ·  need 0 / have 1
ABI: `BASE/BCRYPTP/bcryptp.def` (2) · DONE (commit 4e5d491)

**Have (1), confirm under acceptance:**
- [x] `ProcessPrng` — rust

### `dbghelp` — NEW  ·  need 13 / have 0
ABI: new DLL · diagnostics — stubbable

**Need (13):**
- [ ] `MiniDumpWriteDump` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/minidumpapiset/nf-minidumpapiset-minidumpwritedump)
- [ ] `StackWalk64` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/dbghelp/nf-dbghelp-stackwalk64)
- [ ] `SymCleanup` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/dbghelp/nf-dbghelp-symcleanup)
- [ ] `SymFromAddr` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/dbghelp/nf-dbghelp-symfromaddr)
- [ ] `SymFunctionTableAccess64` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/dbghelp/nf-dbghelp-symfunctiontableaccess64)
- [ ] `SymGetLineFromAddr64` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/dbghelp/nf-dbghelp-symgetlinefromaddr64)
- [ ] `SymGetModuleBase64` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/dbghelp/nf-dbghelp-symgetmodulebase64)
- [ ] `SymGetOptions` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/dbghelp/nf-dbghelp-symgetoptions)
- [ ] `SymGetSearchPathW` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/dbghelp/nf-dbghelp-symgetsearchpathw)
- [ ] `SymInitialize` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/dbghelp/nf-dbghelp-syminitialize)
- [ ] `SymSetOptions` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/dbghelp/nf-dbghelp-symsetoptions)
- [ ] `SymSetSearchPathW` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/dbghelp/nf-dbghelp-symsetsearchpathw)
- [ ] `UnDecorateSymbolName` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/dbghelp/nf-dbghelp-undecoratesymbolname)


### `ole32` — NEW  ·  need 1 / have 0
ABI: new DLL · CoTaskMemFree

**Need (1):**
- [ ] `CoTaskMemFree` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/combaseapi/nf-combaseapi-cotaskmemfree)


### `shell32` — OWNED-PARTIAL  ·  need 1 / have 0
ABI: `BASE/SHELL32/SHELL32.DEF` (47) · CommandLineToArgvW + SHGetKnownFolderPath

**Need (1):**
- [ ] `SHGetKnownFolderPath` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/nf-shlobj_core-shgetknownfolderpath)


### `user32` — OWNED-PARTIAL  ·  need 6 / have 3
ABI: `BASE/USER32/USER32.DEF` (49) · Node: 6 inert stubs (console unreachable)

**Need (6):**
- [ ] `DispatchMessageA` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-dispatchmessagea)
- [ ] `GetMessageA` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getmessagea)
- [ ] `GetSystemMetrics` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getsystemmetrics)
- [ ] `MapVirtualKeyW` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-mapvirtualkeyw)
- [ ] `MessageBoxW` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-messageboxw)
- [ ] `TranslateMessage` — node — [MS](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-translatemessage)

**Have (3), confirm under acceptance:**
- [x] `CharUpperA` — node
- [x] `GetProcessWindowStation` — node
- [x] `GetUserObjectInformationW` — node

### `msvcrt` — NEW  ·  need 31 / have 0
ABI: new DLL · mostly forwards to CRTDLL

**Need (31):**
- [ ] `__getmainargs` — rust
- [ ] `__initenv` — rust
- [ ] `__lconv_init` — rust
- [ ] `__p__acmdln` — rust
- [ ] `__p__commode` — rust
- [ ] `__p__fmode` — rust
- [ ] `__set_app_type` — rust
- [ ] `__setusermatherr` — rust
- [ ] `_amsg_exit` — rust
- [ ] `_cexit` — rust
- [ ] `_commode` — rust
- [ ] `_fmode` — rust
- [ ] `_fpreset` — rust
- [ ] `_initterm` — rust
- [ ] `_iob` — rust
- [ ] `_onexit` — rust
- [ ] `abort` — rust
- [ ] `calloc` — rust
- [ ] `exit` — rust
- [ ] `fprintf` — rust
- [ ] `free` — rust
- [ ] `fwrite` — rust
- [ ] `malloc` — rust
- [ ] `memcmp` — rust
- [ ] `memcpy` — rust
- [ ] `memmove` — rust
- [ ] `memset` — rust
- [ ] `signal` — rust
- [ ] `strlen` — rust
- [ ] `strncmp` — rust
- [ ] `vfprintf` — rust


### `api-ms-win-core-synch-l1-2-0` — NEW  ·  need 3 / have 0
ABI: apiset forwarder · futex (Rust)

**Need (3):**
- [ ] `WaitOnAddress` — rust — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitonaddress)
- [ ] `WakeByAddressAll` — rust — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-wakebyaddressall)
- [ ] `WakeByAddressSingle` — rust — [MS](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-wakebyaddresssingle)


---

## Sample corpus
Reference DLL binaries (drop-in oracles) in `stuff/`: NT 3.1/3.51 SDK+DDK, NT 4.0 RK,
srv03 source (`srv03rtm-anika/`, the srv03-generation net/crypto), NT 3.5 source, MSVC 2.2/4.2 CRT.
Period-correctness: Go/Rust/Node lean on the **srv03-generation** net/crypto DLLs, not NT 3.x.

Isolated app samples in `stuff/`:
- `testrust/` — Rust 1.91 hello+server → `MICRONT-RUST-TODO.md`
- `gostuff/` — caddy, frp, soft-serve (windows/386) → `MICRONT-GO-TODO.md`
- `oldstuff/node-v22.22.3-win-x86/node.exe` — last 32-bit Node → `MICRONT-NODE-TODO.md`

`imagehlp` is HOST-ONLY (linker tooling, not a runtime target).

## Cross-refs
- `MICRONT-RUST-TODO.md` / `MICRONT-GO-TODO.md` / `MICRONT-NODE-TODO.md` — toolchain narratives
- `MODERN-IPSTACK.md` — the networking-DLL gate (AFD/TDI/ws2_32 overlapped)
- memory: `project_dll_acceptance_testing`, `project_win32_userland`,
  `feedback_win32_demand_driven`, `reference_srv03_winsock`, `project_advapi32_owned`
