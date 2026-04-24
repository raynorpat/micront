/*
 * cr_thread.c — C escape-hatch for spawning an OS thread that runs Lua
 * code in its own fresh lua_State.
 *
 * Why this is C, not Lua:
 *
 *   The thread entry passed to RtlCreateUserThread must be a real
 *   native function. An FFI callback (ffi.cast on a Lua function)
 *   re-enters the originating lua_State on invocation, which would
 *   corrupt the parent's VM since lua_State is single-threaded.
 *   Bringing up a fresh state on a new thread therefore requires
 *   native code — this file.
 *
 *   This is the architectural rule for cr's top-level C files: each
 *   one must justify itself with a "Lua + FFI cannot express this
 *   safely" reason. New additions need the same justification or they
 *   belong in lua/ as raw FFI.
 *
 * Lifetime model:
 *
 *   Everything the spawned thread reads or writes — the chunk source,
 *   the payload, the output buffer, the done event, and the
 *   CR_THREAD struct itself — is allocated on the process heap (the
 *   one PEB->ProcessHeap that NT 3.5's RtlAllocateHeap is internally
 *   thread-safe on). Nothing comes from Lua's GC.
 *
 *   Ownership is a 2-count refcount: parent and thread each hold one
 *   ref at spawn. Either party drops their ref when done with ctx
 *   (parent in _cr_thread_close, thread at end of _entry). Whoever
 *   atomically decrements to zero is the last toucher and runs
 *   _free_all. Neither party ever blocks the other; in particular
 *   _cr_thread_close NEVER calls NtTerminateThread (which would leak
 *   loader/heap critical sections held by the thread) and NEVER waits.
 *
 *   Crash safety: if the chunk takes the thread down before _entry's
 *   exit path runs (uncaught native exception, chunk-self-
 *   NtTerminateThread, stack overflow, ...), the thread's _release
 *   never fires and ctx would leak forever. To prevent this,
 *   _cr_thread_close polls thread_handle; if signaled and the
 *   thread_released CAS-flag is still 0, the parent claims the
 *   thread's reference and drops it on the thread's behalf. The flag
 *   is set in _entry's exit path before _release, so a normal exit
 *   loses the CAS race against the parent (intended).
 *
 *   Status reporting: ctx->status is initialised to STATUS_CRASH (3)
 *   at spawn. _entry's exit path overwrites it with 0 (chunk returned
 *   ok), 1 (chunk raised a Lua error), or 2 (couldn't even create a
 *   lua_State). If the parent reads 3 it knows the thread terminated
 *   without running its exit path — i.e. crashed.
 *
 * TLS hygiene:
 *
 *   nt.thread.run makes thread spawn cheap. A chunk that calls
 *   TlsAlloc and either forgets TlsFree or crashes would otherwise
 *   leak one of the 64 process-wide TLS indices per spawn — exhausted
 *   in seconds under any workload. We hook k32_memory.c's
 *   TlsAlloc/TlsFree to record per-thread which indices the chunk
 *   allocated (in ctx->tls_owned). _free_all walks the bitmap and
 *   TlsFrees any survivors before releasing ctx. Cleanup runs whether
 *   the thread exited normally or the parent claimed the ref via the
 *   crash path above.
 *
 *   Hooks find "current thread's CR_THREAD*" via TEB.ArbitraryUserPointer
 *   (fs:0x14), which cr reserves for this purpose. _entry stores ctx
 *   there immediately on entry. Threads not spawned by us read NULL
 *   from that slot (kernel zeroes the TEB), so their TlsAlloc/TlsFree
 *   activity is unaffected.
 */

#include "nt.h"          /* rt/nt.h via -Irt: NTSTATUS, HANDLE, BOOLEAN, ... */
#include "kernel32.h"    /* rt/kernel32.h: BOOL/DWORD, TlsFree decl */
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

#define EXPORT __declspec(dllexport)

/* ---- ntdll bits we need (kept local — see rt/nt.h policy) ---------- */

extern PVOID   NTAPI RtlAllocateHeap(HANDLE Heap, ULONG Flags, SIZE_T Size);
extern BOOLEAN NTAPI RtlFreeHeap    (HANDLE Heap, ULONG Flags, PVOID Mem);

extern NTSTATUS NTAPI NtCreateEvent (HANDLE *EventHandle, ULONG DesiredAccess,
                                     POBJECT_ATTRIBUTES Oa, int EventType,
                                     BOOLEAN InitialState);
extern NTSTATUS NTAPI NtSetEvent    (HANDLE EventHandle, LONG *PreviousState);
extern NTSTATUS NTAPI NtClose       (HANDLE Object);
extern NTSTATUS NTAPI NtWaitForSingleObject(HANDLE Object, BOOLEAN Alertable,
                                            PLARGE_INTEGER Timeout);
extern NTSTATUS NTAPI NtTerminateThread(HANDLE Thread, NTSTATUS ExitStatus);

/* k32_memory.c hooks (function pointers, NULL by default). */
extern void (*_k32_tls_alloc_hook)(DWORD idx);
extern void (*_k32_tls_free_hook) (DWORD idx);

extern NTSTATUS NTAPI RtlCreateUserThread(HANDLE Process,
                                          PVOID  ThreadSecurityDescriptor,
                                          BOOLEAN CreateSuspended,
                                          ULONG ZeroBits,
                                          ULONG MaximumStackSize,
                                          ULONG CommittedStackSize,
                                          PVOID StartAddress,
                                          PVOID StartParameter,
                                          HANDLE *Thread,
                                          PVOID  ClientId);

/* PEB->ProcessHeap captured by libc_init.c (rt/libc_heap.c uses it for
 * malloc). We borrow the same heap so allocations made here can be
 * compared / freed against the same handle malloc uses. */
extern HANDLE _libc_heap;

#define HEAP                _libc_heap
#define EVENT_ALL_ACCESS    0x1F0003
#define NotificationEvent   0
#define STATUS_TIMEOUT      ((NTSTATUS)0x00000102L)
#define INFINITE            ((ULONG)0xFFFFFFFF)

#define DEFAULT_OUT_CAP     (4 * 1024)
#define DEFAULT_STACK_RES   (256 * 1024)
#define DEFAULT_STACK_COM   ( 16 * 1024)

/* status values stamped into ctx->status. STATUS_CRASH is the spawn-
 * time default; _entry's exit path overwrites with one of the others
 * before signalling done_event. If parent reads CRASH, the chunk took
 * the thread down before the exit path could run. */
#define STATUS_OK           0
#define STATUS_LUA_ERROR    1
#define STATUS_PANIC        2     /* couldn't create lua_State */
#define STATUS_CRASH        3     /* thread died before exit path */

#define TLS_BITMAP_BYTES    8     /* TEB_TLS_SLOT_COUNT (64) bits */

/* ---- internal structure (opaque to Lua) ---------------------------- */

struct CR_THREAD {
    HANDLE thread_handle;
    HANDLE done_event;       /* NotificationEvent: set when result ready */
    char  *chunk;     ULONG chunk_len;
    char  *payload;   ULONG payload_len;
    char  *out_buf;   ULONG out_cap;   ULONG out_len;
    int    status;           /* one of STATUS_* */
    LONG   refcount;         /* parent + thread = 2 at spawn */
    volatile UCHAR thread_released;  /* CAS-flag: thread has called _release */
    UCHAR  tls_owned[TLS_BITMAP_BYTES]; /* bits: TLS indices owned by chunk */
};

/* ---- TEB.ArbitraryUserPointer (fs:0x14) — current-thread ctx ------- */
/*
 * cr stores the spawned thread's CR_THREAD* here so the TlsAlloc/TlsFree
 * hooks (which run inside arbitrary call sites) can find it without a
 * thread-table lookup. Threads not spawned by cr leave the slot at the
 * kernel's zero-init value of NULL; hooks no-op for those.
 */
static __inline__ struct CR_THREAD *_get_thread_ctx(void)
{
    void *p;
    __asm__ ("movl %%fs:0x14, %0" : "=r"(p));
    return (struct CR_THREAD *)p;
}

static __inline__ void _set_thread_ctx(struct CR_THREAD *t)
{
    __asm__ volatile ("movl %0, %%fs:0x14" : : "r"(t) : "memory");
}

/* ---- TLS-tracking hooks -------------------------------------------- */

static void _on_tls_alloc(DWORD idx)
{
    struct CR_THREAD *t = _get_thread_ctx();
    if (t && idx < (TLS_BITMAP_BYTES * 8)) {
        t->tls_owned[idx >> 3] |= (UCHAR)(1u << (idx & 7));
    }
}

static void _on_tls_free(DWORD idx)
{
    struct CR_THREAD *t = _get_thread_ctx();
    if (t && idx < (TLS_BITMAP_BYTES * 8)) {
        t->tls_owned[idx >> 3] &= (UCHAR)~(1u << (idx & 7));
    }
}

/* Install the TlsAlloc/TlsFree hooks once. CAS-guarded so concurrent
 * first-spawns from multiple threads don't double-install (idempotent
 * either way; the CAS just avoids redundant writes). */
static volatile LONG _hooks_installed = 0;
static void _ensure_hooks(void)
{
    if (__sync_lock_test_and_set(&_hooks_installed, 1) == 0) {
        _k32_tls_alloc_hook = _on_tls_alloc;
        _k32_tls_free_hook  = _on_tls_free;
    }
}

/* ---- helpers -------------------------------------------------------- */

/* Free every kernel handle and heap block in ctx, then ctx itself.
 * Caller must have proven nobody else will dereference t.
 *
 * Reclaims any TLS indices the chunk allocated and didn't release —
 * runs whether the thread exited normally (thread does the final
 * decrement) or the parent claimed the thread's ref via the crash
 * path. TlsFree's hook will re-enter _on_tls_free, which clears bits
 * in t->tls_owned via _get_thread_ctx — but the calling context's
 * fs:0x14 may or may not be t (parent thread = NULL; spawned thread =
 * t). Either way harmless: the bitmap is going away with t. */
static void _free_all(struct CR_THREAD *t)
{
    int i;
    for (i = 0; i < (TLS_BITMAP_BYTES * 8); i++) {
        if (t->tls_owned[i >> 3] & (UCHAR)(1u << (i & 7))) {
            TlsFree((DWORD)i);
        }
    }
    if (t->thread_handle) NtClose(t->thread_handle);
    if (t->done_event)    NtClose(t->done_event);
    if (t->chunk)   RtlFreeHeap(HEAP, 0, t->chunk);
    if (t->payload) RtlFreeHeap(HEAP, 0, t->payload);
    if (t->out_buf) RtlFreeHeap(HEAP, 0, t->out_buf);
    RtlFreeHeap(HEAP, 0, t);
}

/* Drop one reference. Whoever decrements to zero is by definition the
 * last toucher (the other party's decrement-and-step-away has already
 * happened) and is safe to free. Atomic via gcc's lock-prefixed builtin. */
static void _release(struct CR_THREAD *t)
{
    if (__sync_sub_and_fetch(&t->refcount, 1) == 0) _free_all(t);
}

static void _copy_result(struct CR_THREAD *t, lua_State *L, int lua_status)
{
    size_t      len;
    const char *s = lua_tolstring(L, -1, &len);
    ULONG       i;

    if (s == 0) { s = ""; len = 0; }
    if (len > t->out_cap) len = t->out_cap;
    for (i = 0; i < (ULONG)len; i++) t->out_buf[i] = s[i];
    t->out_len = (ULONG)len;
    t->status  = (lua_status == 0) ? STATUS_OK : STATUS_LUA_ERROR;
}

/* ---- thread entry --------------------------------------------------- */

/* Native-NT thread entries are contractually one-way: `RtlInitializeContext`
 * (rtl/i386/context.c) sets up the stack with a parameter at [esp+4] and
 * a "return address" slot at [esp+0] that it never writes. If the entry
 * function returns, `ret` pops 0 into EIP and the thread crashes with
 * STATUS_ACCESS_VIOLATION. Win32's kernel32 wraps entries in
 * BaseThreadStartThunk → ExitThread; native ntdll callers (us) must call
 * NtTerminateThread ourselves before returning. */
static ULONG NTAPI _entry(PVOID raw)
{
    struct CR_THREAD *t = (struct CR_THREAD *)raw;
    lua_State *L;

    /* Stash ctx in TEB.ArbitraryUserPointer FIRST — before any TlsAlloc
     * the chunk might trigger via require()/luaL_openlibs/etc. The
     * hooks find it here. */
    _set_thread_ctx(t);

    L = luaL_newstate();
    if (L == 0) {
        t->status  = STATUS_PANIC;
        t->out_len = 0;
    } else {
        int rc;
        luaL_openlibs(L);

        /* Expose payload as the global PAYLOAD. Always a string,
         * possibly empty. The chunk reads it like any other global. */
        lua_pushlstring(L, t->payload, (size_t)t->payload_len);
        lua_setglobal(L, "PAYLOAD");

        rc = luaL_loadbuffer(L, t->chunk, (size_t)t->chunk_len, "=thread");
        if (rc == 0) rc = lua_pcall(L, 0, 1, 0);

        /* On both ok and error, top of stack is a string we marshal
         * back (return value, or pcall error message). _copy_result
         * overwrites STATUS_CRASH with STATUS_OK or STATUS_LUA_ERROR.
         * If we never reach this line — chunk did NtTerminateThread,
         * unhandled native exception, stack overflow — status stays at
         * STATUS_CRASH and the parent sees it. */
        _copy_result(t, L, rc);
        lua_close(L);
    }
    NtSetEvent(t->done_event, 0);

    /* Mark the thread as having reached its exit path BEFORE releasing.
     * Parent's close polls thread_handle and CAS-claims this flag if
     * the thread terminated without setting it (= crashed). The order
     * (set flag → _release) means a normal exit always loses the CAS
     * race against a parent that polls between the two. Acceptable —
     * the loser just doesn't perform the redundant claim. */
    __sync_lock_test_and_set(&t->thread_released, 1);
    _release(t);

    /* Clear ctx pointer in TEB before exiting — defensive only; the
     * TEB is about to be freed by the kernel. */
    _set_thread_ctx(0);
    NtTerminateThread((HANDLE)(long)-2 /* NtCurrentThread */, 0);
    return 0;                 /* unreachable */
}

/* ---- exported API --------------------------------------------------- */

EXPORT struct CR_THREAD *_cr_thread_spawn(const char *chunk,   ULONG chunk_len,
                                          const char *payload, ULONG payload_len)
{
    struct CR_THREAD *t;
    NTSTATUS st;
    HANDLE   h;
    ULONG    i;

    /* Install the TLS hooks the first time we're called. Cheap CAS;
     * idempotent across re-entries. */
    _ensure_hooks();

    t = (struct CR_THREAD *)RtlAllocateHeap(HEAP, HEAP_ZERO_MEMORY, sizeof(*t));
    if (t == 0) return 0;

    t->chunk_len   = chunk_len;
    t->payload_len = payload_len;
    t->out_cap     = DEFAULT_OUT_CAP;
    t->refcount    = 2;       /* parent + thread */
    t->status      = STATUS_CRASH;   /* sentinel: overwritten on normal exit */

    /* Always allocate at least 1 byte so a zero-length chunk/payload
     * still gets a valid (distinct) pointer that _free_all can release. */
    t->chunk   = (char *)RtlAllocateHeap(HEAP, 0, chunk_len   ? chunk_len   : 1);
    t->payload = (char *)RtlAllocateHeap(HEAP, 0, payload_len ? payload_len : 1);
    t->out_buf = (char *)RtlAllocateHeap(HEAP, 0, t->out_cap);
    if (!t->chunk || !t->payload || !t->out_buf) {
        _free_all(t);
        return 0;
    }
    for (i = 0; i < chunk_len;   i++) t->chunk  [i] = chunk  [i];
    for (i = 0; i < payload_len; i++) t->payload[i] = payload[i];

    st = NtCreateEvent(&t->done_event, EVENT_ALL_ACCESS, 0,
                       NotificationEvent, 0);
    if (st < 0) { t->done_event = 0; _free_all(t); return 0; }

    st = RtlCreateUserThread(
            (HANDLE)(long)-1,        /* current process pseudo-handle */
            0,                        /* no security descriptor */
            0,                        /* not suspended */
            0,                        /* zero bits */
            DEFAULT_STACK_RES,
            DEFAULT_STACK_COM,
            (PVOID)_entry,
            (PVOID)t,
            &h,
            0);                       /* don't care about ClientId */
    if (st < 0) { _free_all(t); return 0; }

    t->thread_handle = h;
    return t;
}

/* Borrowed thread handle, valid until _cr_thread_close. */
EXPORT HANDLE _cr_thread_handle(struct CR_THREAD *t)
{
    return t ? t->thread_handle : 0;
}

/* Non-blocking poll: has the thread terminated yet?
 *
 * Returns 1 = thread terminated (handle signaled, _entry done or
 * crashed), 0 = still running, -1 = error or invalid ctx.
 *
 * NEVER blocks. The C side deliberately exposes no blocking-wait
 * primitive: any actual waiting is the Lua side's job, which lets a
 * future reactor intercept and replace blocking shapes with coroutine
 * yields without touching this file. Lua-side `nt.thread:wait` is
 * implemented over `nt.dll.ke.NtWaitForSingleObject` on the borrowed
 * thread handle. */
EXPORT int _cr_thread_done(struct CR_THREAD *t)
{
    LARGE_INTEGER zero;
    NTSTATUS st;
    if (!t || !t->thread_handle) return -1;
    zero.LowPart = 0; zero.HighPart = 0;
    st = NtWaitForSingleObject(t->thread_handle, 0, &zero);
    if (st == 0)              return 1;
    if (st == STATUS_TIMEOUT) return 0;
    return -1;
}

/* Caller must confirm via _cr_thread_done (or wait on the thread
 * handle Lua-side) that the thread has terminated before reading a
 * result. *out_buf and *out_len are written; pointer remains valid
 * until _cr_thread_close. Returns thread status:
 *   0 = ok (chunk returned a string),
 *   1 = lua error (out_buf carries the error message),
 *   2 = panic (couldn't create lua_State; out_buf empty),
 *   3 = crash (thread terminated before its exit path ran). */
EXPORT int _cr_thread_result(struct CR_THREAD *t,
                             const char **out_buf, ULONG *out_len)
{
    if (!t) return -1;
    if (out_buf) *out_buf = t->out_buf;
    if (out_len) *out_len = t->out_len;
    return t->status;
}

/* Drop the parent's reference. Returns immediately, never blocks.
 *
 * Three cases:
 *
 *   1. Thread still running: drop parent's ref. Thread keeps its ref
 *      and will run cleanup when it eventually exits. ctx survives.
 *
 *   2. Thread exited normally: thread already _release'd before
 *      terminating. Parent's _release brings refcount to zero,
 *      triggering _free_all (TLS cleanup + handle close + heap free).
 *
 *   3. Thread crashed (terminated without running its exit path —
 *      uncaught native exception, chunk-self-NtTerminateThread,
 *      stack overflow): thread's _release was never called, so
 *      refcount is still 2. Without intervention, parent's drop
 *      would leave refcount at 1 and ctx (including the leaked
 *      TLS index bitmap) would live until process exit.
 *
 *      We detect this by polling thread_handle for signaled state
 *      and CAS-claiming the thread_released flag. If we win the CAS
 *      (flag was 0 → thread didn't reach its exit), we _release on
 *      the thread's behalf so the refcount can reach zero and
 *      _free_all reclaims the TLS indices.
 *
 * Crucially this does NOT call NtTerminateThread. Killing a thread
 * that holds a kernel critical section (e.g. mid-LdrLoadDll, mid-
 * heap-allocation) leaves that section locked forever and deadlocks
 * the rest of the process. Cooperative cancellation (signal an event
 * the chunk waits on) is the caller's responsibility. */
EXPORT void _cr_thread_close(struct CR_THREAD *t)
{
    LARGE_INTEGER zero;

    if (!t) return;

    /* Crash detection: thread_handle becomes signaled on ANY thread
     * exit, normal or abnormal. If signaled and the thread didn't
     * mark itself released (CAS-claim wins), it crashed — release on
     * its behalf so refcount can reach zero and TLS cleanup runs. */
    if (t->thread_handle) {
        zero.LowPart = 0; zero.HighPart = 0;
        if (NtWaitForSingleObject(t->thread_handle, 0, &zero) == 0 &&
            __sync_lock_test_and_set(&t->thread_released, 1) == 0)
        {
            _release(t);   /* extra decrement on the dead thread's behalf */
        }
    }

    _release(t);           /* parent's own decrement */
}
