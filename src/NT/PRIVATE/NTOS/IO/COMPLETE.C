/*++

Copyright (c) 1994  Microsoft Corporation

Module Name:

    complete.c

Abstract:

   This module implements the executive I/O completion object. Functions are
   provided to create, open, query, and wait for I/O completion objects.

Author:

    David N. Cutler (davec) 25-Feb-1994

Environment:

    Kernel mode only.

Revision History:

--*/

#include "iop.h"

//
// Define section types for appropriate functions.
//

#ifdef ALLOC_PRAGMA
#pragma alloc_text(PAGE, NtCreateIoCompletion)
#pragma alloc_text(PAGE, NtOpenIoCompletion)
#pragma alloc_text(PAGE, NtQueryIoCompletion)
#pragma alloc_text(PAGE, NtRemoveIoCompletion)
#pragma alloc_text(PAGE, NtRemoveIoCompletionEx)
#pragma alloc_text(PAGE, NtSetIoCompletion)
#endif

NTSTATUS
NtCreateIoCompletion (
    IN PHANDLE IoCompletionHandle,
    IN ACCESS_MASK DesiredAccess,
    IN POBJECT_ATTRIBUTES ObjectAttributes OPTIONAL,
    IN ULONG Count OPTIONAL
    )

/*++

Routine Description:

    This function creates an I/O completion object, sets the maximum
    target concurrent thread count to the specified value, and opens
    a handle to the object with the specified desired access.

Arguments:

    IoCompletionHandle - Supplies a pointer to a variable that receives
        the I/O completion object handle.

    DesiredAccess - Supplies the desired types of access for the I/O
        completion object.

    ObjectAttributes - Supplies a pointer to an object attributes structure.

    Count - Supplies the target maximum  number of threads that should
        be concurrently active. If this parameter is not specified, then
        the number of processors is used.

Return Value:

    STATUS_SUCCESS is returned if the function is success. Otherwise, an
    error status is returned.

--*/

{

    HANDLE Handle;
    KPROCESSOR_MODE PreviousMode;
    PVOID IoCompletion;
    NTSTATUS Status;

    //
    // Establish an exception handler, probe the output handle address, and
    // attempt to create an I/O completion object. If the probe fails, then
    // return the exception code as the service status. Otherwise, return the
    // status value returned by the object insertion routine.
    //

    try {

        //
        // Get previous processor mode and probe output handle address if
        // necessary.
        //

        PreviousMode = KeGetPreviousMode();
        if (PreviousMode != KernelMode) {
            ProbeForWriteHandle(IoCompletionHandle);
        }

        //
        // Allocate I/O completion object.
        //

        Status = ObCreateObject(PreviousMode,
                                IoCompletionObjectType,
                                ObjectAttributes,
                                PreviousMode,
                                NULL,
                                sizeof(KQUEUE),
                                0,
                                0,
                                (PVOID *)&IoCompletion);

        //
        // If the I/O completion object was successfully allocated, then
        // initialize the object and attempt to insert it in the handle
        // table of the current process.
        //

        if (NT_SUCCESS(Status)) {
            KeInitializeQueue((PKQUEUE)IoCompletion, Count);
            Status = ObInsertObject(IoCompletion,
                                    NULL,
                                    DesiredAccess,
                                    0,
                                    (PVOID *)NULL,
                                    &Handle);

            //
            // If the I/O completion object was successfully inserted in
            // the handle table of the current process, then attempt to
            // write the handle value. If the write attempt fails, then
            // do not report an error. When the caller attempts to access
            // the handle value, an access violation will occur.
            //

            if (NT_SUCCESS(Status)) {
                try {
                    *IoCompletionHandle = Handle;

                } except(ExSystemExceptionFilter()) {
                    //
                    // ObInsertObject installed Handle in the caller's
                    // table; close it so a faulted user write doesn't
                    // leak the handle name.
                    //
                    NtClose(Handle);
                    Status = GetExceptionCode();
                }
            }
        }

    //
    // If an exception occurs during the probe of the output handle address,
    // then always handle the exception and return the exception code as the
    // status value.
    //

    } except(ExSystemExceptionFilter()) {
        Status = GetExceptionCode();
    }

    //
    // Return service status.
    //

    return Status;
}

NTSTATUS
NtOpenIoCompletion (
    OUT PHANDLE IoCompletionHandle,
    IN ACCESS_MASK DesiredAccess,
    IN POBJECT_ATTRIBUTES ObjectAttributes
    )

/*++

Routine Description:

    This function opens a handle to an I/O completion object with the
    specified desired access.

Arguments:

    IoCompletionHandle - Supplies a pointer to a variable that receives
        the completion object handle.

    DesiredAccess - Supplies the desired types of access for the I/O
        completion object.

    ObjectAttributes - Supplies a pointer to an object attributes structure.

Return Value:

    STATUS_SUCCESS is returned if the function is success. Otherwise, an
    error status is returned.

--*/

{

    HANDLE Handle;
    KPROCESSOR_MODE PreviousMode;
    NTSTATUS Status;

    //
    // Establish an exception handler, probe the output handle address,
    // and attempt to open an I/O completion object. If the probe fails,
    // then return the exception code as the service status. Otherwise,
    // return the status value returned by the object open routine.
    //

    try {

        //
        // Get previous processor mode and probe output handle address if
        // necessary.
        //

        PreviousMode = KeGetPreviousMode();
        if (PreviousMode != KernelMode) {
            ProbeForWriteHandle(IoCompletionHandle);
        }

        //
        // Open handle to the completion object with the specified desired
        // access.
        //

        Status = ObOpenObjectByName(ObjectAttributes,
                                    IoCompletionObjectType,
                                    PreviousMode,
                                    NULL,
                                    DesiredAccess,
                                    NULL,
                                    &Handle);

        //
        // If the open was successful, then attempt to write the I/O
        // completion object handle value. If the write attempt fails,
        // then do not report an error. When the caller attempts to
        // access the handle value, an access violation will occur.
        //

        if (NT_SUCCESS(Status)) {
            try {
                *IoCompletionHandle = Handle;

            } except(ExSystemExceptionFilter()) {
                //
                // Handle is already installed in the caller's table by
                // ObOpenObjectByName; close it so a faulted user write
                // doesn't leak the handle name.
                //
                NtClose(Handle);
                Status = GetExceptionCode();
            }
        }

    //
    // If an exception occurs during the probe of the output handle address,
    // then always handle the exception and return the exception code as the
    // status value.
    //

    } except(ExSystemExceptionFilter()) {
        Status = GetExceptionCode();
    }


    //
    // Return service status.
    //

    return Status;
}

NTSTATUS
NtQueryIoCompletion (
    IN HANDLE IoCompletionHandle,
    IN IO_COMPLETION_INFORMATION_CLASS IoCompletionInformationClass,
    OUT PVOID IoCompletionInformation,
    IN ULONG IoCompletionInformationLength,
    OUT PULONG ReturnLength OPTIONAL
    )

/*++

Routine Description:

    This function queries the state of an I/O completion object and returns
    the requested information in the specified record structure.

Arguments:

    IoCompletionHandle - Supplies a handle to an I/O completion object.

    IoCompletionInformationClass - Supplies the class of information being
        requested.

    IoCompletionInformation - Supplies a pointer to a record that receives
        the requested information.

    IoCompletionInformationLength - Supplies the length of the record that
        receives the requested information.

    ReturnLength - Supplies an optional pointer to a variable that receives
        the actual length of the information that is returned.

Return Value:

    STATUS_SUCCESS is returned if the function is success. Otherwise, an
    error status is returned.

--*/

{

    PVOID IoCompletion;
    LONG Depth;
    KPROCESSOR_MODE PreviousMode;
    NTSTATUS Status;

    //
    // Establish an exception handler, probe the output arguments, reference
    // the I/O completion object, and return the specified information. If
    // the probe fails, then return the exception code as the service status.
    // Otherwise return the status value returned by the reference object by
    // handle routine.
    //

    try {

        //
        // Get previous processor mode and probe output arguments if necessary.
        //

        PreviousMode = KeGetPreviousMode();
        if (PreviousMode != KernelMode) {
            ProbeForWrite(IoCompletionInformation,
                          sizeof(IO_COMPLETION_BASIC_INFORMATION),
                          sizeof(ULONG));

            if (ARGUMENT_PRESENT(ReturnLength)) {
                ProbeForWriteUlong(ReturnLength);
            }
        }

        //
        // Check argument validity.
        //

        if (IoCompletionInformationClass != IoCompletionBasicInformation) {
            return STATUS_INVALID_INFO_CLASS;
        }

        if (IoCompletionInformationLength != sizeof(IO_COMPLETION_BASIC_INFORMATION)) {
            return STATUS_INFO_LENGTH_MISMATCH;
        }

        //
        // Reference the I/O completion object by handle.
        //

        Status = ObReferenceObjectByHandle(IoCompletionHandle,
                                           IO_COMPLETION_QUERY_STATE,
                                           IoCompletionObjectType,
                                           PreviousMode,
                                           &IoCompletion,
                                           NULL);

        //
        // If the reference was successful, then read the current state of
        // the I/O completion object, dereference the I/O completion object,
        // fill in the information structure, and return the structure length
        // if specified. If the write of the I/O completion information or
        // the return length fails, then do not report an error. When the
        // caller accesses the information structure or length an access
        // violation will occur.
        //

        if (NT_SUCCESS(Status)) {
            Depth = KeReadStateQueue((PKQUEUE)IoCompletion);
            ObDereferenceObject(IoCompletion);
            try {
                ((PIO_COMPLETION_BASIC_INFORMATION)IoCompletionInformation)->Depth = Depth;
                if (ARGUMENT_PRESENT(ReturnLength)) {
                    *ReturnLength = sizeof(IO_COMPLETION_BASIC_INFORMATION);
                }

            } except(ExSystemExceptionFilter()) {
                NOTHING;
            }
        }

    //
    // If an exception occurs during the probe of the output arguments, then
    // always handle the exception and return the exception code as the status
    // value.
    //

    } except(ExSystemExceptionFilter()) {
        Status = GetExceptionCode();
    }

    //
    // Return service status.
    //

    return Status;
}

NTSTATUS
NtRemoveIoCompletion (
    IN HANDLE IoCompletionHandle,
    OUT PVOID *KeyContext,
    OUT PVOID *ApcContext,
    OUT PIO_STATUS_BLOCK IoStatusBlock,
    IN PLARGE_INTEGER Timeout OPTIONAL
    )

/*++

Routine Description:

    This function removes an entry from an I/O completion object. If there
    are currently no entries available, then the calling thread waits for
    an entry.

Arguments:

    Completion - Supplies a handle to an I/O completion object.

    KeyContext - Supplies a pointer to a variable that receives the key
        context that was specified when the I/O completion object was
        assoicated with a file object.

    ApcContext - Supplies a pointer to a variable that receives the
        context that was specified when the I/O operation was issued.

    IoStatus - Supplies a pointer to a variable that receives the
        I/O completion status.

    Timeout - Supplies a pointer to an optional time out value.

Return Value:

    STATUS_SUCCESS is returned if the function is success. Otherwise, an
    error status is returned.

--*/

{

    PLARGE_INTEGER CapturedTimeout;
    PLIST_ENTRY Entry;
    PVOID IoCompletion;
    PIRP Irp;
    PIOP_MINI_COMPLETION_PACKET MiniPacket;
    BOOLEAN PacketIsIrp;
    KPROCESSOR_MODE PreviousMode;
    NTSTATUS Status;
    LARGE_INTEGER TimeoutValue;
    PVOID LocalApcContext;
    PVOID LocalKeyContext;
    IO_STATUS_BLOCK LocalIoStatusBlock;

    //
    // Establish an exception handler, probe the I/O context, the I/O
    // status, and the optional timeout value if specified, reference
    // the I/O completion object, and attempt to remove an entry from
    // the I/O completion object. If the probe fails, then return the
    // exception code as the service status. Otherwise, return a value
    // dependent on the outcome of the queue removal.
    //

    try {

        //
        // Get previous processor mode and probe the I/O context, status,
        // and timeout if necessary.
        //

        CapturedTimeout = NULL;
        PreviousMode = KeGetPreviousMode();
        if (PreviousMode != KernelMode) {
            ProbeForWriteLong((PLONG)ApcContext);
            ProbeForWriteLong((PLONG)KeyContext);
            ProbeForWriteIoStatus(IoStatusBlock);
            if (ARGUMENT_PRESENT(Timeout)) {
                CapturedTimeout = &TimeoutValue;
                TimeoutValue = ProbeAndReadLargeInteger(Timeout);
            }

        } else{
            if (ARGUMENT_PRESENT(Timeout)) {
                CapturedTimeout = Timeout;
            }
        }

        //
        // Reference the I/O completion object by handle.
        //

        Status = ObReferenceObjectByHandle(IoCompletionHandle,
                                           IO_COMPLETION_MODIFY_STATE,
                                           IoCompletionObjectType,
                                           PreviousMode,
                                           &IoCompletion,
                                           NULL);

        //
        // If the reference was successful, then attempt to remove an entry
        // from the I/O completion object. If an entry is removed from the
        // I/O completion object, then capture the completion information,
        // release the associated IRP, and attempt to write the completion
        // inforamtion. If the write of the completion infomation fails,
        // then do not report an error. When the caller attempts to access
        // the completion information, an access violation will occur.
        //

        if (NT_SUCCESS(Status)) {
            Entry = KeRemoveQueue((PKQUEUE)IoCompletion,
                                  PreviousMode,
                                  CapturedTimeout);

            //
            // N.B. The entry value returned can be the address of a list
            //      entry, STATUS_USER_APC, or STATUS_TIMEOUT.
            //

            if (((NTSTATUS)Entry == STATUS_TIMEOUT) ||
                ((NTSTATUS)Entry == STATUS_USER_APC)) {
                Status = (NTSTATUS)Entry;

            } else {

                //
                // Set the completion status, capture the completion
                // information, deallocate the associated IRP, and
                // attempt to write the completion information.
                //

                Status = STATUS_SUCCESS;

                //
                // The entry is either a completed IRP or a packet posted by
                // NtSetIoCompletion; the tag in the slot after the LIST_ENTRY
                // says which.  Capture the completion fields from the right one.
                //

                PacketIsIrp = (BOOLEAN)
                    (IopCompletionPacketType(Entry) == IopCompletionPacketIrp);

                if (PacketIsIrp) {
                    Irp = CONTAINING_RECORD(Entry, IRP, Tail.Overlay.ListEntry);
                    LocalApcContext = Irp->Overlay.AsynchronousParameters.UserApcContext;
                    LocalKeyContext = (PVOID)Irp->Tail.CompletionKey;
                    LocalIoStatusBlock = Irp->IoStatus;
                } else {
                    MiniPacket = CONTAINING_RECORD(Entry,
                                                   IOP_MINI_COMPLETION_PACKET,
                                                   ListEntry);
                    LocalApcContext = MiniPacket->ApcContext;
                    LocalKeyContext = MiniPacket->KeyContext;
                    LocalIoStatusBlock.Status = MiniPacket->IoStatus;
                    LocalIoStatusBlock.Information = MiniPacket->IoStatusInformation;
                }

                try {

                    //
                    // Deliver the completion to the user buffers before
                    // releasing the packet.  If a write faults, the entry has
                    // not been consumed, so the packet must stay intact for
                    // the exception handler to re-queue it.
                    //

                    *ApcContext = LocalApcContext;
                    *KeyContext = LocalKeyContext;
                    *IoStatusBlock = LocalIoStatusBlock;

                    if (PacketIsIrp) {
                        IoFreeIrp(Irp);
                    } else {
                        ExFreePool(MiniPacket);
                    }

                } except(ExSystemExceptionFilter()) {

                    //
                    // A user-buffer write faulted.  Put the completion
                    // entry back on the queue (its packet is still valid)
                    // and fail the call, rather than silently dropping
                    // the completion and returning STATUS_SUCCESS.
                    //

                    KeInsertQueue((PKQUEUE)IoCompletion, Entry);
                    Status = GetExceptionCode();
                }
            }

            //
            // Deference I/O completion object.
            //

            ObDereferenceObject(IoCompletion);
        }

    //
    // If an exception occurs during the probe of the previous count, then
    // always handle the exception and return the exception code as the status
    // value.
    //

    } except(ExSystemExceptionFilter()) {
        Status = GetExceptionCode();
    }

    //
    // Return service status.
    //

    return Status;
}

VOID
IopDeleteIoCompletion (
    IN PVOID Object
    )

/*++

Routine Description:

    This function is the delete routine for I/O completion objects. Its
    function is to release all the entries in the repsective completion
    queue and to rundown all threads that are current associated.

Arguments:

    Object - Supplies a pointer to an executive I/O completion object.

Return Value:

    None.

--*/

{

    PLIST_ENTRY FirstEntry;
    PIRP Irp;
    PLIST_ENTRY NextEntry;

    //
    // Rundown threads associated with the I/O completion object and get
    // the list of unprocessed I/O completion IRPs.
    //

    FirstEntry = KeRundownQueue((PKQUEUE)Object);
    if (FirstEntry != NULL) {
        NextEntry = FirstEntry;
        do {
            PLIST_ENTRY ThisEntry = NextEntry;

            //
            // Advance before freeing (the free invalidates the entry); free as
            // an IRP or a posted mini-packet depending on the entry's tag.
            //

            NextEntry = NextEntry->Flink;
            if (IopCompletionPacketType(ThisEntry) == IopCompletionPacketIrp) {
                Irp = CONTAINING_RECORD(ThisEntry, IRP, Tail.Overlay.ListEntry);
                IoFreeIrp(Irp);
            } else {
                ExFreePool(CONTAINING_RECORD(ThisEntry,
                                             IOP_MINI_COMPLETION_PACKET,
                                             ListEntry));
            }
        } while (FirstEntry != NextEntry);
    }

    return;
}

NTSTATUS
NtSetIoCompletion (
    IN HANDLE IoCompletionHandle,
    IN PVOID KeyContext,
    IN PVOID ApcContext,
    IN NTSTATUS IoStatus,
    IN ULONG IoStatusInformation
    )

/*++

Routine Description:

    This function posts a completion packet to an I/O completion object.  The
    packet is delivered to a thread waiting in NtRemoveIoCompletion[Ex] exactly
    as a completed IRP would be, except that all of the values are supplied by
    the caller.  This backs the Win32 PostQueuedCompletionStatus API.

Arguments:

    IoCompletionHandle - Supplies a handle to an I/O completion object.

    KeyContext - Supplies the completion key returned to the dequeuer.

    ApcContext - Supplies the (opaque) APC/overlapped context returned to the
        dequeuer.

    IoStatus - Supplies the completion status returned to the dequeuer.

    IoStatusInformation - Supplies the information value returned to the
        dequeuer.

Return Value:

    STATUS_SUCCESS, or an error status from the handle reference / allocation.

--*/

{
    PVOID IoCompletion;
    NTSTATUS Status;
    PIOP_MINI_COMPLETION_PACKET MiniPacket;

    //
    // Every argument is passed by value (the contexts are opaque pointers that
    // are never dereferenced here), so no probing is required.
    //

    Status = ObReferenceObjectByHandle(IoCompletionHandle,
                                       IO_COMPLETION_MODIFY_STATE,
                                       IoCompletionObjectType,
                                       KeGetPreviousMode(),
                                       &IoCompletion,
                                       NULL);
    if (!NT_SUCCESS(Status)) {
        return Status;
    }

    MiniPacket = ExAllocatePoolWithTag(NonPagedPool,
                                       sizeof(IOP_MINI_COMPLETION_PACKET),
                                       'pCoI');
    if (MiniPacket == NULL) {
        ObDereferenceObject(IoCompletion);
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    MiniPacket->PacketType = IopCompletionPacketMini;
    MiniPacket->KeyContext = KeyContext;
    MiniPacket->ApcContext = ApcContext;
    MiniPacket->IoStatus = IoStatus;
    MiniPacket->IoStatusInformation = IoStatusInformation;

    KeInsertQueue((PKQUEUE)IoCompletion, &MiniPacket->ListEntry);

    ObDereferenceObject(IoCompletion);

    return STATUS_SUCCESS;
}

NTSTATUS
NtRemoveIoCompletionEx (
    IN HANDLE IoCompletionHandle,
    OUT PFILE_IO_COMPLETION_INFORMATION IoCompletionInformation,
    IN ULONG Count,
    OUT PULONG NumEntriesRemoved,
    IN PLARGE_INTEGER Timeout OPTIONAL,
    IN BOOLEAN Alertable
    )

/*++

Routine Description:

    This function removes up to Count entries from an I/O completion object,
    blocking (honouring the optional timeout) only until the first entry is
    available and then draining any further ready entries without blocking.
    This backs the Win32 GetQueuedCompletionStatusEx API (the only dequeue
    path mio uses).

Arguments:

    IoCompletionHandle - Supplies a handle to an I/O completion object.

    IoCompletionInformation - Supplies an array that receives the removed
        completion entries.

    Count - Supplies the number of elements in the array.

    NumEntriesRemoved - Receives the number of entries actually removed.

    Timeout - Supplies an optional time out for the wait on the first entry.

    Alertable - Supplies whether the wait is alertable (carried by the wait
        mode below).

Return Value:

    STATUS_SUCCESS if at least one entry was removed; STATUS_TIMEOUT /
    STATUS_USER_APC if the wait for the first entry did not complete; otherwise
    an error status.

--*/

{
    PLARGE_INTEGER CapturedTimeout;
    LARGE_INTEGER TimeoutValue;
    LARGE_INTEGER ZeroTimeout;
    PVOID IoCompletion;
    KPROCESSOR_MODE PreviousMode;
    NTSTATUS Status;
    PLIST_ENTRY Entry;
    PIRP Irp;
    PIOP_MINI_COMPLETION_PACKET MiniPacket;
    ULONG removed;

    UNREFERENCED_PARAMETER( Alertable );

    try {

        CapturedTimeout = NULL;
        PreviousMode = KeGetPreviousMode();

        //
        // Guard the array size against count overflow before probing it.
        //

        if (Count == 0 ||
            Count > MAXULONG / sizeof(FILE_IO_COMPLETION_INFORMATION)) {
            return STATUS_INVALID_PARAMETER;
        }

        if (PreviousMode != KernelMode) {
            ProbeForWrite(IoCompletionInformation,
                          Count * sizeof(FILE_IO_COMPLETION_INFORMATION),
                          sizeof(ULONG));
            ProbeForWrite(NumEntriesRemoved, sizeof(ULONG), sizeof(ULONG));
            if (ARGUMENT_PRESENT(Timeout)) {
                CapturedTimeout = &TimeoutValue;
                TimeoutValue = ProbeAndReadLargeInteger(Timeout);
            }
        } else {
            if (ARGUMENT_PRESENT(Timeout)) {
                CapturedTimeout = Timeout;
            }
        }

        Status = ObReferenceObjectByHandle(IoCompletionHandle,
                                           IO_COMPLETION_MODIFY_STATE,
                                           IoCompletionObjectType,
                                           PreviousMode,
                                           &IoCompletion,
                                           NULL);
        if (!NT_SUCCESS(Status)) {
            return Status;
        }

        ZeroTimeout.QuadPart = 0;
        removed = 0;
        Status = STATUS_SUCCESS;

        while (removed < Count) {

            //
            // Block (with the caller's timeout) only for the first entry; drain
            // further ready entries with a zero timeout.
            //

            Entry = KeRemoveQueue((PKQUEUE)IoCompletion,
                                  PreviousMode,
                                  (removed == 0) ? CapturedTimeout : &ZeroTimeout);

            if (((NTSTATUS)Entry == STATUS_TIMEOUT) ||
                ((NTSTATUS)Entry == STATUS_USER_APC)) {
                if (removed == 0) {
                    Status = (NTSTATUS)Entry;
                }
                break;
            }

            if (IopCompletionPacketType(Entry) == IopCompletionPacketIrp) {
                Irp = CONTAINING_RECORD(Entry, IRP, Tail.Overlay.ListEntry);
                IoCompletionInformation[removed].ApcContext =
                    Irp->Overlay.AsynchronousParameters.UserApcContext;
                IoCompletionInformation[removed].KeyContext =
                    (PVOID)Irp->Tail.CompletionKey;
                IoCompletionInformation[removed].IoStatusBlock = Irp->IoStatus;
                IoFreeIrp(Irp);
            } else {
                MiniPacket = CONTAINING_RECORD(Entry,
                                               IOP_MINI_COMPLETION_PACKET,
                                               ListEntry);
                IoCompletionInformation[removed].ApcContext = MiniPacket->ApcContext;
                IoCompletionInformation[removed].KeyContext = MiniPacket->KeyContext;
                IoCompletionInformation[removed].IoStatusBlock.Status =
                    MiniPacket->IoStatus;
                IoCompletionInformation[removed].IoStatusBlock.Information =
                    MiniPacket->IoStatusInformation;
                ExFreePool(MiniPacket);
            }

            removed += 1;
        }

        *NumEntriesRemoved = removed;

        ObDereferenceObject(IoCompletion);

    } except(ExSystemExceptionFilter()) {
        Status = GetExceptionCode();
    }

    return Status;
}
