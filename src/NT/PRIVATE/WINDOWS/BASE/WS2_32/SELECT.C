/*++

Copyright (c) 1992 Microsoft Corporation

Module Name:

    Select.c

Abstract:

    This module contains support for the select( ) and WSASelectWindow
    WinSock APIs.

Author:

    David Treadwell (davidtr)    4-Apr-1992

Revision History:

--*/

//
// FD_SET uses the FD_SETSIZE macro, so define it to a huge value here so
// that apps can pass a very large number of sockets to select(), which
// uses the FD_SET macro.
//

#define FD_SETSIZE 65536

#include "winsockp.h"

#define HANDLES_IN_SET(set) ( (set) == NULL ? 0 : (set->fd_count & 0xFFFF) )
#define IS_EVENT_ENABLED(event, socket)                     \
            ( (socket->DisabledAsyncSelectEvents & event) == 0 && \
              (socket->AsyncSelectlEvent & event) != 0 )

typedef struct _POLL_CONTEXT_BLOCK {
    SOCKET SocketHandle;
    DWORD SocketSerialNumber;
    DWORD AsyncSelectSerialNumber;
    IO_STATUS_BLOCK IoStatus;
    AFD_POLL_INFO PollInfo;
} POLL_CONTEXT_BLOCK, *PPOLL_CONTEXT_BLOCK;

/* AsyncSelectCompletionApc removed: WSAAsyncSelect is not supported (headless). */


int PASCAL
select (
    int nfds,
    fd_set *readfds,
    fd_set *writefds,
    fd_set *exceptfds,
    const struct timeval *timeout
    )

/*++

Routine Description:

    This function is used to determine the status of one or more
    sockets.  For each socket, the caller may request information on
    read, write or error status.  The set of sockets for which a given
    status is requested is indicated by an fd_set structure.  Upon
    return, the structure is updated to reflect the subset of these
    sockets which meet the specified condition, and select() returns the
    number of sockets meeting the conditions.  A set of macros is
    provided for manipulating an fd_set.  These macros are compatible
    with those used in the Berkeley software, but the underlying
    representation is completely different.

    The parameter readfds identifies those sockets which are to be
    checked for readability.  If the socket is currently listen()ing, it
    will be marked as readable if an incoming connection request has
    been received, so that an accept() is guaranteed to complete without
    blocking.  For other sockets, readability means that queued data is
    available for reading, so that a recv() or recvfrom() is guaranteed
    to complete without blocking.  The presence of out-of-band data will
    be checked if the socket option SO_OOBINLINE has been enabled (see
    setsockopt()).

    The parameter writefds identifies those sockets which are to be
    checked for writeability.  If a socket is connect()ing
    (non-blocking), writeability means that the connection establishment
    is complete.  For other sockets, writeability means that a send() or
    sendto() will complete without blocking.  [It is not specified how
    long this guarantee can be assumed to be valid, particularly in a
    multithreaded environment.]

    The parameter exceptfds identifies those sockets which are to be
    checked for the presence of out- of-band data or any exceptional
    error conditions.  Note that out-of-band data will only be reported
    in this way if the option SO_OOBINLINE is FALSE.  For a SOCK_STREAM,
    the breaking of the connection by the peer or due to KEEPALIVE
    failure will be indicated as an exception.  This specification does
    not define which other errors will be included.

    Any of readfds, writefds, or exceptfds may be given as NULL if no
    descriptors are of interest.

    Four macros are defined in the header file winsock.h for
    manipulating the descriptor sets.  The variable FD_SETSIZE
    determines the maximum number of descriptors in a set.  (The default
    value of FD_SETSIZE is 64, which may be modified by #defining
    FD_SETSIZE to another value before #including winsock.h.)
    Internally, an fd_set is represented as an array of SOCKETs; the
    last valid entry is followed by an element set to INVALID_SOCKET.
    The macros are:

    FD_CLR(s, *set)     Removes the descriptor s from set.
    FD_ISSET(s, *set)   Nonzero if s is a member of the set, zero otherwise.
    FD_SET(s, *set)     Adds descriptor s to set.
    FD_ZERO(*set)       Initializes the set to the NULL set.

    The parameter timeout controls how long the select() may take to
    complete.  If timeout is a null pointer, select() will block
    indefinitely until at least one descriptor meets the specified
    criteria.  Otherwise, timeout points to a struct timeval which
    specifies the maximum time that select() should wait before
    returning.  If the timeval is initialized to {0, 0}, select() will
    return immediately; this is used to "poll" the state of the selected
    sockets.

Arguments:

    nfds - This argument is ignored and included only for the sake of
        compatibility.

    readfds - A set of sockets to be checked for readability.

    writefds - A set of sockets to be checked for writeability

    exceptfds -  set of sockets to be checked for errors.

    timeout   The maximum time for select() to wait, or NULL for blocking
        operation.

Return Value:

    select() returns the total number of descriptors which are ready and
    contained in the fd_set structures, or 0 if the time limit expired.

--*/

{
    NTSTATUS status;
    ULONG error;
    PAFD_POLL_INFO pollInfo;
    ULONG pollBufferSize;
    PAFD_POLL_HANDLE_INFO pollHandleInfo;
    ULONG handleCount;
    ULONG i;
    HANDLE eventHandle;
    IO_STATUS_BLOCK ioStatusBlock;
    ULONG handlesReady;

    WS_ENTER( "select", readfds, writefds, exceptfds, (PVOID)timeout );

    if ( !SockEnterApi( TRUE, TRUE, FALSE ) ) {
        WS_EXIT( "select", SOCKET_ERROR, TRUE );
        return SOCKET_ERROR;
    }

    //
    // Set up locals so that we know how to clean up on exit.
    //

    error = NO_ERROR;
    pollInfo = NULL;
    eventHandle = NULL;
    handlesReady = 0;

    //
    // Determine how many handles we're going to check so that we can
    // allocate a buffer large enough to hold information about all of
    // them.
    //

    handleCount = HANDLES_IN_SET( readfds ) +
                  HANDLES_IN_SET( writefds ) +
                  HANDLES_IN_SET( exceptfds );

    //
    // If there are no handles specified, just return.
    //

    if ( handleCount == 0 ) {
        WS_EXIT( "select", 0, FALSE );
        return 0;
    }

    //
    // Allocate space to hold the input buffer for the poll IOCTL.
    //

    pollBufferSize = sizeof(AFD_POLL_INFO) +
                         handleCount * sizeof(AFD_POLL_HANDLE_INFO);

    pollInfo = ALLOCATE_HEAP( pollBufferSize );

    if ( pollInfo == NULL ) {
        error = WSAENOBUFS;
        goto exit;
    }

    //
    // Initialize the poll buffer.
    //

    pollInfo->NumberOfHandles = handleCount;
    pollInfo->Unique = FALSE;

    pollHandleInfo = pollInfo->Handles;

    for ( i = 0; readfds != NULL && i < (readfds->fd_count & 0xFFFF); i++ ) {

        //
        // If the connection is disconnected, either abortively or
        // orderly, then it is considered possible to read immediately
        // on the socket, so include these events in addition to receive.
        //

        pollHandleInfo->Handle = (HANDLE)readfds->fd_array[i];
        pollHandleInfo->PollEvents =
            AFD_POLL_RECEIVE | AFD_POLL_DISCONNECT | AFD_POLL_ABORT;
        pollHandleInfo++;
    }

    for ( i = 0; writefds != NULL && i < (writefds->fd_count & 0xFFFF); i++ ) {
        pollHandleInfo->Handle = (HANDLE)writefds->fd_array[i];
        pollHandleInfo->PollEvents = AFD_POLL_SEND;
        pollHandleInfo++;
    }

    for ( i = 0; exceptfds != NULL && i < (exceptfds->fd_count & 0xFFFF); i++ ) {
        pollHandleInfo->Handle = (HANDLE)exceptfds->fd_array[i];
        pollHandleInfo->PollEvents =
            AFD_POLL_RECEIVE_EXPEDITED | AFD_POLL_CONNECT_FAIL;
        pollHandleInfo++;
    }

    //
    // If a timeout was specified, convert it to NT format.  Since it is
    // a relative time, it must be negative.
    //

    if ( timeout != NULL ) {

        LARGE_INTEGER microseconds;

        pollInfo->Timeout = RtlEnlargedIntegerMultiply(
                                timeout->tv_sec,
                                -10*1000*1000
                                );

        microseconds = RtlEnlargedIntegerMultiply( timeout->tv_usec, -10 );

        pollInfo->Timeout = RtlLargeIntegerAdd(
                                pollInfo->Timeout,
                                microseconds
                                );

    } else {

        //
        // No timeout was specified, just set the timeout value
        // to the largest possible value, in effect using an infinite
        // timeout.
        //

        pollInfo->Timeout.LowPart = 0xFFFFFFFF;
        pollInfo->Timeout.HighPart = 0x7FFFFFFF;
    }

    //
    // Create an event to wait on.  Creating an event costs a little
    // here, but this is easier and cleaner than using an event
    // from one of the sockets.
    //

    status = NtCreateEvent(
                 &eventHandle,
                 EVENT_ALL_ACCESS,
                 NULL,
                 SynchronizationEvent,
                 FALSE
                 );
    if ( !NT_SUCCESS(status) ) {
        error = SockNtStatusToSocketError( status );
        goto exit;
    }

    //
    // Send the IOCTL to AFD.  AFD will complete the request as soon as
    // one or more of the specified handles is ready for the specified
    // operation.
    //
    // Just use the first handle as the handle for the request.  Any
    // handle is fine; we just need a handle to AFD so that it gets to the
    // driver.
    //
    // Note that the same buffer is used for both input and output.
    // Since IOCTL_AFD_POLL is a method 0 (buffered) IOCTL, this
    // shouldn't cause problems.
    //

    WS_ASSERT( (IOCTL_AFD_POLL & 0x03) == METHOD_BUFFERED );

    status = NtDeviceIoControlFile(
                 pollInfo->Handles[0].Handle,
                 eventHandle,
                 NULL,                   // APC Routine
                 NULL,                   // APC Context
                 &ioStatusBlock,
                 IOCTL_AFD_POLL,
                 pollInfo,
                 pollBufferSize,
                 pollInfo,
                 pollBufferSize
                 );

    if ( status == STATUS_PENDING ) {
        SockWaitForSingleObject(
            eventHandle,
            (SOCKET)pollInfo->Handles[0].Handle,
            RtlLargeIntegerEqualToZero( pollInfo->Timeout ) ?
                SOCK_NEVER_CALL_BLOCKING_HOOK :
                SOCK_ALWAYS_CALL_BLOCKING_HOOK,
            SOCK_NO_TIMEOUT
            );
        status = ioStatusBlock.Status;
    }

    if ( !NT_SUCCESS(status) ) {
        error = SockNtStatusToSocketError( status );
        goto exit;
    }

    //
    // Use the information provided by the driver to set up the fd_set
    // structures to return to the caller.  First zero out the structures.
    //

    if ( readfds != NULL ) {
        FD_ZERO( readfds );
    }

    if ( writefds != NULL ) {
        FD_ZERO( writefds );
    }

    if ( exceptfds != NULL ) {
        FD_ZERO( exceptfds );
    }

    //
    // Walk the poll buffer returned by AFD, setting up the fd_set
    // structures as we go.
    //

    pollHandleInfo = pollInfo->Handles;

    for ( i = 0; i < pollInfo->NumberOfHandles; i++ ) {

        WS_ASSERT( pollHandleInfo->PollEvents != 0 );

        if ( (pollHandleInfo->PollEvents & AFD_POLL_RECEIVE) != 0 ) {

            WS_ASSERT( readfds != NULL );

            if ( !FD_ISSET( (SOCKET)pollHandleInfo->Handle, readfds ) ) {
                FD_SET( (SOCKET)pollHandleInfo->Handle, readfds );
                handlesReady++;
            }

            IF_DEBUG(SELECT) {
                WS_PRINT(( "select handle %lx ready for reading.\n",
                               pollHandleInfo->Handle ));
            }

        }

        if ( (pollHandleInfo->PollEvents & AFD_POLL_SEND) != 0 ) {

            WS_ASSERT( writefds != NULL );

            if ( !FD_ISSET( (SOCKET)pollHandleInfo->Handle, writefds ) ) {
                FD_SET( (SOCKET)pollHandleInfo->Handle, writefds );
                handlesReady++;
            }

            IF_DEBUG(SELECT) {
                WS_PRINT(( "select handle %lx ready for writing.\n",
                               pollHandleInfo->Handle ));
            }

        }

        if ( (pollHandleInfo->PollEvents & AFD_POLL_RECEIVE_EXPEDITED) != 0 ) {

            WS_ASSERT( exceptfds != NULL );

            if ( !FD_ISSET( (SOCKET)pollHandleInfo->Handle, exceptfds ) ) {
                FD_SET( (SOCKET)pollHandleInfo->Handle, exceptfds );
                handlesReady++;
            }


            IF_DEBUG(SELECT) {
                WS_PRINT(( "select handle %lx ready for expedited reading.\n",
                               pollHandleInfo->Handle ));
            }

        }

        if ( (pollHandleInfo->PollEvents & AFD_POLL_ACCEPT) != 0 ) {

            WS_ASSERT( readfds != NULL );

            if ( !FD_ISSET( (SOCKET)pollHandleInfo->Handle, readfds ) ) {
                FD_SET( (SOCKET)pollHandleInfo->Handle, readfds );
                handlesReady++;
            }


            IF_DEBUG(SELECT) {
                WS_PRINT(( "select handle %lx ready for accept.\n",
                               pollHandleInfo->Handle ));
            }

        }

        if ( (pollHandleInfo->PollEvents & AFD_POLL_CONNECT) != 0 ) {

            WS_ASSERT( NT_SUCCESS(pollHandleInfo->Status) );
            WS_ASSERT( writefds != NULL );
    
            if ( !FD_ISSET( (SOCKET)pollHandleInfo->Handle, writefds ) ) {
                FD_SET( (SOCKET)pollHandleInfo->Handle, writefds );
                handlesReady++;
            }

            IF_DEBUG(SELECT) {
                WS_PRINT(( "select handle %lx completed connect, status %lx\n",
                               pollHandleInfo->Handle, pollHandleInfo->Status ));
            }

        }

        if ( (pollHandleInfo->PollEvents & AFD_POLL_CONNECT_FAIL) != 0 ) {

            WS_ASSERT( !NT_SUCCESS(pollHandleInfo->Status) );
            WS_ASSERT( exceptfds != NULL );
    
            if ( !FD_ISSET( (SOCKET)pollHandleInfo->Handle, exceptfds ) ) {
                FD_SET( (SOCKET)pollHandleInfo->Handle, exceptfds );
                handlesReady++;
            }

            IF_DEBUG(SELECT) {
                WS_PRINT(( "select handle %lx completed connect, status %lx\n",
                               pollHandleInfo->Handle, pollHandleInfo->Status ));
            }

        }

        if ( (pollHandleInfo->PollEvents & AFD_POLL_DISCONNECT) != 0 ) {

            WS_ASSERT( readfds != NULL );

            if ( !FD_ISSET( (SOCKET)pollHandleInfo->Handle, readfds ) ) {
                FD_SET( (SOCKET)pollHandleInfo->Handle, readfds );
                handlesReady++;
            }


            IF_DEBUG(SELECT) {
                WS_PRINT(( "select handle %lx disconnected.\n",
                               pollHandleInfo->Handle ));
            }

        }

        if ( (pollHandleInfo->PollEvents & AFD_POLL_ABORT) != 0 ) {

            WS_ASSERT( readfds != NULL );

            if ( !FD_ISSET( (SOCKET)pollHandleInfo->Handle, readfds ) ) {
                FD_SET( (SOCKET)pollHandleInfo->Handle, readfds );
                handlesReady++;
            }


            IF_DEBUG(SELECT) {
                WS_PRINT(( "select handle %lx aborted.\n",
                               pollHandleInfo->Handle ));
            }

        }

        if ( (pollHandleInfo->PollEvents & AFD_POLL_LOCAL_CLOSE) != 0 ) {

            //
            // If the app does a closesocket() on a handle that has a
            // select() outstanding on it, this event may get set by
            // AFD even though we didn't request notification of it.
            // If exceptfds is NULL, then this is an error condition.
            //

            if ( readfds == NULL ) {
                handlesReady = 0;
                error = WSAENOTSOCK;
                goto exit;
            } else {

                if ( !FD_ISSET( (SOCKET)pollHandleInfo->Handle, readfds ) ) {
                    FD_SET( (SOCKET)pollHandleInfo->Handle, readfds );
                    handlesReady++;
                }
            }

            IF_DEBUG(SELECT) {
                WS_PRINT(( "select handle %lx closed locally.\n",
                               pollHandleInfo->Handle ));
            }

        }

        pollHandleInfo++;
    }

exit:

    IF_DEBUG(SELECT) {
        if ( error != NO_ERROR ) {
            WS_PRINT(( "select failed: %ld.\n", error ));
        } else {
            WS_PRINT(( "select succeeded, %ld readfds, %ld writefds, "
                       "%ld exceptfds\n",
                           HANDLES_IN_SET( readfds ),
                           HANDLES_IN_SET( writefds ),
                           HANDLES_IN_SET( exceptfds ) ));
        }
    }

    if ( pollInfo != NULL ) {
        FREE_HEAP( pollInfo );
    }

    if ( eventHandle != NULL ) {
        NtClose( eventHandle );
    }

    if ( error != NO_ERROR ) {
        SetLastError( error );
        WS_EXIT( "select", SOCKET_ERROR, TRUE );
        return SOCKET_ERROR;
    }

    WS_ASSERT( (ULONG)handlesReady == (ULONG)(HANDLES_IN_SET( readfds ) +
                                              HANDLES_IN_SET( writefds ) +
                                              HANDLES_IN_SET( exceptfds )) );

    WS_EXIT( "select", handlesReady, FALSE );
    return handlesReady;

} // select


int PASCAL FAR
__WSAFDIsSet (
    SOCKET fd,
    fd_set FAR *set
    )

/*++

Routine Description:

    This routine is used by the FD_ISSET macro; applications should
    not call it directly.  It determines whether a socket handle is
    included in an fd_set structure.

Arguments:

    fd - The socket handle to look for.

    set - The fd_set structure to examine.

Return Value:

    TRUE if the socket handle is in the set, FALSE if it is not.

--*/

{

    int i = (set->fd_count & 0xFFFF);

    while (i--)
        if (set->fd_array[i] == fd)
            return 1;

    return 0;

} // __WSAFDIsSet
