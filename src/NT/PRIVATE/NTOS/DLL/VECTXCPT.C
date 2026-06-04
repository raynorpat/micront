/*++

Module Name:

    vectxcpt.c

Abstract:

    Vectored exception handlers (user mode only).  Backported from the NT 5.x
    ntdll: a process-wide list of handlers that RtlDispatchException consults
    BEFORE the frame-based SEH search.  A handler returns
    EXCEPTION_CONTINUE_EXECUTION to resume the faulting context, or
    EXCEPTION_CONTINUE_SEARCH to defer to the normal SEH chain.

    Backs kernel32!AddVectoredExceptionHandler -- the stack-overflow guard that
    Rust's std (and the MSVC CRT) install at process startup.

    The list head and lock are initialized once by LdrpInitializeProcess; the
    callout site is in rtl\i386\exdsptch.c under #ifndef NTOS_KERNEL_RUNTIME
    (vectored handlers exist only in user mode).

--*/

#include <ntos.h>
#include <ntrtl.h>
#include <nturtl.h>
#include <heap.h>

//
// Filter return values a vectored handler may give us.  These post-date this
// SDK's headers, so define them if absent.
//
#ifndef EXCEPTION_CONTINUE_EXECUTION
#define EXCEPTION_CONTINUE_EXECUTION (-1)
#endif
#ifndef EXCEPTION_CONTINUE_SEARCH
#define EXCEPTION_CONTINUE_SEARCH    (0)
#endif

#ifndef PVECTORED_EXCEPTION_HANDLER
typedef LONG (NTAPI *PVECTORED_EXCEPTION_HANDLER)(
    struct _EXCEPTION_POINTERS *ExceptionInfo
    );
#endif

typedef struct _VECTXCPT_CALLOUT_ENTRY {
    LIST_ENTRY                  Links;
    PVECTORED_EXCEPTION_HANDLER VectoredHandler;
} VECTXCPT_CALLOUT_ENTRY, *PVECTXCPT_CALLOUT_ENTRY;

//
// Process-wide handler list + lock.  Defined here; initialized in ldrinit.c
// (which declares them extern).
//
LIST_ENTRY           RtlpCalloutEntryList;
RTL_CRITICAL_SECTION RtlpCalloutEntryLock;

//
// RtlCallVectoredExceptionHandlers -- called from RtlDispatchException before
// the frame-based search.  Returns TRUE (and the caller restores the context)
// if some handler asked to continue execution; FALSE to proceed with SEH.
//
BOOLEAN
RtlCallVectoredExceptionHandlers(
    IN PEXCEPTION_RECORD ExceptionRecord,
    IN PCONTEXT          ContextRecord
    )
{
    PLIST_ENTRY             Next;
    PVECTXCPT_CALLOUT_ENTRY CalloutEntry;
    LONG                    ReturnValue;
    EXCEPTION_POINTERS      ExceptionInfo;

    //
    // A NULL Flink means the list head has not been initialized yet (an
    // exception during very early ntdll init, before LdrpInitializeProcess);
    // treat that as 'no handlers'.
    //
    if (RtlpCalloutEntryList.Flink == NULL ||
        IsListEmpty(&RtlpCalloutEntryList)) {
        return FALSE;
    }

    ExceptionInfo.ExceptionRecord = ExceptionRecord;
    ExceptionInfo.ContextRecord   = ContextRecord;

    RtlEnterCriticalSection(&RtlpCalloutEntryLock);
    Next = RtlpCalloutEntryList.Flink;
    while (Next != &RtlpCalloutEntryList) {
        CalloutEntry = CONTAINING_RECORD(Next, VECTXCPT_CALLOUT_ENTRY, Links);
        ReturnValue = (CalloutEntry->VectoredHandler)(&ExceptionInfo);
        if (ReturnValue == EXCEPTION_CONTINUE_EXECUTION) {
            RtlLeaveCriticalSection(&RtlpCalloutEntryLock);
            return TRUE;
        }
        Next = Next->Flink;
    }
    RtlLeaveCriticalSection(&RtlpCalloutEntryLock);
    return FALSE;
}

//
// RtlAddVectoredExceptionHandler -- register a handler at the head (FirstHandler
// != 0) or tail of the list.  Returns an opaque handle for removal, or NULL on
// allocation failure.
//
PVOID
RtlAddVectoredExceptionHandler(
    IN ULONG                       FirstHandler,
    IN PVECTORED_EXCEPTION_HANDLER VectoredHandler
    )
{
    PVECTXCPT_CALLOUT_ENTRY CalloutEntry;

    CalloutEntry = RtlAllocateHeap(RtlProcessHeap(), 0, sizeof(*CalloutEntry));
    if (CalloutEntry) {
        CalloutEntry->VectoredHandler = VectoredHandler;
        RtlEnterCriticalSection(&RtlpCalloutEntryLock);
        if (FirstHandler) {
            InsertHeadList(&RtlpCalloutEntryList, &CalloutEntry->Links);
        } else {
            InsertTailList(&RtlpCalloutEntryList, &CalloutEntry->Links);
        }
        RtlLeaveCriticalSection(&RtlpCalloutEntryLock);
    }
    return CalloutEntry;
}

//
// RtlRemoveVectoredExceptionHandler -- unregister a handler by its handle.
// Returns TRUE if found and removed, FALSE otherwise.
//
ULONG
RtlRemoveVectoredExceptionHandler(
    IN PVOID VectoredHandlerHandle
    )
{
    PLIST_ENTRY             Next;
    PVECTXCPT_CALLOUT_ENTRY CalloutEntry;

    RtlEnterCriticalSection(&RtlpCalloutEntryLock);
    Next = RtlpCalloutEntryList.Flink;
    while (Next != &RtlpCalloutEntryList) {
        CalloutEntry = CONTAINING_RECORD(Next, VECTXCPT_CALLOUT_ENTRY, Links);
        if (CalloutEntry == VectoredHandlerHandle) {
            RemoveEntryList(&CalloutEntry->Links);
            RtlLeaveCriticalSection(&RtlpCalloutEntryLock);
            RtlFreeHeap(RtlProcessHeap(), 0, CalloutEntry);
            return TRUE;
        }
        Next = Next->Flink;
    }
    RtlLeaveCriticalSection(&RtlpCalloutEntryLock);
    return FALSE;
}
