/*++

Module Name:

    wsa2.c

Abstract:

    Winsock 2 socket-management entry points layered on the flat BSD/AFD core:
    WSASocketW (Unicode socket create) and WSADuplicateSocketW.

    WSARecv / WSASend (data path) live in recv.c / send.c next to their BSD
    siblings; getaddrinfo / freeaddrinfo (name resolution) live in gai.c.

--*/

#include "winsockp.h"
#include "winsk2p.h"

//
// WSASocketW -- create a socket.  Delegates to the BSD socket() for the
// supported case (no protocol-info descriptor, no socket group).  The
// extended parameters that MicroNT does not support are rejected truthfully
// rather than silently ignored.
//
SOCKET PASCAL
WSASocketW(
    IN int                 AddressFamily,
    IN int                 SocketType,
    IN int                 Protocol,
    IN LPWSAPROTOCOL_INFOW lpProtocolInfo,
    IN GROUP               g,
    IN DWORD               dwFlags
    )
{
    //
    // A protocol-info descriptor means "re-create this socket from a
    // WSADuplicateSocket blob" -- the cross-process sharing path MicroNT does
    // not implement (see WSADuplicateSocketW / ws2_32.md).
    //
    if (lpProtocolInfo != NULL) {
        WSASetLastError( WSAEINVAL );
        return INVALID_SOCKET;
    }

    //
    // Socket groups are not supported.
    //
    if (g != 0) {
        WSASetLastError( WSAEINVAL );
        return INVALID_SOCKET;
    }

    //
    // WSA_FLAG_OVERLAPPED -- every AFD socket is already overlapped-capable,
    // so it needs no special handling.  WSA_FLAG_NO_HANDLE_INHERIT (which
    // mio/Tokio pass) is already the default: AFD socket handles are opened
    // without OBJ_INHERIT, so they are non-inheritable already.  Any other
    // flag bit is not implemented.
    //
    if ((dwFlags & ~(WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT)) != 0) {
        WSASetLastError( WSAEINVAL );
        return INVALID_SOCKET;
    }

    return socket( AddressFamily, SocketType, Protocol );
}

//
// WSADuplicateSocketW -- produce a WSAPROTOCOL_INFO blob that another process
// could use to re-open this socket.  Cross-process socket sharing needs an AFD
// duplication path MicroNT does not have yet (see ws2_32.md); fail truthfully
// rather than return an unusable descriptor.
//
int PASCAL
WSADuplicateSocketW(
    IN  SOCKET              s,
    IN  DWORD               dwProcessId,
    OUT LPWSAPROTOCOL_INFOW lpProtocolInfo
    )
{
    UNREFERENCED_PARAMETER( s );
    UNREFERENCED_PARAMETER( dwProcessId );
    UNREFERENCED_PARAMETER( lpProtocolInfo );

    WSASetLastError( WSAEOPNOTSUPP );
    return SOCKET_ERROR;
}

//
// WSARecv -- synchronous scatter receive.  std::net uses a single WSABUF, the
// exact case recv() covers; WSARecv is also permitted to return fewer bytes
// than the whole buffer set, so filling the first buffer is a legal completion
// for the vectored case too.  The overlapped (lpOverlapped / completion
// routine) path is the async/IOCP milestone -- refused truthfully here rather
// than quietly downgraded to a synchronous receive (see ws2_32.md).
//
int PASCAL
WSARecv(
    IN     SOCKET                             Handle,
    IN     LPWSABUF                            lpBuffers,
    IN     DWORD                              dwBufferCount,
    OUT    LPDWORD                            lpNumberOfBytesRecvd,
    IN OUT LPDWORD                            lpFlags,
    IN     LPWSAOVERLAPPED                    lpOverlapped,
    IN     LPWSAOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine
    )
{
    int bytes;
    int flags;

    if (lpOverlapped != NULL || lpCompletionRoutine != NULL) {
        WSASetLastError( WSAEOPNOTSUPP );
        return SOCKET_ERROR;
    }
    if (lpBuffers == NULL || dwBufferCount == 0) {
        WSASetLastError( WSAEINVAL );
        return SOCKET_ERROR;
    }

    flags = (lpFlags != NULL) ? (int)*lpFlags : 0;

    bytes = recv( Handle, lpBuffers[0].buf, (int)lpBuffers[0].len, flags );
    if (bytes == SOCKET_ERROR) {
        return SOCKET_ERROR;          // recv() already set the WSA error
    }

    if (lpNumberOfBytesRecvd != NULL) {
        *lpNumberOfBytesRecvd = (DWORD)bytes;
    }
    if (lpFlags != NULL) {
        *lpFlags = 0;
    }
    return 0;
}

//
// WSASend -- synchronous gather send.  On a stream socket the buffers'
// bytes concatenate, so sending each WSABUF in order reproduces WSASend's
// gather exactly.  Overlapped path refused truthfully (see ws2_32.md).
//
int PASCAL
WSASend(
    IN  SOCKET                             Handle,
    IN  LPWSABUF                            lpBuffers,
    IN  DWORD                              dwBufferCount,
    OUT LPDWORD                            lpNumberOfBytesSent,
    IN  DWORD                              dwFlags,
    IN  LPWSAOVERLAPPED                    lpOverlapped,
    IN  LPWSAOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine
    )
{
    DWORD i;
    DWORD total = 0;

    if (lpOverlapped != NULL || lpCompletionRoutine != NULL) {
        WSASetLastError( WSAEOPNOTSUPP );
        return SOCKET_ERROR;
    }
    if (lpBuffers == NULL) {
        WSASetLastError( WSAEINVAL );
        return SOCKET_ERROR;
    }

    for (i = 0; i < dwBufferCount; i += 1) {
        int sent;

        if (lpBuffers[i].len == 0) {
            continue;
        }
        sent = send( Handle, lpBuffers[i].buf, (int)lpBuffers[i].len, (int)dwFlags );
        if (sent == SOCKET_ERROR) {
            if (total > 0) {
                break;                // report the bytes already sent
            }
            return SOCKET_ERROR;      // send() already set the WSA error
        }
        total += (DWORD)sent;
        if ((ULONG)sent < lpBuffers[i].len) {
            break;                    // short send: stop, don't reorder bytes
        }
    }

    if (lpNumberOfBytesSent != NULL) {
        *lpNumberOfBytesSent = total;
    }
    return 0;
}

//
// WSARecvFrom / WSASendTo / WSASendMsg -- the datagram WSA-2 scatter/gather
// variants, and WSAPoll -- the poll() multiplexer.  Exported so modern
// toolchains (mio/tokio, socket2) resolve their imports, but the TCP reactor
// path never calls them.  Rather than risk a silent wrong answer they return
// WSAEOPNOTSUPP truthfully; wire real bodies if a consumer is found to need
// them.  Exotic Vista-era parameter types (WSAMSG, WSAPOLLFD) are taken as
// opaque pointers -- pointer-width on x86, so the __stdcall frame is correct
// even when called.
//

int PASCAL
WSARecvFrom(
    IN     SOCKET                             Handle,
    IN     LPWSABUF                            lpBuffers,
    IN     DWORD                              dwBufferCount,
    OUT    LPDWORD                            lpNumberOfBytesRecvd,
    IN OUT LPDWORD                            lpFlags,
    OUT    void *                             lpFrom,
    IN OUT void *                             lpFromlen,
    IN     LPWSAOVERLAPPED                    lpOverlapped,
    IN     LPWSAOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine
    )
{
    WSASetLastError( WSAEOPNOTSUPP );
    return SOCKET_ERROR;
}

int PASCAL
WSASendTo(
    IN  SOCKET                             Handle,
    IN  LPWSABUF                            lpBuffers,
    IN  DWORD                              dwBufferCount,
    OUT LPDWORD                            lpNumberOfBytesSent,
    IN  DWORD                              dwFlags,
    IN  const void *                      lpTo,
    IN  int                               iToLen,
    IN  LPWSAOVERLAPPED                    lpOverlapped,
    IN  LPWSAOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine
    )
{
    WSASetLastError( WSAEOPNOTSUPP );
    return SOCKET_ERROR;
}

int PASCAL
WSASendMsg(
    IN  SOCKET                             Handle,
    IN  void *                            lpMsg,
    IN  DWORD                             dwFlags,
    OUT LPDWORD                           lpNumberOfBytesSent,
    IN  LPWSAOVERLAPPED                   lpOverlapped,
    IN  LPWSAOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine
    )
{
    WSASetLastError( WSAEOPNOTSUPP );
    return SOCKET_ERROR;
}

int PASCAL
WSAPoll(
    IN OUT void *fdArray,
    IN     ULONG nfds,
    IN     INT   timeout
    )
{
    WSASetLastError( WSAEOPNOTSUPP );
    return SOCKET_ERROR;
}
