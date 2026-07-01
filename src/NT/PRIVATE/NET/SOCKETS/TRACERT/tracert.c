/*++

Copyright (c) 1994 Microsoft Corporation

Module Name:

    tracert.c

Abstract:

    A minimal `tracert` (traceroute) command-line utility.  Sends ICMP echo
    requests with an increasing IP TTL through icmp.dll (IcmpSendEcho); each
    router that decrements the TTL to zero returns an ICMP time-exceeded,
    which the IP driver surfaces as IP_TTL_EXPIRED_TRANSIT with the router's
    address.  Repeating with TTL 1, 2, 3, ... walks the path to the target.

    Usage:  tracert [-h maxhops] [-w timeout] target

--*/

#include <windows.h>
#include <winsock.h>
#include <ipexport.h>
#include <icmpapi.h>
#include <stdio.h>
#include <stdlib.h>

#define DEFAULT_MAX_HOPS    30
#define DEFAULT_TIMEOUT     3000    // ms
#define PROBES_PER_HOP      3
#define PROBE_DATA_SIZE     32


VOID
PrintAddress(
    IPAddr Address
    )
{
    PUCHAR b = (PUCHAR)&Address;
    printf( "%u.%u.%u.%u", b[0], b[1], b[2], b[3] );
}


VOID
Usage(
    VOID
    )
{
    printf( "usage: tracert [-h maximum_hops] [-w timeout] target\n" );
}


int
__cdecl
main(
    int argc,
    char **argv
    )
{
    WSADATA wsaData;
    HANDLE icmpHandle;
    IPAddr address;
    struct hostent *host;
    char *target = NULL;
    DWORD maxHops = DEFAULT_MAX_HOPS;
    DWORD timeout = DEFAULT_TIMEOUT;
    DWORD ttl;
    DWORD i;
    CHAR sendBuffer[PROBE_DATA_SIZE];
    PVOID replyBuffer;
    DWORD replySize;
    IP_OPTION_INFORMATION options;

    for ( i = 1; i < (DWORD)argc; i++ ) {
        if ( argv[i][0] == '-' ) {
            switch ( argv[i][1] ) {
            case 'h':
                if ( ++i < (DWORD)argc ) maxHops = atoi( argv[i] );
                break;
            case 'w':
                if ( ++i < (DWORD)argc ) timeout = atoi( argv[i] );
                break;
            default:
                Usage();
                return 1;
            }
        } else {
            target = argv[i];
        }
    }

    if ( target == NULL ) {
        Usage();
        return 1;
    }

    if ( WSAStartup( 0x0101, &wsaData ) != 0 ) {
        printf( "tracert: unable to initialize Windows Sockets.\n" );
        return 1;
    }

    address = inet_addr( target );
    if ( address == INADDR_NONE ) {
        host = gethostbyname( target );
        if ( host == NULL ) {
            printf( "tracert: cannot resolve %s: unknown host\n", target );
            WSACleanup();
            return 1;
        }
        address = *(IPAddr *)host->h_addr;
    }

    icmpHandle = IcmpCreateFile();
    if ( icmpHandle == INVALID_HANDLE_VALUE ) {
        printf( "tracert: unable to open ICMP handle (error %lu)\n",
                GetLastError() );
        WSACleanup();
        return 1;
    }

    replySize = sizeof(ICMP_ECHO_REPLY) + PROBE_DATA_SIZE + 8;
    replyBuffer = LocalAlloc( LPTR, replySize );
    if ( replyBuffer == NULL ) {
        printf( "tracert: out of memory\n" );
        IcmpCloseHandle( icmpHandle );
        WSACleanup();
        return 1;
    }
    for ( i = 0; i < PROBE_DATA_SIZE; i++ ) {
        sendBuffer[i] = (CHAR)( 'a' + ( i % 23 ) );
    }

    printf( "\nTracing route to " );
    PrintAddress( address );
    printf( "\nover a maximum of %lu hops:\n\n", maxHops );

    for ( ttl = 1; ttl <= maxHops; ttl++ ) {

        IPAddr hopAddress = 0;
        BOOL gotReply = FALSE;
        BOOL reachedDest = FALSE;
        DWORD probe;

        printf( "%3lu ", ttl );

        RtlZeroMemory( &options, sizeof(options) );
        options.Ttl = (UCHAR)ttl;

        for ( probe = 0; probe < PROBES_PER_HOP; probe++ ) {

            DWORD replies;
            PICMP_ECHO_REPLY reply;

            replies = IcmpSendEcho(
                          icmpHandle,
                          address,
                          sendBuffer,
                          PROBE_DATA_SIZE,
                          &options,
                          replyBuffer,
                          replySize,
                          timeout
                          );

            if ( replies == 0 ) {
                printf( "    *   " );
                continue;
            }

            reply = (PICMP_ECHO_REPLY)replyBuffer;

            if ( reply->RoundTripTime == 0 ) {
                printf( "  <10 ms" );
            } else {
                printf( " %4lu ms", reply->RoundTripTime );
            }

            hopAddress = reply->Address;
            gotReply = TRUE;

            //
            // IP_SUCCESS means the echo reached the target itself; anything
            // else (typically IP_TTL_EXPIRED_TRANSIT) is an intermediate
            // router and we keep walking.
            //

            if ( reply->Status == IP_SUCCESS ) {
                reachedDest = TRUE;
            }
        }

        if ( gotReply ) {
            printf( "  " );
            PrintAddress( hopAddress );
            printf( "\n" );
        } else {
            printf( "  Request timed out.\n" );
        }

        if ( reachedDest ) {
            break;
        }
    }

    printf( "\nTrace complete.\n" );

    IcmpCloseHandle( icmpHandle );
    WSACleanup();

    return 0;
}
