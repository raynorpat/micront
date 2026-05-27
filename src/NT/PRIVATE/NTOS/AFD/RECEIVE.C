/*++

Copyright (c) 1989  Microsoft Corporation

Module Name:

    receive.c

Abstract:

    This module contains the code for passing on receive IRPs to
    TDI providers.

Author:

    David Treadwell (davidtr)    13-Mar-1992

Revision History:

--*/

#include "afdp.h"

#ifdef ALLOC_PRAGMA
#pragma alloc_text( PAGEAFD, AfdReceive )
#pragma alloc_text( PAGEAFD, AfdQueryReceiveInformation )
#endif


NTSTATUS
AfdReceive (
    IN PIRP Irp,
    IN PIO_STACK_LOCATION IrpSp
    )

/*++

Routine Description:

    Dispatch a receive IRP to the appropriate handler. Buffering-transport
    support has been stripped — the VC path always lands in AfdBReceive
    (TCP/IP is non-buffering), and datagrams use AfdReceiveDatagram.

Arguments:

    Irp   - the receive IRP.
    IrpSp - the IO stack location.

Return Value:

    NTSTATUS — status of the receive.

--*/

{
    PAFD_ENDPOINT endpoint;
    NTSTATUS status;

    endpoint = IrpSp->FileObject->FsContext;
    ASSERT( IS_AFD_ENDPOINT_TYPE( endpoint ) );

    if ( endpoint->State != AfdEndpointStateConnected ) {
        status = STATUS_INVALID_CONNECTION;
    } else if ( (endpoint->DisconnectMode & AFD_PARTIAL_DISCONNECT_RECEIVE) ) {
        status = STATUS_PIPE_DISCONNECTED;
    } else if ( (endpoint->DisconnectMode & AFD_ABORTIVE_DISCONNECT) ) {
        status = STATUS_LOCAL_DISCONNECT;
    } else if ( endpoint->EndpointType == AfdEndpointTypeDatagram ) {
        return AfdReceiveDatagram( Irp, IrpSp );
    } else {
        return AfdBReceive( Irp, IrpSp );
    }

    Irp->IoStatus.Information = 0;
    Irp->IoStatus.Status = status;
    IoCompleteRequest( Irp, AfdPriorityBoost );
    return status;

} // AfdReceive





NTSTATUS
AfdQueryReceiveInformation (
    IN PIRP Irp,
    IN PIO_STACK_LOCATION IrpSp
    )
{
    PAFD_RECEIVE_INFORMATION receiveInformation;
    PAFD_ENDPOINT endpoint;
    KIRQL oldIrql;
    LARGE_INTEGER result;
    PAFD_CONNECTION connection;

    //
    // Make sure that the output buffer is large enough.
    //

    if ( IrpSp->Parameters.DeviceIoControl.OutputBufferLength <
             sizeof(AFD_RECEIVE_INFORMATION) ) {
        return STATUS_BUFFER_TOO_SMALL;
    }

    //
    // If this endpoint has a connection block, use the connection block's
    // information, else use the information from the endpoint itself.
    //

    endpoint = IrpSp->FileObject->FsContext;
    ASSERT( IS_AFD_ENDPOINT_TYPE( endpoint ) );
    receiveInformation = Irp->AssociatedIrp.SystemBuffer;

    KeAcquireSpinLock( &endpoint->SpinLock, &oldIrql );

    connection = AFD_CONNECTION_FROM_ENDPOINT( endpoint );

    if ( connection != NULL ) {

        ASSERT( endpoint->Type == AfdBlockTypeVcConnecting );
        ASSERT( connection->Type == AfdBlockTypeConnection );

        receiveInformation->BytesAvailable =
            connection->VcBufferredReceiveBytes;
        receiveInformation->ExpeditedBytesAvailable = 0;

    } else {

        //
        // Determine the number of bytes available to be read.
        //

        if ( endpoint->EndpointType == AfdEndpointTypeDatagram ) {

            //
            // Return the amount of bytes of datagrams that are
            // bufferred on the endpoint.
            //

            receiveInformation->BytesAvailable = endpoint->BufferredDatagramBytes;

        } else {

            //
            // This is an unconnected endpoint, hence no bytes are
            // available to be read.
            //

            receiveInformation->BytesAvailable = 0;
        }

        //
        // Whether this is a datagram endpoint or just unconnected,
        // there are no expedited bytes available.
        //

        receiveInformation->ExpeditedBytesAvailable = 0;
    }

    KeReleaseSpinLock( &endpoint->SpinLock, oldIrql );

    Irp->IoStatus.Information = sizeof(AFD_RECEIVE_INFORMATION);

    return STATUS_SUCCESS;

} // AfdQueryReceiveInformation


