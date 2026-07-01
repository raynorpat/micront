/*++

Copyright (c) 1996 Microsoft Corporation

Module Name:

    acceptex.c

Abstract:

    This module implements the AcceptEx() and GetAcceptExSockaddrs()
    Windows Sockets extension APIs.  These were added in Windows NT 3.51
    Service Pack 5.

    AcceptEx() asynchronously accepts a connection, retrieves the local
    and remote addresses, and receives the first block of data, all in a
    single overlapped call.  It is backed by the IOCTL_AFD_SUPER_ACCEPT
    AFD device control.

    GetAcceptExSockaddrs() parses the addresses out of the buffer that
    AcceptEx() fills.

--*/

#include "winsockp.h"


BOOL PASCAL FAR
AcceptEx(
    IN SOCKET sListenSocket,
    IN SOCKET sAcceptSocket,
    IN PVOID lpOutputBuffer,
    IN DWORD dwReceiveDataLength,
    IN DWORD dwLocalAddressLength,
    IN DWORD dwRemoteAddressLength,
    OUT LPDWORD lpdwBytesReceived,
    IN LPOVERLAPPED lpOverlapped
    )

/*++

Routine Description:

    Accepts a new connection on a pre-created, unbound accept socket,
    optionally receiving the first block of data and always returning the
    local and remote addresses in lpOutputBuffer.  This is an overlapped
    operation.

Arguments:

    sListenSocket - a listening socket.

    sAcceptSocket - a pre-created socket that has not been bound or
        connected.  The new connection is accepted onto this socket.

    lpOutputBuffer - a buffer that receives the first block of data, the
        local address, and the remote address.  Parse it with
        GetAcceptExSockaddrs().

    dwReceiveDataLength - the number of bytes of lpOutputBuffer to use for
        received data.  May be zero to complete as soon as a connection
        arrives.

    dwLocalAddressLength - bytes reserved for the local address; must be at
        least 16 more than the protocol's sockaddr.

    dwRemoteAddressLength - bytes reserved for the remote address; must be
        at least 16 more than the protocol's sockaddr, and cannot be zero.

    lpdwBytesReceived - on synchronous completion, receives the count of
        data bytes read.

    lpOverlapped - required; this is an overlapped operation.

Return Value:

    TRUE if the operation completed synchronously.  FALSE otherwise, with
    the error available from WSAGetLastError() (ERROR_IO_PENDING if the
    operation was successfully initiated but is not yet complete).

--*/

{
    NTSTATUS status;
    PSOCKET_INFORMATION listenSocketInfo;
    PAFD_SUPER_ACCEPT_INFO superAcceptInfo;
    ULONG superAcceptInfoLength;
    HANDLE event;
    PIO_STATUS_BLOCK ioStatusBlock;
    ULONG error;

    WS_ENTER( "AcceptEx", (PVOID)sListenSocket, (PVOID)sAcceptSocket,
                  lpOutputBuffer, lpOverlapped );

    if ( !SockEnterApi( TRUE, FALSE, FALSE ) ) {
        WS_EXIT( "AcceptEx", FALSE, TRUE );
        return FALSE;
    }

    error = NO_ERROR;
    listenSocketInfo = NULL;
    superAcceptInfo = NULL;

    //
    // This is an overlapped call and the remote address is mandatory.
    //

    if ( !ARGUMENT_PRESENT( lpOverlapped ) || dwRemoteAddressLength == 0 ) {
        error = WSAEINVAL;
        goto exit;
    }

    //
    // Reference the listening socket and make sure it is listening.
    //

    listenSocketInfo = SockFindAndReferenceSocket( sListenSocket, TRUE );
    if ( listenSocketInfo == NULL ) {
        error = WSAENOTSOCK;
        goto exit;
    }

    if ( listenSocketInfo->State != SocketStateListening ) {
        error = WSAEINVAL;
        goto exit;
    }

    //
    // Allocate the input structure.  Extra room is left after the fixed
    // structure to hold the addresses captured by the wait for listen
    // performed inside AFD.
    //

    superAcceptInfoLength = sizeof(AFD_SUPER_ACCEPT_INFO) +
                                dwLocalAddressLength + dwRemoteAddressLength;

    superAcceptInfo = ALLOCATE_HEAP( superAcceptInfoLength );
    if ( superAcceptInfo == NULL ) {
        error = WSAENOBUFS;
        goto exit;
    }

    superAcceptInfo->AcceptHandle = (HANDLE)sAcceptSocket;
    superAcceptInfo->AcceptEndpoint = NULL;
    superAcceptInfo->AcceptFileObject = NULL;
    superAcceptInfo->ReceiveDataLength = dwReceiveDataLength;
    superAcceptInfo->LocalAddressLength = dwLocalAddressLength;
    superAcceptInfo->RemoteAddressLength = dwRemoteAddressLength;

    //
    // Set up overlapped completion.  AFD uses the OVERLAPPED structure's
    // Internal field as the I/O status block and signals hEvent (or queues
    // to a completion port) when the operation finishes.  Following the
    // usual Win32 convention, a low bit set in hEvent suppresses the
    // completion port notification.
    //

    event = lpOverlapped->hEvent;
    lpOverlapped->Internal = (DWORD)STATUS_PENDING;
    ioStatusBlock = (PIO_STATUS_BLOCK)&lpOverlapped->Internal;

    status = NtDeviceIoControlFile(
                 (HANDLE)listenSocketInfo->Handle,
                 event,
                 NULL,                                       // APC routine
                 (DWORD)event & 1 ? NULL : lpOverlapped,     // APC/IOCP context
                 ioStatusBlock,
                 IOCTL_AFD_SUPER_ACCEPT,
                 superAcceptInfo,
                 superAcceptInfoLength,
                 lpOutputBuffer,
                 dwReceiveDataLength + dwLocalAddressLength + dwRemoteAddressLength
                 );

    //
    // The input buffer has been captured by the I/O system, so it can be
    // freed now regardless of whether the operation is still pending.
    //

    FREE_HEAP( superAcceptInfo );
    superAcceptInfo = NULL;

    SockDereferenceSocket( listenSocketInfo );
    listenSocketInfo = NULL;

    if ( status == STATUS_PENDING ) {
        SetLastError( ERROR_IO_PENDING );
        WS_EXIT( "AcceptEx", FALSE, TRUE );
        return FALSE;
    }

    if ( !NT_SUCCESS(status) ) {
        SetLastError( SockNtStatusToSocketError( status ) );
        WS_EXIT( "AcceptEx", FALSE, TRUE );
        return FALSE;
    }

    if ( ARGUMENT_PRESENT( lpdwBytesReceived ) ) {
        *lpdwBytesReceived = (DWORD)ioStatusBlock->Information;
    }

    WS_EXIT( "AcceptEx", TRUE, FALSE );
    return TRUE;

exit:

    if ( superAcceptInfo != NULL ) {
        FREE_HEAP( superAcceptInfo );
    }

    if ( listenSocketInfo != NULL ) {
        SockDereferenceSocket( listenSocketInfo );
    }

    SetLastError( error );
    WS_EXIT( "AcceptEx", FALSE, TRUE );
    return FALSE;

} // AcceptEx


VOID PASCAL FAR
GetAcceptExSockaddrs(
    IN PVOID lpOutputBuffer,
    IN DWORD dwReceiveDataLength,
    IN DWORD dwLocalAddressLength,
    IN DWORD dwRemoteAddressLength,
    OUT struct sockaddr **LocalSockaddr,
    OUT LPINT LocalSockaddrLength,
    OUT struct sockaddr **RemoteSockaddr,
    OUT LPINT RemoteSockaddrLength
    )

/*++

Routine Description:

    Processes the lpOutputBuffer parameter after a successful AcceptEx()
    operation.  Because AcceptEx() writes address information in an
    internal (TDI) format, this routine is required to locate the SOCKADDR
    structures in the buffer.

Arguments:

    lpOutputBuffer, dwReceiveDataLength, dwLocalAddressLength,
    dwRemoteAddressLength - the same values passed to AcceptEx().

    LocalSockaddr / LocalSockaddrLength - receive a pointer to, and the
        length of, the connection's local address.

    RemoteSockaddr / RemoteSockaddrLength - receive a pointer to, and the
        length of, the connection's remote address.

Return Value:

    None.

--*/

{
    PTRANSPORT_ADDRESS tdiAddress;

    //
    // Locate the local address.  There is one ULONG between the start of
    // the local address section of the buffer and the actual TDI address.
    //

    tdiAddress = (PTRANSPORT_ADDRESS)
        ( (PCHAR)lpOutputBuffer + dwReceiveDataLength + sizeof(ULONG) );

    *LocalSockaddrLength =
        tdiAddress->Address[0].AddressLength +
        sizeof((*LocalSockaddr)->sa_family);

    *LocalSockaddr = (struct sockaddr *)(&tdiAddress->Address[0].AddressType);

    //
    // Repeat for the remote address, which begins at the local address
    // section's end.
    //

    tdiAddress = (PTRANSPORT_ADDRESS)
        ( (PCHAR)lpOutputBuffer + dwReceiveDataLength + dwLocalAddressLength );

    *RemoteSockaddrLength =
        tdiAddress->Address[0].AddressLength +
        sizeof((*RemoteSockaddr)->sa_family);

    *RemoteSockaddr = (struct sockaddr *)(&tdiAddress->Address[0].AddressType);

    return;

} // GetAcceptExSockaddrs
