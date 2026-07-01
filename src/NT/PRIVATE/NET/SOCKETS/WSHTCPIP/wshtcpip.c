/*++

Copyright (c) 1993 Microsoft Corporation

Module Name:

    wshtcpip.c

Abstract:

    This module contains the necessary routines for the TCP/IP Windows
    Sockets Helper DLL.  This DLL provides the transport-specific support
    the Windows Sockets DLL (wsock32) needs to open AF_INET sockets on the
    TCP/IP transport (afd.sys -> \Device\Tcp / \Device\Udp).

    The NT 3.5 tree shipped this DLL only as a prebuilt import lib; this is
    a minimal reimplementation of the eight WSH entry points the NT 3.5
    winsock DLL calls (per wsahelp.h), modelled on the sibling WSHNETBS.C
    helper.  The TCP/IP specifics (triple mapping, device names, sockaddr
    interpretation) follow the NT4 wshtcpip.

--*/

#define UNICODE

#include <nt.h>
#include <ntrtl.h>
#include <nturtl.h>

#include <windef.h>
#include <winbase.h>
#include <tdi.h>

#include <winsock.h>
#include <wsahelp.h>
#include <ntddtcp.h>

#include <basetyps.h>
#include <nspapi.h>
#include <nspapip.h>

//
// Structure and variables to define the triples supported by TCP/IP.  The
// first entry of each array is the canonical triple for that socket type;
// the others are synonyms for the first.
//

typedef struct _MAPPING_TRIPLE {
    INT AddressFamily;
    INT SocketType;
    INT Protocol;
} MAPPING_TRIPLE, *PMAPPING_TRIPLE;

MAPPING_TRIPLE TcpMappingTriples[] = { AF_INET,   SOCK_STREAM, IPPROTO_TCP,
                                       AF_INET,   SOCK_STREAM, 0,
                                       AF_INET,   0,           IPPROTO_TCP,
                                       AF_UNSPEC, 0,           IPPROTO_TCP,
                                       AF_UNSPEC, SOCK_STREAM, IPPROTO_TCP };

MAPPING_TRIPLE UdpMappingTriples[] = { AF_INET,   SOCK_DGRAM,  IPPROTO_UDP,
                                       AF_INET,   SOCK_DGRAM,  0,
                                       AF_INET,   0,           IPPROTO_UDP,
                                       AF_UNSPEC, 0,           IPPROTO_UDP,
                                       AF_UNSPEC, SOCK_DGRAM,  IPPROTO_UDP };

//
// The per-socket context structure for this DLL.  Each open TCP/IP socket
// has one, used to canonicalize the triple and answer SO_CONTEXT queries.
//

typedef struct _WSHTCPIP_SOCKET_CONTEXT {
    INT AddressFamily;
    INT SocketType;
    INT Protocol;
} WSHTCPIP_SOCKET_CONTEXT, *PWSHTCPIP_SOCKET_CONTEXT;


BOOLEAN
IsTripleInList (
    IN PMAPPING_TRIPLE List,
    IN ULONG Count,
    IN INT AddressFamily,
    IN INT SocketType,
    IN INT Protocol
    )

/*++

Routine Description:

    Determines whether the specified triple appears in a mapping list.  A
    zero in a list entry's SocketType or Protocol field acts as a wildcard.

--*/

{
    ULONG i;

    for ( i = 0; i < Count; i++ ) {

        if ( ( List[i].AddressFamily == AddressFamily ) &&
             ( List[i].SocketType == SocketType || List[i].SocketType == 0 ) &&
             ( List[i].Protocol == Protocol || List[i].Protocol == 0 ) ) {

            return TRUE;
        }
    }

    return FALSE;

} // IsTripleInList


BOOLEAN
DllInitialize (
    IN PVOID DllHandle,
    IN ULONG Reason,
    IN PVOID Context OPTIONAL
    )
{
    UNREFERENCED_PARAMETER( DllHandle );
    UNREFERENCED_PARAMETER( Context );

    //
    // Unlike the Netbios helper, the TCP/IP helper is stateless: the set
    // of transports (TCP, UDP) is fixed and the device names are constants,
    // so there is nothing to read from the registry at attach time.
    //

    switch ( Reason ) {

    case DLL_PROCESS_ATTACH:
    case DLL_THREAD_ATTACH:
    case DLL_THREAD_DETACH:
    case DLL_PROCESS_DETACH:

        break;
    }

    return TRUE;

} // DllInitialize


INT
WSHGetSockaddrType (
    IN PSOCKADDR Sockaddr,
    IN DWORD SockaddrLength,
    OUT PSOCKADDR_INFO SockaddrInfo
    )

/*++

Routine Description:

    Parses a sockaddr to determine the type of the machine address and
    endpoint (port) portions.  Called by the winsock DLL whenever it needs
    to interpret a sockaddr.

--*/

{
    UNALIGNED SOCKADDR_IN *sockaddr = (PSOCKADDR_IN)Sockaddr;
    ULONG i;

    if ( sockaddr->sin_family != AF_INET ) {
        return WSAEAFNOSUPPORT;
    }

    if ( SockaddrLength < sizeof(SOCKADDR_IN) ) {
        return WSAEFAULT;
    }

    //
    // Determine the type of the address portion of the sockaddr.
    //

    if ( sockaddr->sin_addr.s_addr == INADDR_ANY ) {
        SockaddrInfo->AddressInfo = SockaddrAddressInfoWildcard;
    } else if ( sockaddr->sin_addr.s_addr == INADDR_BROADCAST ) {
        SockaddrInfo->AddressInfo = SockaddrAddressInfoBroadcast;
    } else if ( sockaddr->sin_addr.s_addr == INADDR_LOOPBACK ) {
        SockaddrInfo->AddressInfo = SockaddrAddressInfoLoopback;
    } else {
        SockaddrInfo->AddressInfo = SockaddrAddressInfoNormal;
    }

    //
    // Determine the type of the port (endpoint) in the sockaddr.
    //

    if ( sockaddr->sin_port == 0 ) {
        SockaddrInfo->EndpointInfo = SockaddrEndpointInfoWildcard;
    } else if ( ntohs( sockaddr->sin_port ) < 2000 ) {
        SockaddrInfo->EndpointInfo = SockaddrEndpointInfoReserved;
    } else {
        SockaddrInfo->EndpointInfo = SockaddrEndpointInfoNormal;
    }

    //
    // Zero out the sin_zero part of the address.  We silently allow
    // nonzero values in this field.
    //

    for ( i = 0; i < sizeof(sockaddr->sin_zero); i++ ) {
        sockaddr->sin_zero[i] = 0;
    }

    return NO_ERROR;

} // WSHGetSockaddrType


INT
WSHGetSocketInformation (
    IN PVOID HelperDllSocketContext,
    IN SOCKET SocketHandle,
    IN HANDLE TdiAddressObjectHandle,
    IN HANDLE TdiConnectionObjectHandle,
    IN INT Level,
    IN INT OptionName,
    OUT PCHAR OptionValue,
    OUT PINT OptionLength
    )

/*++

Routine Description:

    Retrieves information about a socket for those options handled in this
    helper DLL.  The only option handled here is the winsock DLL's internal
    request for our per-socket context block.

--*/

{
    PWSHTCPIP_SOCKET_CONTEXT context = HelperDllSocketContext;

    UNREFERENCED_PARAMETER( SocketHandle );
    UNREFERENCED_PARAMETER( TdiAddressObjectHandle );
    UNREFERENCED_PARAMETER( TdiConnectionObjectHandle );

    //
    // Check if this is an internal request for context information.
    //

    if ( Level == SOL_INTERNAL && OptionName == SO_CONTEXT ) {

        if ( OptionValue != NULL ) {

            if ( *OptionLength < sizeof(*context) ) {
                return WSAEFAULT;
            }

            RtlCopyMemory( OptionValue, context, sizeof(*context) );
        }

        *OptionLength = sizeof(*context);

        return NO_ERROR;
    }

    //
    // No other options are handled in the helper; the winsock DLL passes
    // real IP/TCP options straight to the transport.
    //

    return WSAEINVAL;

} // WSHGetSocketInformation


INT
WSHGetWildcardSockaddr (
    IN PVOID HelperDllSocketContext,
    OUT PSOCKADDR Sockaddr,
    OUT PINT SockaddrLength
    )

/*++

Routine Description:

    Returns a wildcard socket address.  For TCP/IP a wildcard address has
    IP address 0.0.0.0 and port 0.

--*/

{
    UNREFERENCED_PARAMETER( HelperDllSocketContext );

    if ( *SockaddrLength < sizeof(SOCKADDR_IN) ) {
        return WSAEFAULT;
    }

    *SockaddrLength = sizeof(SOCKADDR_IN);

    RtlZeroMemory( Sockaddr, sizeof(SOCKADDR_IN) );

    Sockaddr->sa_family = AF_INET;

    return NO_ERROR;

} // WSHGetWildcardSockaddr


DWORD
WSHGetWinsockMapping (
    OUT PWINSOCK_MAPPING Mapping,
    IN DWORD MappingLength
    )

/*++

Routine Description:

    Returns the list of address family/socket type/protocol triples
    supported by this helper DLL (TCP and UDP over AF_INET).

--*/

{
    DWORD mappingLength;

    mappingLength = sizeof(WINSOCK_MAPPING) - sizeof(MAPPING_TRIPLE) +
                        sizeof(TcpMappingTriples) + sizeof(UdpMappingTriples);

    if ( mappingLength > MappingLength ) {
        return mappingLength;
    }

    Mapping->Rows = sizeof(TcpMappingTriples) / sizeof(TcpMappingTriples[0])
                     + sizeof(UdpMappingTriples) / sizeof(UdpMappingTriples[0]);
    Mapping->Columns = sizeof(MAPPING_TRIPLE) / sizeof(DWORD);

    RtlMoveMemory(
        Mapping->Mapping,
        TcpMappingTriples,
        sizeof(TcpMappingTriples)
        );
    RtlMoveMemory(
        (PCHAR)Mapping->Mapping + sizeof(TcpMappingTriples),
        UdpMappingTriples,
        sizeof(UdpMappingTriples)
        );

    return mappingLength;

} // WSHGetWinsockMapping


INT
WSHOpenSocket (
    IN OUT PINT AddressFamily,
    IN OUT PINT SocketType,
    IN OUT PINT Protocol,
    OUT PUNICODE_STRING TransportDeviceName,
    OUT PVOID *HelperDllSocketContext,
    OUT PDWORD NotificationEvents
    )

/*++

Routine Description:

    Opens a socket on behalf of the winsock DLL's socket() routine.
    Verifies the triple, determines the TDI device name of the transport
    that will support it (\Device\Tcp or \Device\Udp), allocates the
    socket's context block, and canonicalizes the triple.

--*/

{
    PWSHTCPIP_SOCKET_CONTEXT context;

    //
    // Determine whether this is to be a TCP or UDP socket and hand back
    // the canonical triple + TDI device name.
    //

    if ( IsTripleInList(
             TcpMappingTriples,
             sizeof(TcpMappingTriples) / sizeof(TcpMappingTriples[0]),
             *AddressFamily,
             *SocketType,
             *Protocol ) ) {

        *AddressFamily = TcpMappingTriples[0].AddressFamily;
        *SocketType = TcpMappingTriples[0].SocketType;
        *Protocol = TcpMappingTriples[0].Protocol;

        RtlInitUnicodeString( TransportDeviceName, DD_TCP_DEVICE_NAME );

    } else if ( IsTripleInList(
                    UdpMappingTriples,
                    sizeof(UdpMappingTriples) / sizeof(UdpMappingTriples[0]),
                    *AddressFamily,
                    *SocketType,
                    *Protocol ) ) {

        *AddressFamily = UdpMappingTriples[0].AddressFamily;
        *SocketType = UdpMappingTriples[0].SocketType;
        *Protocol = UdpMappingTriples[0].Protocol;

        RtlInitUnicodeString( TransportDeviceName, DD_UDP_DEVICE_NAME );

    } else {

        return WSAEINVAL;
    }

    //
    // Allocate context for this socket.  The winsock DLL returns this to
    // us on future get/set socket-option calls.
    //

    context = RtlAllocateHeap( RtlProcessHeap( ), 0, sizeof(*context) );
    if ( context == NULL ) {
        return WSAENOBUFS;
    }

    context->AddressFamily = *AddressFamily;
    context->SocketType = *SocketType;
    context->Protocol = *Protocol;

    //
    // We only need to be notified when the socket is closed so we can free
    // the context block.
    //

    *NotificationEvents = WSH_NOTIFY_CLOSE;

    *HelperDllSocketContext = context;
    return NO_ERROR;

} // WSHOpenSocket


INT
WSHNotify (
    IN PVOID HelperDllSocketContext,
    IN SOCKET SocketHandle,
    IN HANDLE TdiAddressObjectHandle,
    IN HANDLE TdiConnectionObjectHandle,
    IN DWORD NotifyEvent
    )

/*++

Routine Description:

    Called by the winsock DLL after a socket state transition we asked to
    be notified of.  We only ask for WSH_NOTIFY_CLOSE, at which point we
    free the socket context.

--*/

{
    UNREFERENCED_PARAMETER( SocketHandle );
    UNREFERENCED_PARAMETER( TdiAddressObjectHandle );
    UNREFERENCED_PARAMETER( TdiConnectionObjectHandle );

    if ( NotifyEvent == WSH_NOTIFY_CLOSE ) {

        RtlFreeHeap( RtlProcessHeap( ), 0, HelperDllSocketContext );

    } else {

        return WSAEINVAL;
    }

    return NO_ERROR;

} // WSHNotify


INT
WSHSetSocketInformation (
    IN PVOID HelperDllSocketContext,
    IN SOCKET SocketHandle,
    IN HANDLE TdiAddressObjectHandle,
    IN HANDLE TdiConnectionObjectHandle,
    IN INT Level,
    IN INT OptionName,
    IN PCHAR OptionValue,
    IN INT OptionLength
    )

/*++

Routine Description:

    Sets information about a socket for those options handled in this
    helper DLL.  The only option handled here is the winsock DLL's internal
    request to (re)establish our per-socket context for an inherited or
    accept()'ed socket.

--*/

{
    PWSHTCPIP_SOCKET_CONTEXT context = HelperDllSocketContext;

    UNREFERENCED_PARAMETER( SocketHandle );
    UNREFERENCED_PARAMETER( TdiAddressObjectHandle );
    UNREFERENCED_PARAMETER( TdiConnectionObjectHandle );

    if ( Level == SOL_INTERNAL && OptionName == SO_CONTEXT ) {

        if ( OptionLength < sizeof(*context) ) {
            return WSAEINVAL;
        }

        if ( HelperDllSocketContext == NULL ) {

            //
            // A socket handle was inherited or duped into this process.
            // Allocate a fresh context and hand it back to the winsock DLL.
            //

            context = RtlAllocateHeap( RtlProcessHeap( ), 0, sizeof(*context) );
            if ( context == NULL ) {
                return WSAENOBUFS;
            }

            RtlCopyMemory( context, OptionValue, sizeof(*context) );

            *(PWSHTCPIP_SOCKET_CONTEXT *)OptionValue = context;

            return NO_ERROR;

        } else {

            //
            // The socket was accept()'ed; it already has a context that
            // matches its parent's.  Nothing more to do.
            //

            return NO_ERROR;
        }
    }

    return WSAEINVAL;

} // WSHSetSocketInformation


INT
WSHEnumProtocols (
    IN LPINT lpiProtocols,
    IN LPWSTR lpTransportKeyName,
    IN OUT LPVOID lpProtocolBuffer,
    IN OUT LPDWORD lpdwBufferLength
    )

/*++

Routine Description:

    Returns PROTOCOL_INFO entries for the TCP and UDP protocols supported
    by this helper DLL.

--*/

{
    DWORD bytesRequired;
    PPROTOCOL_INFO protocolInfo;
    PCHAR namePointer;
    static WCHAR tcpName[] = L"TCP/IP";
    static WCHAR udpName[] = L"UDP/IP";
    BOOLEAN wantTcp = TRUE;
    BOOLEAN wantUdp = TRUE;

    UNREFERENCED_PARAMETER( lpTransportKeyName );

    //
    // Honour a caller-supplied protocol filter (a zero-terminated list of
    // protocol values).  Absent a filter, report both TCP and UDP.
    //

    if ( ARGUMENT_PRESENT( lpiProtocols ) ) {
        LPINT p;

        wantTcp = FALSE;
        wantUdp = FALSE;

        for ( p = lpiProtocols; *p != 0; p++ ) {
            if ( *p == IPPROTO_TCP ) {
                wantTcp = TRUE;
            } else if ( *p == IPPROTO_UDP ) {
                wantUdp = TRUE;
            }
        }
    }

    bytesRequired = 0;
    if ( wantTcp ) {
        bytesRequired += sizeof(PROTOCOL_INFO) + sizeof(tcpName);
    }
    if ( wantUdp ) {
        bytesRequired += sizeof(PROTOCOL_INFO) + sizeof(udpName);
    }

    if ( bytesRequired > *lpdwBufferLength ) {
        *lpdwBufferLength = bytesRequired;
        return -1;
    }

    //
    // Protocol name strings are packed from the top of the buffer down;
    // the PROTOCOL_INFO array grows from the bottom up.
    //

    namePointer = (PCHAR)lpProtocolBuffer + *lpdwBufferLength;
    protocolInfo = lpProtocolBuffer;

    if ( wantTcp ) {

        protocolInfo->dwServiceFlags = XP_GUARANTEED_DELIVERY |
                                           XP_GUARANTEED_ORDER |
                                           XP_GRACEFUL_CLOSE;
        protocolInfo->iAddressFamily = AF_INET;
        protocolInfo->iMaxSockAddr = sizeof(SOCKADDR_IN);
        protocolInfo->iMinSockAddr = sizeof(SOCKADDR_IN);
        protocolInfo->iSocketType = SOCK_STREAM;
        protocolInfo->iProtocol = IPPROTO_TCP;
        protocolInfo->dwMessageSize = 0;

        namePointer -= sizeof(tcpName);
        protocolInfo->lpProtocol = (LPWSTR)namePointer;
        wcscpy( protocolInfo->lpProtocol, tcpName );

        protocolInfo++;
    }

    if ( wantUdp ) {

        protocolInfo->dwServiceFlags = XP_CONNECTIONLESS |
                                           XP_MESSAGE_ORIENTED |
                                           XP_SUPPORTS_BROADCAST |
                                           XP_FRAGMENTATION;
        protocolInfo->iAddressFamily = AF_INET;
        protocolInfo->iMaxSockAddr = sizeof(SOCKADDR_IN);
        protocolInfo->iMinSockAddr = sizeof(SOCKADDR_IN);
        protocolInfo->iSocketType = SOCK_DGRAM;
        protocolInfo->iProtocol = IPPROTO_UDP;
        protocolInfo->dwMessageSize = 65535 - 68;

        namePointer -= sizeof(udpName);
        protocolInfo->lpProtocol = (LPWSTR)namePointer;
        wcscpy( protocolInfo->lpProtocol, udpName );

        protocolInfo++;
    }

    *lpdwBufferLength = bytesRequired;

    return (INT)( wantTcp + wantUdp );

} // WSHEnumProtocols
