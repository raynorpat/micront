/*++

Copyright (c) 1994 Microsoft Corporation

Module Name:

    ping.c

Abstract:

    A minimal `ping` command-line utility.  Resolves the target (dotted IP
    or host name via Winsock), then issues ICMP echo requests through
    icmp.dll (IcmpSendEcho) and reports each reply's round-trip time.

    Usage:  ping [-n count] [-l size] [-w timeout] target

--*/

#include <windows.h>
#include <winsock.h>
#include <ipexport.h>
#include <icmpapi.h>
#include <stdio.h>
#include <stdlib.h>

#define DEFAULT_COUNT       4
#define DEFAULT_DATA_SIZE   32
#define DEFAULT_TIMEOUT     1000    // ms
#define MAX_DATA_SIZE       8192

//
// Print an IP address (network byte order) as dotted decimal.
//

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
    printf( "usage: ping [-n count] [-l size] [-w timeout] target\n" );
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
    DWORD count = DEFAULT_COUNT;
    DWORD dataSize = DEFAULT_DATA_SIZE;
    DWORD timeout = DEFAULT_TIMEOUT;
    DWORD i;
    DWORD sent = 0, received = 0;
    PCHAR sendBuffer;
    PVOID replyBuffer;
    DWORD replySize;
    PICMP_ECHO_REPLY reply;

    //
    // Parse the command line.
    //

    for ( i = 1; i < (DWORD)argc; i++ ) {
        if ( argv[i][0] == '-' ) {
            switch ( argv[i][1] ) {
            case 'n':
                if ( ++i < (DWORD)argc ) count = atoi( argv[i] );
                break;
            case 'l':
                if ( ++i < (DWORD)argc ) dataSize = atoi( argv[i] );
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

    if ( dataSize > MAX_DATA_SIZE ) {
        dataSize = MAX_DATA_SIZE;
    }

    //
    // Winsock is needed only for name/address resolution.
    //

    if ( WSAStartup( 0x0101, &wsaData ) != 0 ) {
        printf( "ping: unable to initialize Windows Sockets.\n" );
        return 1;
    }

    //
    // Resolve the target: try dotted-decimal first, then a host name.
    //

    address = inet_addr( target );
    if ( address == INADDR_NONE ) {
        host = gethostbyname( target );
        if ( host == NULL ) {
            printf( "ping: cannot resolve %s: unknown host\n", target );
            WSACleanup();
            return 1;
        }
        address = *(IPAddr *)host->h_addr;
    }

    icmpHandle = IcmpCreateFile();
    if ( icmpHandle == INVALID_HANDLE_VALUE ) {
        printf( "ping: unable to open ICMP handle (error %lu)\n",
                GetLastError() );
        WSACleanup();
        return 1;
    }

    //
    // Allocate the echo data (filled with a repeating pattern) and a reply
    // buffer big enough for one reply plus the echoed data.
    //

    sendBuffer = LocalAlloc( LPTR, dataSize );
    replySize = sizeof(ICMP_ECHO_REPLY) + dataSize + 8;
    replyBuffer = LocalAlloc( LPTR, replySize );
    if ( sendBuffer == NULL || replyBuffer == NULL ) {
        printf( "ping: out of memory\n" );
        IcmpCloseHandle( icmpHandle );
        WSACleanup();
        return 1;
    }
    for ( i = 0; i < dataSize; i++ ) {
        sendBuffer[i] = (CHAR)( 'a' + ( i % 23 ) );
    }

    printf( "\nPinging " );
    PrintAddress( address );
    printf( " with %lu bytes of data:\n\n", dataSize );

    for ( i = 0; i < count; i++ ) {

        DWORD replies;

        sent++;

        replies = IcmpSendEcho(
                      icmpHandle,
                      address,
                      sendBuffer,
                      (WORD)dataSize,
                      NULL,
                      replyBuffer,
                      replySize,
                      timeout
                      );

        if ( replies == 0 ) {
            DWORD error = GetLastError();
            if ( error == IP_REQ_TIMED_OUT ) {
                printf( "Request timed out.\n" );
            } else {
                printf( "PING: transmit failed (error %lu).\n", error );
            }
        } else {
            reply = (PICMP_ECHO_REPLY)replyBuffer;
            if ( reply->Status == IP_SUCCESS ) {
                received++;
                printf( "Reply from " );
                PrintAddress( reply->Address );
                printf( ": bytes=%u ", reply->DataSize );
                if ( reply->RoundTripTime == 0 ) {
                    printf( "time<10ms " );
                } else {
                    printf( "time=%lums ", reply->RoundTripTime );
                }
                printf( "TTL=%u\n", reply->Options.Ttl );
            } else {
                printf( "Reply from " );
                PrintAddress( reply->Address );
                printf( ": status %lu\n", reply->Status );
            }
        }

        //
        // Pause a second between pings, but not after the last one.
        //

        if ( i + 1 < count ) {
            Sleep( 1000 );
        }
    }

    printf( "\nPing statistics for " );
    PrintAddress( address );
    printf( ":\n    Packets: Sent = %lu, Received = %lu, Lost = %lu (%lu%% loss)\n",
            sent, received, sent - received,
            sent ? ( ( sent - received ) * 100 / sent ) : 0 );

    IcmpCloseHandle( icmpHandle );
    WSACleanup();

    return ( received > 0 ) ? 0 : 1;
}
