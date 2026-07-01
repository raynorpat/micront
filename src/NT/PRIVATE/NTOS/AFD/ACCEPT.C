/*++

Copyright (c) 1989  Microsoft Corporation

Module Name:

    accept.c

Abstract:

    This module contains the handling code for IOCTL_AFD_ACCEPT.

Author:

    David Treadwell (davidtr)    21-Feb-1992

Revision History:

--*/

#include "afdp.h"

extern POBJECT_TYPE *IoFileObjectType;

VOID
AfdDoListenBacklogReplenish (
    IN PVOID Endpoint
    );

VOID
AfdReplenishListenBacklog (
    IN PAFD_ENDPOINT Endpoint
    );

NTSTATUS
AfdRestartSuperAcceptListen (
    IN PDEVICE_OBJECT DeviceObject,
    IN PIRP Irp,
    IN PVOID Context
    );

VOID
AfdSuperAcceptWorker (
    IN PVOID Context
    );

NTSTATUS
AfdSuperAcceptSyncComplete (
    IN PDEVICE_OBJECT DeviceObject,
    IN PIRP Irp,
    IN PVOID Context
    );

#ifdef ALLOC_PRAGMA
#pragma alloc_text( PAGEAFD, AfdAccept )
#pragma alloc_text( PAGEAFD, AfdAcceptCore )
#pragma alloc_text( PAGEAFD, AfdSuperAccept )
#pragma alloc_text( PAGEAFD, AfdSuperAcceptWorker )
#pragma alloc_text( PAGEAFD, AfdDoListenBacklogReplenish )
#pragma alloc_text( PAGEAFD, AfdInitiateListenBacklogReplenish )
#pragma alloc_text( PAGEAFD, AfdReplenishListenBacklog )
#endif


NTSTATUS
AfdAccept (
    IN PIRP Irp,
    IN PIO_STACK_LOCATION IrpSp
    )
{
    NTSTATUS status;
    PAFD_ACCEPT_INFO acceptInfo;
    PAFD_ENDPOINT endpoint;
    PFILE_OBJECT acceptEndpointFileObject;
    PAFD_ENDPOINT acceptEndpoint;
    KIRQL oldIrql;

    //
    // Set up local variables.
    //

    endpoint = IrpSp->FileObject->FsContext;
    ASSERT( endpoint->Type == AfdBlockTypeVcListening );
    acceptInfo = Irp->AssociatedIrp.SystemBuffer;

    Irp->IoStatus.Information = 0;

    //
    // Add another free connection to replace the one we're accepting.
    // Also, add extra to account for past failures in calls to
    // AfdAddFreeConnection().
    //

    ExInterlockedAddUlong(
        &endpoint->Common.VcListening.FailedConnectionAdds,
        1,
        &AfdSpinLock
        );

    AfdReplenishListenBacklog( endpoint );

    //
    // Obtain a pointer to the endpoint on which we're going to
    // accept the connection;
    //

    status = ObReferenceObjectByHandle(
                 acceptInfo->AcceptHandle,
                 0L,                         // DesiredAccess
                 *IoFileObjectType,
                 KernelMode,
                 (PVOID *)&acceptEndpointFileObject,
                 NULL
                 );

    if ( !NT_SUCCESS(status) ) {
        goto complete;
    }

    acceptEndpoint = acceptEndpointFileObject->FsContext;

    //
    // We may have a file object that is not an AFD endpoint.  Make sure
    // that this is an actual AFD endpoint.
    //

    if ( acceptEndpoint->Type != AfdBlockTypeEndpoint ) {
        ObDereferenceObject( acceptEndpointFileObject );
        status = STATUS_INVALID_PARAMETER;
        goto complete;
    }

    IF_DEBUG(ACCEPT) {
        KdPrint(( "AfdAccept: file object %lx, accept endpoint %lx, "
                  "listen endpoint %lx\n",
                      acceptEndpointFileObject, acceptEndpoint, endpoint ));
    }

    //
    // Perform the actual acceptance, wiring the connection onto the
    // accept endpoint.
    //

    status = AfdAcceptCore( endpoint, acceptEndpoint, acceptInfo->Sequence );

    ObDereferenceObject( acceptEndpointFileObject );

complete:

    Irp->IoStatus.Status = status;
    IoAcquireCancelSpinLock( &oldIrql );
    IoSetCancelRoutine( Irp, NULL );
    IoReleaseCancelSpinLock( oldIrql );
    IoCompleteRequest( Irp, AfdPriorityBoost );

    return status;

} // AfdAccept


NTSTATUS
AfdAcceptCore (
    IN PAFD_ENDPOINT ListenEndpoint,
    IN PAFD_ENDPOINT AcceptEndpoint,
    IN ULONG Sequence
    )

/*++

Routine Description:

    Performs the guts of an accept: locates the returned connection for
    the given sequence, wires it onto the accept endpoint, and opens a
    referenced handle to the TDI address object.  Shared by AfdAccept
    and AfdSuperAccept.

Arguments:

    ListenEndpoint - the listening endpoint.

    AcceptEndpoint - the endpoint the connection is to be accepted on.

    Sequence - identifies the returned connection to accept.

Return Value:

    STATUS_SUCCESS or a failure status.

--*/

{
    NTSTATUS status;
    PAFD_CONNECTION connection;

    //
    // Store the local address of the accept endpoint from the listening
    // endpoint.  This keeps the address unusable as long as the accept
    // endpoint is active.
    //

    AcceptEndpoint->LocalAddressLength = ListenEndpoint->LocalAddressLength;

    AcceptEndpoint->LocalAddress =
        AFD_ALLOCATE_POOL(
            NonPagedPool,
            ListenEndpoint->LocalAddressLength
            );

    if ( ListenEndpoint->LocalAddress == NULL ) {
        return STATUS_NO_MEMORY;
    }

    RtlMoveMemory(
        AcceptEndpoint->LocalAddress,
        ListenEndpoint->LocalAddress,
        ListenEndpoint->LocalAddressLength
        );

    //
    // Find the connection on which the accept is being performed.
    //

    connection = AfdGetReturnedConnection( ListenEndpoint, Sequence );

    if ( connection == NULL ) {
        return STATUS_INVALID_PARAMETER;
    }

    ASSERT( connection->Type == AfdBlockTypeConnection );

    //
    // Dereference the endpoint in the connection, if any.
    //

    ASSERT( connection->Endpoint != NULL );
    AfdDereferenceEndpoint( connection->Endpoint );

    //
    // Set up the accept endpoint's type, and remember blocking
    // characteracteristics of the TDI provider.
    //

    AcceptEndpoint->Type = AfdBlockTypeVcConnecting;
    AcceptEndpoint->TdiBufferring = ListenEndpoint->TdiBufferring;

    //
    // Place the connection on the endpoint we'll accept it on.  It is
    // still referenced from when it was created.
    //

    AcceptEndpoint->Common.VcConnecting.Connection = connection;

    //
    // Set up a referenced pointer from the connection to the accept
    // endpoint.
    //

    AfdReferenceEndpoint( AcceptEndpoint, FALSE );
    connection->Endpoint = AcceptEndpoint;

    //
    // Set up a referenced pointer to the listening endpoint.  This is
    // necessary so that the endpoint does not go away until all
    // accepted endpoints have gone away.  Without this, a connect
    // indication could occur on a TDI address object held open
    // by an accepted endpoint after the listening endpoint has
    // been closed and the memory for it deallocated.
    //

    AfdReferenceEndpoint( ListenEndpoint, FALSE );
    AcceptEndpoint->Common.VcConnecting.ListenEndpoint = ListenEndpoint;

    //
    // Set the endpoint to the connected state.
    //

    AcceptEndpoint->State = AfdEndpointStateConnected;

    //
    // Set up a referenced pointer in the accepted endpoint to the
    // TDI address object.
    //

    status = ObReferenceObjectByPointer(
                 ListenEndpoint->AddressFileObject,
                 0L,                         // DesiredAccess
                 *IoFileObjectType,
                 KernelMode
                 );
    ASSERT( NT_SUCCESS(status) );

    AcceptEndpoint->AddressFileObject = ListenEndpoint->AddressFileObject;

    //
    // Get a new handle to the TDI address object on the listening
    // endpoint.  This is necessary so that the TDI address object stays
    // open after the listening endpoint is closed, in order that we
    // continue getting indications on accepted endpoints after the
    // listening endpoint is closed.
    //

    KeAttachProcess( AfdSystemProcess );

    status = ObOpenObjectByPointer(
                 ListenEndpoint->AddressFileObject,
                 OBJ_CASE_INSENSITIVE,
                 NULL,
                 GENERIC_READ | GENERIC_WRITE | SYNCHRONIZE,
                 *IoFileObjectType,
                 KernelMode,
                 &AcceptEndpoint->AddressHandle
                 );
    ASSERT( NT_SUCCESS(status) );

    KeDetachProcess( );

    return STATUS_SUCCESS;

} // AfdAcceptCore


VOID
AfdInitiateListenBacklogReplenish (
    IN PAFD_ENDPOINT Endpoint
    )
{
    PAGED_CODE( );

    //
    // Reference the endpoint so that it won't go away until we're
    // done with it.
    //

    AfdReferenceEndpoint( Endpoint, FALSE );

    //
    // Queue a work item to an executive worker thread.
    //

    AfdQueueWorkItem( AfdDoListenBacklogReplenish, Endpoint );

    return;

} // AfdInitiateListenBacklogReplenish


VOID
AfdDoListenBacklogReplenish (
    IN PVOID Endpoint
    )
{
    PAFD_ENDPOINT endpoint = Endpoint;

    PAGED_CODE( );

    ASSERT( endpoint->Type == AfdBlockTypeVcListening );

    //
    // If the endpoint's state changed, don't replenish the backlog.
    //

    if ( endpoint->State != AfdEndpointStateListening ) {
        AfdDereferenceEndpoint( endpoint );
        return;
    }

    //
    // Fill up the free connection backlog.
    //

    AfdReplenishListenBacklog( endpoint );

    //
    // Clean up and return.
    //

    AfdDereferenceEndpoint( endpoint );

    return;

} // AfdDoListenBacklogReplenish


VOID
AfdReplenishListenBacklog (
    IN PAFD_ENDPOINT Endpoint
    )
{
    KIRQL oldIrql;
    NTSTATUS status;

    ASSERT( Endpoint->Type == AfdBlockTypeVcListening );

    KeAcquireSpinLock( &AfdSpinLock, &oldIrql );

    status = STATUS_SUCCESS;

    //
    // Continue opening new free conections until we've hit the
    // backlog or a connection open fails.
    //

    while ( Endpoint->Common.VcListening.FailedConnectionAdds > 0 && NT_SUCCESS(status) ) {

        Endpoint->Common.VcListening.FailedConnectionAdds--;
        KeReleaseSpinLock( &AfdSpinLock, oldIrql );

        status = AfdAddFreeConnection( Endpoint );

        KeAcquireSpinLock( &AfdSpinLock, &oldIrql );

        if ( !NT_SUCCESS(status) ) {
            Endpoint->Common.VcListening.FailedConnectionAdds++;
            IF_DEBUG(ACCEPT) {
                KdPrint(( "AfdReplenishListenBacklog: AfdAddFreeConnection failed: %X, "
                          "fail count = %ld\n", status,
                              Endpoint->Common.VcListening.FailedConnectionAdds ));
            }
        }
    }

    KeReleaseSpinLock( &AfdSpinLock, oldIrql );

    return;

} // AfdReplenishListenBacklog


NTSTATUS
AfdSuperAccept (
    IN PIRP Irp,
    IN PIO_STACK_LOCATION IrpSp
    )

/*++

Routine Description:

    Entrypoint for IOCTL_AFD_SUPER_ACCEPT, which backs the Win32 AcceptEx
    API.  A super accept combines waiting for an incoming connection,
    accepting it, retrieving the local and remote addresses, and receiving
    the first block of data on the connection into a single overlapped
    request.

    This routine validates parameters and initiates the wait for a
    connection using the same IRP.  Processing continues in the completion
    routine AfdRestartSuperAcceptListen.

Arguments:

    Irp - the super accept IRP.  Uses METHOD_OUT_DIRECT, so the caller's
        output buffer is described by Irp->MdlAddress.

    IrpSp - our stack location for this IRP.

Return Value:

    STATUS_PENDING if the request was initiated, or a failure status.

--*/

{
    PAFD_ENDPOINT listenEndpoint;
    PAFD_ENDPOINT acceptEndpoint;
    PFILE_OBJECT acceptFileObject;
    PAFD_SUPER_ACCEPT_INFO superAcceptInfo;
    NTSTATUS status;
    PIO_STACK_LOCATION nextIrpSp;

    PAGED_CODE( );

    listenEndpoint = IrpSp->FileObject->FsContext;
    superAcceptInfo = Irp->AssociatedIrp.SystemBuffer;

    //
    // Validate the input and output buffers.  The input buffer must hold
    // the super accept info plus enough extra to hold the local address
    // captured by the wait for listen.  The output buffer must be large
    // enough for the requested receive data plus both addresses.
    //

    if ( listenEndpoint->Type != AfdBlockTypeVcListening

             ||

         IrpSp->Parameters.DeviceIoControl.InputBufferLength <
             sizeof(AFD_SUPER_ACCEPT_INFO)

             ||

         IrpSp->Parameters.DeviceIoControl.InputBufferLength <
             sizeof(AFD_SUPER_ACCEPT_INFO) + superAcceptInfo->LocalAddressLength

             ||

         Irp->MdlAddress == NULL

             ||

         IrpSp->Parameters.DeviceIoControl.OutputBufferLength <
             superAcceptInfo->ReceiveDataLength +
             superAcceptInfo->LocalAddressLength +
             superAcceptInfo->RemoteAddressLength ) {

        superAcceptInfo = NULL;
        status = STATUS_INVALID_PARAMETER;
        goto complete;
    }

    //
    // Obtain a pointer to the endpoint on which we're going to accept the
    // connection.
    //

    status = ObReferenceObjectByHandle(
                 superAcceptInfo->AcceptHandle,
                 0L,                         // DesiredAccess
                 *IoFileObjectType,
                 KernelMode,
                 (PVOID *)&acceptFileObject,
                 NULL
                 );

    if ( !NT_SUCCESS(status) ) {
        superAcceptInfo = NULL;
        goto complete;
    }

    superAcceptInfo->AcceptFileObject = acceptFileObject;
    acceptEndpoint = acceptFileObject->FsContext;
    superAcceptInfo->AcceptEndpoint = acceptEndpoint;

    //
    // Make sure this is an actual, unconnected AFD endpoint.
    //

    if ( acceptEndpoint->Type != AfdBlockTypeEndpoint ) {
        status = STATUS_INVALID_PARAMETER;
        goto complete;
    }

    //
    // Add another free connection to replace the one we're accepting.
    //

    ExInterlockedAddUlong(
        &listenEndpoint->Common.VcListening.FailedConnectionAdds,
        1,
        &AfdSpinLock
        );

    AfdReplenishListenBacklog( listenEndpoint );

    //
    // Build a wait for listen request using the current IRP and its next
    // stack location.  The sequence number and remote address are written
    // into the ListenResponseInfo field of the super accept info.
    //

    nextIrpSp = IoGetNextIrpStackLocation( Irp );

    Irp->AssociatedIrp.SystemBuffer = &superAcceptInfo->ListenResponseInfo;
    nextIrpSp->FileObject = IrpSp->FileObject;
    nextIrpSp->DeviceObject = IoGetRelatedDeviceObject( IrpSp->FileObject );
    nextIrpSp->MajorFunction = IRP_MJ_DEVICE_CONTROL;
    nextIrpSp->Parameters.DeviceIoControl.OutputBufferLength =
        sizeof(AFD_LISTEN_RESPONSE_INFO) + superAcceptInfo->RemoteAddressLength;
    nextIrpSp->Parameters.DeviceIoControl.InputBufferLength = 0;
    nextIrpSp->Parameters.DeviceIoControl.IoControlCode = IOCTL_AFD_WAIT_FOR_LISTEN;

    IoSetCompletionRoutine(
        Irp,
        AfdRestartSuperAcceptListen,
        superAcceptInfo,
        TRUE,
        TRUE,
        TRUE
        );

    //
    // Perform the listen wait.  Processing continues in the completion
    // routine.
    //

    IoCallDriver( IrpSp->DeviceObject, Irp );

    return STATUS_PENDING;

complete:

    if ( superAcceptInfo != NULL ) {
        ObDereferenceObject( superAcceptInfo->AcceptFileObject );
    }

    Irp->IoStatus.Information = 0;
    Irp->IoStatus.Status = status;
    IoCompleteRequest( Irp, 0 );

    return status;

} // AfdSuperAccept


NTSTATUS
AfdRestartSuperAcceptListen (
    IN PDEVICE_OBJECT DeviceObject,
    IN PIRP Irp,
    IN PVOID Context
    )

/*++

Routine Description:

    Completion routine for the wait for listen portion of a super accept.
    This can run at DISPATCH_LEVEL, so it defers the remaining work (which
    must open a handle to the TDI address object at PASSIVE_LEVEL) to a
    worker thread.

Arguments:

    DeviceObject - the device object on which the request completed.

    Irp - the super accept IRP.

    Context - points to the super accept request information.

Return Value:

    The completion status if the wait failed, or
    STATUS_MORE_PROCESSING_REQUIRED to keep the IRP alive for the worker.

--*/

{
    PAFD_ENDPOINT listenEndpoint;
    PAFD_SUPER_ACCEPT_INFO superAcceptInfo;
    PIO_STACK_LOCATION irpSp;
    KIRQL oldIrql;

    superAcceptInfo = Context;
    irpSp = IoGetCurrentIrpStackLocation( Irp );
    listenEndpoint = irpSp->FileObject->FsContext;

    if ( Irp->PendingReturned ) {
        IoMarkIrpPending( Irp );
    }

    //
    // Restore the system buffer pointer we clobbered for the wait.
    //

    ASSERT( Irp->AssociatedIrp.SystemBuffer == &superAcceptInfo->ListenResponseInfo );
    Irp->AssociatedIrp.SystemBuffer = superAcceptInfo;

    //
    // If the wait failed, clean up and let the IRP complete normally.
    //

    if ( !NT_SUCCESS(Irp->IoStatus.Status) ) {

        ObDereferenceObject( superAcceptInfo->AcceptFileObject );

        KeAcquireSpinLock( &AfdSpinLock, &oldIrql );
        listenEndpoint->Common.VcListening.FailedConnectionAdds--;
        KeReleaseSpinLock( &AfdSpinLock, oldIrql );

        return Irp->IoStatus.Status;
    }

    //
    // Queue the rest of the work to a worker thread running at
    // PASSIVE_LEVEL, then keep this IRP alive.
    //

    AfdQueueWorkItem( AfdSuperAcceptWorker, Irp );

    return STATUS_MORE_PROCESSING_REQUIRED;

} // AfdRestartSuperAcceptListen


VOID
AfdSuperAcceptWorker (
    IN PVOID Context
    )

/*++

Routine Description:

    Runs at PASSIVE_LEVEL to finish a super accept: performs the actual
    connection acceptance, copies the local and remote addresses into the
    caller's output buffer, optionally receives the first block of data,
    and completes the IRP.

    The local address is obtained with a TDI query on the connection, so it
    reflects the connection's actual local address (matching a getsockname
    on the accepted socket) even for wildcard binds.

Arguments:

    Context - the super accept IRP.

Return Value:

    None.

--*/

{
    PIRP Irp = Context;
    PAFD_SUPER_ACCEPT_INFO superAcceptInfo;
    PAFD_ENDPOINT listenEndpoint;
    PAFD_ENDPOINT acceptEndpoint;
    PFILE_OBJECT acceptFileObject;
    PIO_STACK_LOCATION irpSp;
    NTSTATUS status;
    PUCHAR outputBuffer;
    PAFD_CONNECTION connection;
    ULONG bytesReceived;

    PAGED_CODE( );

    superAcceptInfo = Irp->AssociatedIrp.SystemBuffer;
    irpSp = IoGetCurrentIrpStackLocation( Irp );
    listenEndpoint = irpSp->FileObject->FsContext;
    acceptEndpoint = superAcceptInfo->AcceptEndpoint;
    acceptFileObject = superAcceptInfo->AcceptFileObject;
    bytesReceived = 0;

    //
    // Perform the actual acceptance, wiring the connection onto the accept
    // endpoint.
    //

    status = AfdAcceptCore(
                 listenEndpoint,
                 acceptEndpoint,
                 superAcceptInfo->ListenResponseInfo.Sequence
                 );

    if ( !NT_SUCCESS(status) ) {
        goto complete;
    }

    //
    // Get a system-space pointer to the caller's output buffer.
    //

    outputBuffer = MmGetSystemAddressForMdl( Irp->MdlAddress );

    //
    // Query the connection's actual local address directly into the local
    // address section of the output buffer.  TDI returns a TDI_ADDRESS_INFO
    // (a ULONG activity count followed by the transport address), which is
    // exactly the layout GetAcceptExSockaddrs expects.
    //

    connection = AFD_CONNECTION_FROM_ENDPOINT( acceptEndpoint );

    if ( connection != NULL && superAcceptInfo->LocalAddressLength > 0 ) {

        PVOID localAddressVa;
        PMDL localMdl;
        PIRP queryIrp;
        KEVENT queryEvent;

        localAddressVa = (PCHAR)MmGetMdlVirtualAddress( Irp->MdlAddress ) +
                             superAcceptInfo->ReceiveDataLength;

        localMdl = IoAllocateMdl(
                       localAddressVa,
                       superAcceptInfo->LocalAddressLength,
                       FALSE,
                       FALSE,
                       NULL
                       );

        if ( localMdl != NULL ) {

            IoBuildPartialMdl(
                Irp->MdlAddress,
                localMdl,
                localAddressVa,
                superAcceptInfo->LocalAddressLength
                );

            queryIrp = IoAllocateIrp( connection->FileObject->DeviceObject->StackSize, FALSE );

            if ( queryIrp != NULL ) {

                KeInitializeEvent( &queryEvent, NotificationEvent, FALSE );

                queryIrp->MdlAddress = localMdl;
                queryIrp->Tail.Overlay.Thread = PsGetCurrentThread( );

                TdiBuildQueryInformation(
                    queryIrp,
                    connection->FileObject->DeviceObject,
                    connection->FileObject,
                    AfdSuperAcceptSyncComplete,
                    &queryEvent,
                    TDI_QUERY_ADDRESS_INFO,
                    localMdl
                    );

                status = IoCallDriver( connection->FileObject->DeviceObject, queryIrp );

                if ( status == STATUS_PENDING ) {
                    KeWaitForSingleObject(
                        &queryEvent,
                        Executive,
                        KernelMode,
                        FALSE,
                        NULL
                        );
                }

                IoFreeIrp( queryIrp );
            }

            IoFreeMdl( localMdl );
        }
    }

    //
    // The address query is best-effort; the connection is already
    // established, so the accept itself succeeds regardless.
    //

    status = STATUS_SUCCESS;

    //
    // Store the remote address, captured by the wait for listen.
    //

    if ( superAcceptInfo->RemoteAddressLength > 0 ) {
        RtlCopyMemory(
            outputBuffer + superAcceptInfo->ReceiveDataLength +
                superAcceptInfo->LocalAddressLength,
            &superAcceptInfo->ListenResponseInfo.RemoteAddress,
            superAcceptInfo->RemoteAddressLength
            );
    }

    //
    // If requested, receive the first block of data on the connection.  We
    // synthesize an IRP_MJ_READ to the accept endpoint, describing just the
    // receive-data portion of the output buffer, and wait for it.
    //

    if ( superAcceptInfo->ReceiveDataLength > 0 ) {

        PDEVICE_OBJECT acceptDeviceObject;
        PMDL partialMdl;
        PIRP readIrp;
        PIO_STACK_LOCATION readIrpSp;
        KEVENT event;

        acceptDeviceObject = IoGetRelatedDeviceObject( acceptFileObject );

        partialMdl = IoAllocateMdl(
                         MmGetMdlVirtualAddress( Irp->MdlAddress ),
                         superAcceptInfo->ReceiveDataLength,
                         FALSE,
                         FALSE,
                         NULL
                         );

        if ( partialMdl != NULL ) {

            IoBuildPartialMdl(
                Irp->MdlAddress,
                partialMdl,
                MmGetMdlVirtualAddress( Irp->MdlAddress ),
                superAcceptInfo->ReceiveDataLength
                );

            readIrp = IoAllocateIrp( acceptDeviceObject->StackSize, FALSE );

            if ( readIrp != NULL ) {

                KeInitializeEvent( &event, NotificationEvent, FALSE );

                readIrp->MdlAddress = partialMdl;
                readIrp->Tail.Overlay.Thread = PsGetCurrentThread( );

                readIrpSp = IoGetNextIrpStackLocation( readIrp );
                readIrpSp->MajorFunction = IRP_MJ_READ;
                readIrpSp->FileObject = acceptFileObject;
                readIrpSp->DeviceObject = acceptDeviceObject;
                readIrpSp->Parameters.Read.Length = superAcceptInfo->ReceiveDataLength;
                readIrpSp->Parameters.Read.Key = 0;
                readIrpSp->Parameters.Read.ByteOffset.QuadPart = 0;

                IoSetCompletionRoutine(
                    readIrp,
                    AfdSuperAcceptSyncComplete,
                    &event,
                    TRUE,
                    TRUE,
                    TRUE
                    );

                status = IoCallDriver( acceptDeviceObject, readIrp );

                if ( status == STATUS_PENDING ) {
                    KeWaitForSingleObject(
                        &event,
                        Executive,
                        KernelMode,
                        FALSE,
                        NULL
                        );
                }

                bytesReceived = (ULONG)readIrp->IoStatus.Information;

                IoFreeIrp( readIrp );
            }

            IoFreeMdl( partialMdl );
        }

        //
        // A failure to receive the first data does not fail the accept;
        // the connection has already been established.
        //

        status = STATUS_SUCCESS;
    }

complete:

    ObDereferenceObject( acceptFileObject );

    if ( NT_SUCCESS(status) ) {
        Irp->IoStatus.Information =
            bytesReceived +
            superAcceptInfo->LocalAddressLength +
            superAcceptInfo->RemoteAddressLength;
    } else {
        Irp->IoStatus.Information = 0;
    }

    Irp->IoStatus.Status = status;
    IoCompleteRequest( Irp, AfdPriorityBoost );

    return;

} // AfdSuperAcceptWorker


NTSTATUS
AfdSuperAcceptSyncComplete (
    IN PDEVICE_OBJECT DeviceObject,
    IN PIRP Irp,
    IN PVOID Context
    )

/*++

Routine Description:

    Completion routine for the synchronous first-data receive issued by
    AfdSuperAcceptWorker.  Signals the event the worker is waiting on and
    stops completion processing so the worker can free the IRP.

--*/

{
    KeSetEvent( (PKEVENT)Context, AfdPriorityBoost, FALSE );
    return STATUS_MORE_PROCESSING_REQUIRED;

} // AfdSuperAcceptSyncComplete
