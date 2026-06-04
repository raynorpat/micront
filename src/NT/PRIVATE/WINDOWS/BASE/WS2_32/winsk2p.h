/*++

Module Name:

    winsk2p.h

Abstract:

    Minimal Winsock 2 type surface for the WS2_32 entry points modern
    toolchains import (Rust std, Go, ...).  This SDK ships only winsock.h
    (Winsock 1.1); these are the 2.x additions, ABI-matched to the documented
    Win32 layouts so a binary built against the real ws2_32.lib links and runs
    against MicroNT's ws2_32 unchanged.

    Pulled in after winsockp.h (which supplies SOCKET, sockaddr, OVERLAPPED,
    the AFD/TDI types and the resolver).

--*/

#ifndef _WINSK2P_H_
#define _WINSK2P_H_

#ifndef GUID_DEFINED
#define GUID_DEFINED
typedef struct _GUID {
    unsigned long  Data1;
    unsigned short Data2;
    unsigned short Data3;
    unsigned char  Data4[8];
} GUID;
#endif

typedef unsigned int GROUP;

//
// Scatter/gather buffer descriptor (WSARecv / WSASend).
//
typedef struct _WSABUF {
    ULONG  len;
    CHAR  *buf;
} WSABUF, *LPWSABUF;

//
// Overlapped I/O -- ABI-identical to OVERLAPPED.
//
typedef OVERLAPPED  WSAOVERLAPPED;
typedef OVERLAPPED *LPWSAOVERLAPPED;
typedef void (CALLBACK *LPWSAOVERLAPPED_COMPLETION_ROUTINE)(
    IN DWORD           dwError,
    IN DWORD           cbTransferred,
    IN LPWSAOVERLAPPED lpOverlapped,
    IN DWORD           dwFlags
    );

#define WSA_FLAG_OVERLAPPED   0x01
#define WSA_IO_PENDING        ((DWORD)ERROR_IO_PENDING)
#define WSA_IO_INCOMPLETE     ((DWORD)ERROR_IO_INCOMPLETE)

//
// Protocol-info descriptor (WSASocketW / WSADuplicateSocketW).  We never
// populate it -- both paths that take it fail truthfully -- but the layout
// matches so the pointer ABI is exact.
//
#define WSAPROTOCOL_LEN     255
#define MAX_PROTOCOL_CHAIN  7

typedef struct _WSAPROTOCOLCHAIN {
    int   ChainLen;
    DWORD ChainEntries[MAX_PROTOCOL_CHAIN];
} WSAPROTOCOLCHAIN, *LPWSAPROTOCOLCHAIN;

typedef struct _WSAPROTOCOL_INFOW {
    DWORD            dwServiceFlags1;
    DWORD            dwServiceFlags2;
    DWORD            dwServiceFlags3;
    DWORD            dwServiceFlags4;
    DWORD            dwProviderFlags;
    GUID             ProviderId;
    DWORD            dwCatalogEntryId;
    WSAPROTOCOLCHAIN ProtocolChain;
    int              iVersion;
    int              iAddressFamily;
    int              iMaxSockAddr;
    int              iMinSockAddr;
    int              iSocketType;
    int              iProtocol;
    int              iProtocolMaxOffset;
    int              iNetworkByteOrder;
    int              iSecurityScheme;
    DWORD            dwMessageSize;
    DWORD            dwProviderReserved;
    WCHAR            szProtocol[WSAPROTOCOL_LEN + 1];
} WSAPROTOCOL_INFOW, *LPWSAPROTOCOL_INFOW;

//
// Protocol-independent name resolution (getaddrinfo / freeaddrinfo).  ANSI
// addrinfo -- the names Rust std imports.
//
#define AI_PASSIVE      0x01
#define AI_CANONNAME    0x02
#define AI_NUMERICHOST  0x04

typedef struct addrinfo {
    int              ai_flags;
    int              ai_family;
    int              ai_socktype;
    int              ai_protocol;
    size_t           ai_addrlen;
    char            *ai_canonname;
    struct sockaddr *ai_addr;
    struct addrinfo *ai_next;
} ADDRINFOA, *PADDRINFOA;

//
// getaddrinfo returns WSA error codes directly (EAI_* alias the WSA errors on
// Windows).
//
// Winsock 2 error codes absent from this 1.1 winsock.h (canonical values).
#ifndef WSATYPE_NOT_FOUND
#define WSATYPE_NOT_FOUND      10109L
#endif
#ifndef WSA_NOT_ENOUGH_MEMORY
#define WSA_NOT_ENOUGH_MEMORY  ((DWORD)ERROR_NOT_ENOUGH_MEMORY)
#endif

#define EAI_AGAIN       WSATRY_AGAIN
#define EAI_BADFLAGS    WSAEINVAL
#define EAI_FAIL        WSANO_RECOVERY
#define EAI_FAMILY      WSAEAFNOSUPPORT
#define EAI_MEMORY      WSA_NOT_ENOUGH_MEMORY
#define EAI_NONAME      WSAHOST_NOT_FOUND
#define EAI_SERVICE     WSATYPE_NOT_FOUND
#define EAI_SOCKTYPE    WSAESOCKTNOSUPPORT

#endif // _WINSK2P_H_
