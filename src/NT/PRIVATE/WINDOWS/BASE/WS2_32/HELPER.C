/*++

Copyright (c) 1992  Microsoft Corporation

Module Name:

    helper.c

Abstract:

    MicroNT TCP/IP transport helper for ws2_32.

    MicroNT supports only IPv4 with TCP / UDP / raw IP (executive decision).
    The original wsock32 resolved transports through a registry catalog of
    Winsock Helper DLLs; the catalog, LoadLibrary indirection, and vtable
    dispatch are pure overhead here.  This file provides the two address-
    classification helpers (WshIpGetSockaddrType, WshIpGetWildcardSockaddr)
    as plain functions called directly by the BSD core, and a SockGetTdiName
    that maps the {AF, type, protocol} triple straight to the TDI device name.

--*/

#include "winsockp.h"

//
// TDI transport device names (proven values -- see the Lua AFD client).
//

static const WCHAR SockTcpDeviceName[] = L"\\Device\\Tcp";
static const WCHAR SockUdpDeviceName[] = L"\\Device\\Udp";
static const WCHAR SockRawDeviceName[] = L"\\Device\\RawIp";


/***************************************************************************\
* SockGetTdiName
*
* Map a {AF, type, protocol} triple to the AFD TDI device name.
* Sets *Protocol to the canonical value when the caller passed 0.
* Returns WSAEAFNOSUPPORT / WSAESOCKTNOSUPPORT on unknown triples.
\***************************************************************************/
INT
SockGetTdiName (
    IN OUT PINT AddressFamily,
    IN OUT PINT SocketType,
    IN OUT PINT Protocol,
    OUT PUNICODE_STRING TransportDeviceName
    )
{
    if ( *AddressFamily == AF_UNSPEC ) {
        *AddressFamily = AF_INET;
    }
    if ( *AddressFamily != AF_INET ) {
        return WSAEAFNOSUPPORT;
    }

    switch ( *SocketType ) {

    case SOCK_STREAM:
        RtlInitUnicodeString( TransportDeviceName, SockTcpDeviceName );
        if ( *Protocol == 0 ) {
            *Protocol = IPPROTO_TCP;
        }
        break;

    case SOCK_DGRAM:
        RtlInitUnicodeString( TransportDeviceName, SockUdpDeviceName );
        if ( *Protocol == 0 ) {
            *Protocol = IPPROTO_UDP;
        }
        break;

    case SOCK_RAW:
        RtlInitUnicodeString( TransportDeviceName, SockRawDeviceName );
        break;

    default:
        return WSAESOCKTNOSUPPORT;
    }

    return NO_ERROR;

} // SockGetTdiName


/***************************************************************************\
* WshIpGetSockaddrType
*
* Classify an IPv4 sockaddr: validate length/family, then fill in address
* and endpoint classification in *SockaddrInfo.
\***************************************************************************/
INT
WshIpGetSockaddrType (
    IN PSOCKADDR Sockaddr,
    IN DWORD SockaddrLength,
    OUT PSOCKADDR_INFO SockaddrInfo
    )
{
    PSOCKADDR_IN sin = (PSOCKADDR_IN)Sockaddr;
    ULONG hostAddr;

    if ( SockaddrLength < sizeof(SOCKADDR_IN) || Sockaddr->sa_family != AF_INET ) {
        return WSAEFAULT;
    }

    if ( sin->sin_addr.s_addr == INADDR_ANY ) {
        SockaddrInfo->AddressInfo = SockaddrAddressInfoWildcard;
    } else if ( sin->sin_addr.s_addr == INADDR_BROADCAST ) {
        SockaddrInfo->AddressInfo = SockaddrAddressInfoBroadcast;
    } else {
        hostAddr = ntohl( sin->sin_addr.s_addr );
        if ( (hostAddr & 0xFF000000) == 0x7F000000 ) {
            SockaddrInfo->AddressInfo = SockaddrAddressInfoLoopback;
        } else {
            SockaddrInfo->AddressInfo = SockaddrAddressInfoNormal;
        }
    }

    if ( sin->sin_port == 0 ) {
        SockaddrInfo->EndpointInfo = SockaddrEndpointInfoWildcard;
    } else if ( ntohs( sin->sin_port ) < IPPORT_RESERVED ) {
        SockaddrInfo->EndpointInfo = SockaddrEndpointInfoReserved;
    } else {
        SockaddrInfo->EndpointInfo = SockaddrEndpointInfoNormal;
    }

    return NO_ERROR;

} // WshIpGetSockaddrType


/***************************************************************************\
* WshIpGetWildcardSockaddr
*
* Fill *Sockaddr with the IPv4 wildcard address (INADDR_ANY, port 0).
\***************************************************************************/
INT
WshIpGetWildcardSockaddr (
    OUT PSOCKADDR Sockaddr,
    OUT PINT SockaddrLength
    )
{
    PSOCKADDR_IN sin = (PSOCKADDR_IN)Sockaddr;

    if ( *SockaddrLength < (INT)sizeof(SOCKADDR_IN) ) {
        return WSAEFAULT;
    }

    RtlZeroMemory( sin, sizeof(SOCKADDR_IN) );
    sin->sin_family = AF_INET;
    sin->sin_addr.s_addr = INADDR_ANY;
    sin->sin_port = 0;
    *SockaddrLength = sizeof(SOCKADDR_IN);

    return NO_ERROR;

} // WshIpGetWildcardSockaddr
