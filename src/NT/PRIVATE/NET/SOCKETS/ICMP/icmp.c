/*++

Copyright (c) 1993 Microsoft Corporation

Module Name:

    icmp.c

Abstract:

    Implements the NT ICMP Echo request API (icmpapi.h): IcmpCreateFile,
    IcmpCloseHandle, IcmpSendEcho.  Ping and other tools use these to issue
    ICMP echo requests without a raw socket.

    icmp.dll shipped only as a binary in the NT 3.5 leak, so this is a
    reimplementation against the interface the TCP/IP stack already
    exposes: it opens \Device\Ip and drives IOCTL_ICMP_ECHO_REQUEST, which
    the IP driver (NTOS/TDI/TCPIP/IP/NTIRP.C) already implements.

--*/

#include <nt.h>
#include <ntrtl.h>
#include <nturtl.h>

#include <windows.h>

#include <ipexport.h>
#include <icmpapi.h>
#include <ntddip.h>


HANDLE
WINAPI
IcmpCreateFile(
    VOID
    )

/*++

Routine Description:

    Opens a handle on \Device\Ip on which ICMP echo requests can be issued.

--*/

{
    NTSTATUS status;
    HANDLE handle;
    UNICODE_STRING deviceName;
    OBJECT_ATTRIBUTES objectAttributes;
    IO_STATUS_BLOCK ioStatusBlock;

    RtlInitUnicodeString( &deviceName, DD_IP_DEVICE_NAME );

    InitializeObjectAttributes(
        &objectAttributes,
        &deviceName,
        OBJ_CASE_INSENSITIVE,
        NULL,
        NULL
        );

    status = NtCreateFile(
                 &handle,
                 GENERIC_READ | GENERIC_WRITE | SYNCHRONIZE,
                 &objectAttributes,
                 &ioStatusBlock,
                 NULL,                                 // AllocationSize
                 0L,                                   // FileAttributes
                 FILE_SHARE_READ | FILE_SHARE_WRITE,   // ShareAccess
                 FILE_OPEN_IF,                         // CreateDisposition
                 FILE_SYNCHRONOUS_IO_NONALERT,         // CreateOptions
                 NULL,
                 0
                 );
    if ( !NT_SUCCESS(status) ) {
        SetLastError( RtlNtStatusToDosError( status ) );
        return INVALID_HANDLE_VALUE;
    }

    return handle;

} // IcmpCreateFile


BOOL
WINAPI
IcmpCloseHandle(
    HANDLE IcmpHandle
    )

/*++

Routine Description:

    Closes a handle opened by IcmpCreateFile.

--*/

{
    return CloseHandle( IcmpHandle );

} // IcmpCloseHandle


DWORD
WINAPI
IcmpSendEcho(
    HANDLE                   IcmpHandle,
    IPAddr                   DestinationAddress,
    LPVOID                   RequestData,
    WORD                     RequestSize,
    PIP_OPTION_INFORMATION   RequestOptions,
    LPVOID                   ReplyBuffer,
    DWORD                    ReplySize,
    DWORD                    Timeout
    )

/*++

Routine Description:

    Sends an ICMP echo request and returns any replies.  Builds the
    ICMP_ECHO_REQUEST the IP driver expects (struct + optional IP options +
    echo data), drives IOCTL_ICMP_ECHO_REQUEST, then relocates the offsets
    the driver stored in the returned ICMP_ECHO_REPLY back into pointers.

Return Value:

    The number of replies stored in ReplyBuffer, or 0 on failure (with
    extended error via GetLastError()).

--*/

{
    PICMP_ECHO_REQUEST request;
    DWORD requestSize;
    DWORD bytesReturned;
    DWORD numReplies;
    PICMP_ECHO_REPLY reply;
    DWORD i;
    BOOL ok;
    UCHAR optionsSize;

    optionsSize = ( RequestOptions != NULL ) ? RequestOptions->OptionsSize : 0;

    //
    // The IP driver takes a single input buffer holding the request struct
    // followed by the IP options (if any) and then the echo data.
    //

    requestSize = sizeof(ICMP_ECHO_REQUEST) + optionsSize + RequestSize;

    request = LocalAlloc( LPTR, requestSize );
    if ( request == NULL ) {
        SetLastError( ERROR_NOT_ENOUGH_MEMORY );
        return 0;
    }

    request->Address = DestinationAddress;
    request->Timeout = Timeout;
    request->DataSize = RequestSize;
    request->DataOffset = (USHORT)( sizeof(ICMP_ECHO_REQUEST) + optionsSize );

    if ( RequestOptions != NULL ) {
        request->OptionsValid = 1;
        request->Ttl = RequestOptions->Ttl;
        request->Tos = RequestOptions->Tos;
        request->Flags = RequestOptions->Flags;
        request->OptionsSize = optionsSize;
        request->OptionsOffset =
            ( optionsSize > 0 ) ? (USHORT)sizeof(ICMP_ECHO_REQUEST) : 0;
        if ( optionsSize > 0 ) {
            RtlCopyMemory(
                (PUCHAR)request + request->OptionsOffset,
                RequestOptions->OptionsData,
                optionsSize
                );
        }
    } else {
        request->OptionsValid = 0;
        request->Ttl = 0;
        request->Tos = 0;
        request->Flags = 0;
        request->OptionsSize = 0;
        request->OptionsOffset = 0;
    }

    if ( RequestSize > 0 ) {
        RtlCopyMemory(
            (PUCHAR)request + request->DataOffset,
            RequestData,
            RequestSize
            );
    }

    ok = DeviceIoControl(
             IcmpHandle,
             IOCTL_ICMP_ECHO_REQUEST,
             request,
             requestSize,
             ReplyBuffer,
             ReplySize,
             &bytesReturned,
             NULL
             );

    LocalFree( request );

    if ( !ok ) {
        return 0;
    }

    //
    // The driver stores the reply count in the first reply's Reserved
    // field.  Zero means no reply (timeout / unreachable); the reason is
    // in the reply's Status field.
    //

    reply = (PICMP_ECHO_REPLY)ReplyBuffer;
    numReplies = reply->Reserved;

    if ( numReplies == 0 ) {
        SetLastError( reply->Status );
        return 0;
    }

    //
    // The driver hands back Data / OptionsData as offsets relative to the
    // reply buffer base; turn them into absolute pointers for the caller.
    //

    for ( i = 0; i < numReplies; i++ ) {
        if ( reply[i].Data != NULL ) {
            reply[i].Data =
                (PCHAR)ReplyBuffer + (ULONG)reply[i].Data;
        }
        if ( reply[i].Options.OptionsData != NULL ) {
            reply[i].Options.OptionsData =
                (PUCHAR)ReplyBuffer + (ULONG)reply[i].Options.OptionsData;
        }
    }

    return numReplies;

} // IcmpSendEcho
