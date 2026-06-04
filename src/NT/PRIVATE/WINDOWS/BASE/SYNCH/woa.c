/*++

Module Name:

    woa.c

Abstract:

    api-ms-win-core-synch-l1-2-0.dll -- the WaitOnAddress family ("address-based
    wait", Win8's userland futex).  Rust's std synchronisation primitives
    (Mutex / Condvar / Once thread parking) import exactly these three names
    from this apiset, so the DLL must exist with them for the loader to resolve
    a stock i686-pc-windows-gnu binary.

    Real Windows layers WaitOnAddress on a kernel keyed-event.  MicroNT (NT 3.5
    base, no keyed events) layers it on a classic counting semaphore, per the
    plan in docs-wip/MICRONT-RUST-TODO.md: each watched address gets an entry
    holding a semaphore; waiters block on it; a wake releases N tokens.  A
    counting semaphore gives "no lost wakeups", and the WaitOnAddress contract
    explicitly allows spurious returns (the caller re-checks the value), so the
    design needs no condition variables and no new kernel surface.

    Structure follows VxKex's kernel33/woa.c: WOA_BUCKETS hash buckets keyed on
    (address >> 3), separate-chained per-address entries created on the first
    waiter and freed when the last waiter leaves.  Everything is built on the
    Win32 layer (kernel32 semaphore / critical-section / heap).

--*/

#include <windows.h>

//
// This NT 3.5 SDK's winnt.h exposes LIST_ENTRY / CONTAINING_RECORD but not the
// inline list macros or ERROR_TIMEOUT for user-mode builds; supply them (the
// canonical winnt.h definitions).
//
#ifndef InitializeListHead
#define InitializeListHead(Head) \
    ((Head)->Flink = (Head)->Blink = (Head))
#define InsertHeadList(Head, Entry) { \
    PLIST_ENTRY _EX_Flink = (Head)->Flink; \
    (Entry)->Flink = _EX_Flink; \
    (Entry)->Blink = (Head); \
    _EX_Flink->Blink = (Entry); \
    (Head)->Flink = (Entry); \
    }
#define RemoveEntryList(Entry) { \
    PLIST_ENTRY _EX_Blink = (Entry)->Blink; \
    PLIST_ENTRY _EX_Flink = (Entry)->Flink; \
    _EX_Blink->Flink = _EX_Flink; \
    _EX_Flink->Blink = _EX_Blink; \
    }
#endif

#ifndef ERROR_TIMEOUT
#define ERROR_TIMEOUT 1460L
#endif

#define WOA_BUCKETS 256

//
// One per watched address, alive only while Waiters > 0.  Address is the
// identity key; the semaphore is what waiters block on.
//
typedef struct _WOA_ENTRY {
    LIST_ENTRY  Link;
    PVOID       Address;
    HANDLE      Semaphore;
    ULONG       Waiters;
} WOA_ENTRY, *PWOA_ENTRY;

typedef struct _WOA_BUCKET {
    CRITICAL_SECTION Lock;
    LIST_ENTRY       Head;
} WOA_BUCKET;

static WOA_BUCKET WoaBuckets[WOA_BUCKETS];

//
// (addr >> 3) drops the bits that are constant for naturally-aligned
// objects, spreading addresses across the buckets.
//
static ULONG
WoaHash(
    volatile VOID *Address
    )
{
    return (ULONG)(((ULONG)Address >> 3) & (WOA_BUCKETS - 1));
}

//
// Compare *Address against the caller's snapshot for the given size.  Sizes
// other than 1/2/4/8 are invalid; treat them as "changed" so the caller never
// blocks forever on a bogus call.
//
static BOOLEAN
WoaEqual(
    volatile VOID *Address,
    PVOID          Compare,
    ULONG          Size
    )
{
    switch (Size) {
    case 1:
        return (BOOLEAN)(*(volatile UCHAR  *)Address == *(UCHAR  *)Compare);
    case 2:
        return (BOOLEAN)(*(volatile USHORT *)Address == *(USHORT *)Compare);
    case 4:
        return (BOOLEAN)(*(volatile ULONG  *)Address == *(ULONG  *)Compare);
    case 8:
        return (BOOLEAN)(((volatile ULONG *)Address)[0] == ((ULONG *)Compare)[0] &&
                         ((volatile ULONG *)Address)[1] == ((ULONG *)Compare)[1]);
    default:
        return FALSE;
    }
}

static PWOA_ENTRY
WoaFind(
    WOA_BUCKET    *Bucket,
    volatile VOID *Address
    )
{
    PLIST_ENTRY entry;

    for (entry = Bucket->Head.Flink;
         entry != &Bucket->Head;
         entry = entry->Flink) {
        PWOA_ENTRY w = CONTAINING_RECORD(entry, WOA_ENTRY, Link);
        if (w->Address == (PVOID)Address) {
            return w;
        }
    }
    return NULL;
}

//
// DLL entry point.  Initialise the bucket array on process attach.
//
BOOL
SynchDllInit(
    IN PVOID DllHandle,
    IN ULONG Reason,
    IN PVOID Context OPTIONAL
    )
{
    ULONG i;

    UNREFERENCED_PARAMETER( DllHandle );
    UNREFERENCED_PARAMETER( Context );

    if (Reason == DLL_PROCESS_ATTACH) {
        for (i = 0; i < WOA_BUCKETS; i += 1) {
            InitializeListHead( &WoaBuckets[i].Head );
            InitializeCriticalSection( &WoaBuckets[i].Lock );
        }
    }
    return TRUE;
}

//
// WaitOnAddress -- block while *Address still equals *CompareAddress, up to
// dwMilliseconds (INFINITE for no timeout).  Returns TRUE on a wake (which may
// be spurious -- the caller re-reads *Address and loops), FALSE + ERROR_TIMEOUT
// on timeout.  AddressSize is typed ULONG: SIZE_T is absent from the NT 3.5 SDK
// and is 32-bit on i386, so this is ABI-identical to the documented prototype.
//
BOOL
APIENTRY
WaitOnAddress(
    volatile VOID *Address,
    PVOID          CompareAddress,
    ULONG          AddressSize,
    DWORD          dwMilliseconds
    )
{
    WOA_BUCKET *bucket = &WoaBuckets[WoaHash( Address )];
    PWOA_ENTRY  w;
    HANDLE      sem;
    DWORD       wr;
    BOOL        result;

    EnterCriticalSection( &bucket->Lock );

    //
    // If the value already differs, there is nothing to wait for.  Checking
    // under the bucket lock -- which every WakeByAddress* call also takes --
    // closes the lost-wakeup window against a change+wake that races us here.
    //
    if (!WoaEqual( Address, CompareAddress, AddressSize )) {
        LeaveCriticalSection( &bucket->Lock );
        return TRUE;
    }

    //
    // Find or create the per-address waiter entry and join it.
    //
    w = WoaFind( bucket, Address );
    if (w == NULL) {
        w = (PWOA_ENTRY)HeapAlloc( GetProcessHeap(), 0, sizeof( WOA_ENTRY ) );
        if (w == NULL) {
            LeaveCriticalSection( &bucket->Lock );
            SetLastError( ERROR_NOT_ENOUGH_MEMORY );
            return FALSE;
        }
        w->Address   = (PVOID)Address;
        w->Waiters   = 0;
        w->Semaphore = CreateSemaphoreW( NULL, 0, MAXLONG, NULL );
        if (w->Semaphore == NULL) {
            HeapFree( GetProcessHeap(), 0, w );
            LeaveCriticalSection( &bucket->Lock );
            SetLastError( ERROR_NOT_ENOUGH_MEMORY );
            return FALSE;
        }
        InsertHeadList( &bucket->Head, &w->Link );
    }
    w->Waiters += 1;
    sem = w->Semaphore;

    //
    // Block outside the bucket lock.  A counting semaphore means a wake that
    // races our descheduling is not lost -- the token persists until we
    // consume it.  Any wake returns TRUE; spurious returns are contractual.
    //
    LeaveCriticalSection( &bucket->Lock );
    wr = WaitForSingleObject( sem, dwMilliseconds );
    EnterCriticalSection( &bucket->Lock );

    result = (wr == WAIT_OBJECT_0) ? TRUE : FALSE;

    //
    // Drop our reference; the last waiter out tears the entry down.
    //
    w->Waiters -= 1;
    if (w->Waiters == 0) {
        RemoveEntryList( &w->Link );
        CloseHandle( w->Semaphore );
        HeapFree( GetProcessHeap(), 0, w );
    }
    LeaveCriticalSection( &bucket->Lock );

    if (!result) {
        SetLastError( ERROR_TIMEOUT );
    }
    return result;
}

//
// WakeByAddressSingle -- release one waiter (if any) on Address.
//
VOID
APIENTRY
WakeByAddressSingle(
    PVOID Address
    )
{
    WOA_BUCKET *bucket = &WoaBuckets[WoaHash( Address )];
    PWOA_ENTRY  w;

    EnterCriticalSection( &bucket->Lock );
    w = WoaFind( bucket, Address );
    if (w != NULL && w->Waiters > 0) {
        ReleaseSemaphore( w->Semaphore, 1, NULL );
    }
    LeaveCriticalSection( &bucket->Lock );
}

//
// WakeByAddressAll -- release every current waiter on Address.  Over-release
// (a second wake before the waiters consume their tokens) is harmless: surplus
// tokens die with the entry when the last waiter leaves.
//
VOID
APIENTRY
WakeByAddressAll(
    PVOID Address
    )
{
    WOA_BUCKET *bucket = &WoaBuckets[WoaHash( Address )];
    PWOA_ENTRY  w;

    EnterCriticalSection( &bucket->Lock );
    w = WoaFind( bucket, Address );
    if (w != NULL && w->Waiters > 0) {
        ReleaseSemaphore( w->Semaphore, (LONG)w->Waiters, NULL );
    }
    LeaveCriticalSection( &bucket->Lock );
}
