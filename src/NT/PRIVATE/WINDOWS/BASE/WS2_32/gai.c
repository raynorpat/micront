/*++

Module Name:

    gai.c

Abstract:

    Protocol-independent name resolution: getaddrinfo / freeaddrinfo, the names
    modern std libraries (Rust std::net) use instead of gethostbyname.  Layered
    on the existing IPv4 resolver -- inet_addr for numeric hosts, gethostbyname
    (hosts file) for names, the hardcoded getservbyname table for services.

    No DNS: a name that is neither numeric nor in \SystemRoot\System32\hosts
    resolves to EAI_NONAME -- the truthful answer until a DNS resolver lands.

--*/

#include "winsockp.h"
#include "winsk2p.h"

//
// Allocate one result node carrying its sockaddr_in inline, so freeaddrinfo
// can release it (and an optional canonical name) with a single FREE_HEAP.
//
static ADDRINFOA *
GaiAlloc(
    int    SockType,
    int    Protocol,
    ULONG  Address,
    USHORT Port
    )
{
    ADDRINFOA          *ai;
    struct sockaddr_in *sin;

    ai = (ADDRINFOA *)ALLOCATE_HEAP( sizeof(ADDRINFOA) + sizeof(struct sockaddr_in) );
    if (ai == NULL) {
        return NULL;
    }
    RtlZeroMemory( ai, sizeof(ADDRINFOA) + sizeof(struct sockaddr_in) );

    sin = (struct sockaddr_in *)(ai + 1);
    sin->sin_family      = AF_INET;
    sin->sin_port        = Port;             // network order
    sin->sin_addr.s_addr = Address;          // network order

    ai->ai_family   = AF_INET;
    ai->ai_socktype = SockType;
    ai->ai_protocol = Protocol;
    ai->ai_addrlen  = sizeof(struct sockaddr_in);
    ai->ai_addr     = (struct sockaddr *)sin;
    return ai;
}

int WINAPI
getaddrinfo(
    IN  const char      *pNodeName,
    IN  const char      *pServiceName,
    IN  const ADDRINFOA *pHints,
    OUT PADDRINFOA      *ppResult
    )
{
    ULONG      addr;
    USHORT     port     = 0;
    int        family   = AF_INET;
    int        socktype = 0;
    int        protocol = 0;
    int        flags    = 0;
    ADDRINFOA *ai;

    if (ppResult == NULL) {
        return EAI_FAIL;
    }
    *ppResult = NULL;

    if (pHints != NULL) {
        family   = pHints->ai_family;
        socktype = pHints->ai_socktype;
        protocol = pHints->ai_protocol;
        flags    = pHints->ai_flags;
        if (family != AF_UNSPEC && family != AF_INET) {
            return EAI_FAMILY;          // MicroNT is IPv4-only
        }
    }

    //
    // Node -> IPv4 address.
    //
    if (pNodeName == NULL) {
        addr = (flags & AI_PASSIVE) ? INADDR_ANY : htonl( INADDR_LOOPBACK );
    } else {
        addr = inet_addr( pNodeName );
        if (addr == INADDR_NONE) {
            PHOSTENT he;

            if (flags & AI_NUMERICHOST) {
                return EAI_NONAME;      // caller promised numeric; it was not
            }
            he = gethostbyname( pNodeName );
            if (he == NULL || he->h_addr_list[0] == NULL) {
                return EAI_NONAME;      // not numeric, not in hosts, no DNS
            }
            RtlCopyMemory( &addr, he->h_addr_list[0], 4 );
        }
    }

    //
    // Service -> port.  A leading digit means a numeric port; otherwise look it
    // up in the services table (proto picked from the requested socket type).
    //
    if (pServiceName != NULL && *pServiceName != '\0') {
        if (pServiceName[0] >= '0' && pServiceName[0] <= '9') {
            port = htons( (USHORT)atoi( pServiceName ) );
        } else {
            const char *proto = (socktype == SOCK_DGRAM) ? "udp" : "tcp";
            PSERVENT    se    = getservbyname( pServiceName, proto );

            if (se == NULL) {
                return EAI_SERVICE;
            }
            port = se->s_port;          // already network order
        }
    }

    //
    // Pair an unspecified socket type / protocol the conventional way.
    //
    if (socktype == 0 && protocol != 0) {
        socktype = (protocol == IPPROTO_UDP) ? SOCK_DGRAM : SOCK_STREAM;
    }
    if (protocol == 0 && socktype != 0) {
        protocol = (socktype == SOCK_DGRAM) ? IPPROTO_UDP : IPPROTO_TCP;
    }

    ai = GaiAlloc( socktype, protocol, addr, port );
    if (ai == NULL) {
        return EAI_MEMORY;
    }

    *ppResult = ai;
    return 0;
}

void WINAPI
freeaddrinfo(
    IN PADDRINFOA pAddrInfo
    )
{
    while (pAddrInfo != NULL) {
        PADDRINFOA next = pAddrInfo->ai_next;

        if (pAddrInfo->ai_canonname != NULL) {
            FREE_HEAP( pAddrInfo->ai_canonname );
        }
        FREE_HEAP( pAddrInfo );
        pAddrInfo = next;
    }
}
