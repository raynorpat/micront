/*++

Module Name:

    resolver.c

Abstract:

    Winsock resolver surface: gethostby*, getprotoby*, getservby*, gethostname.

    Resolution strategy:
      - gethostbyname: inet_addr first (numeric IP), then \SystemRoot\System32\hosts
      - gethostbyaddr: reverse lookup in hosts, fallback to dotted-decimal
      - gethostname:   returns "micront"
      - getprotobynumber/getprotobyname: small hardcoded table
      - getservbyname/getservbyport:     small hardcoded table

    Return values point to static per-call storage (not thread-safe, matching
    historic wsock32 behaviour; callers must copy before calling again).

--*/

#include "winsockp.h"

/* ------------------------------------------------------------------ */
/*  Static per-call storage                                             */
/* ------------------------------------------------------------------ */

static char     gs_hname[256];
static char     gs_addr[4];
static char    *gs_addrlist[2]  = { gs_addr, NULL };
static char    *gs_aliases0[1]  = { NULL };
static HOSTENT  gs_hostent = { gs_hname, gs_aliases0, AF_INET, 4, gs_addrlist };

static PROTOENT gs_protoent;
static char     gs_pname[32];
static char    *gs_paliases[1] = { NULL };

static SERVENT  gs_servent;
static char     gs_sname[32];
static char     gs_sproto[8];
static char    *gs_saliases[1] = { NULL };


/* ------------------------------------------------------------------ */
/*  Hosts file                                                          */
/* ------------------------------------------------------------------ */

/*
 * Read \SystemRoot\System32\hosts into Buf (at most BufLen-1 bytes).
 * Returns bytes read; 0 if not found or unreadable.
 */
static ULONG
ReadHostsFile (
    PCHAR  Buf,
    ULONG  BufLen
    )
{
    UNICODE_STRING     Path;
    OBJECT_ATTRIBUTES  Oa;
    IO_STATUS_BLOCK    Iosb;
    HANDLE             Fh;
    NTSTATUS           St;

    RtlInitUnicodeString( &Path, L"\\SystemRoot\\System32\\hosts" );
    InitializeObjectAttributes( &Oa, &Path, OBJ_CASE_INSENSITIVE, NULL, NULL );

    St = NtCreateFile( &Fh,
                       FILE_READ_DATA | SYNCHRONIZE,
                       &Oa, &Iosb,
                       NULL, FILE_ATTRIBUTE_NORMAL,
                       FILE_SHARE_READ,
                       FILE_OPEN,
                       FILE_SYNCHRONOUS_IO_NONALERT | FILE_NON_DIRECTORY_FILE,
                       NULL, 0 );
    if ( !NT_SUCCESS( St ) ) {
        return 0;
    }

    St = NtReadFile( Fh, NULL, NULL, NULL, &Iosb,
                     Buf, BufLen - 1, NULL, NULL );
    NtClose( Fh );

    if ( !NT_SUCCESS( St ) && St != STATUS_END_OF_FILE ) {
        return 0;
    }
    Buf[ Iosb.Information ] = '\0';
    return (ULONG)Iosb.Information;
}

/*
 * Walk the hosts buffer, matching either by name or by dotted-decimal
 * address string.  Fills gs_hostent on success.
 */
static PHOSTENT
HostsLookup (
    PCHAR    Buf,
    ULONG    Len,
    PCHAR    Query,
    BOOLEAN  ByAddr      /* TRUE = match IP column, FALSE = match name column */
    )
{
    PCHAR p   = Buf;
    PCHAR end = Buf + Len;

    while ( p < end ) {
        char  line[512];
        int   llen;
        PCHAR lend, tok, ip, host;
        ULONG bin_addr;

        /* Isolate one line */
        lend = p;
        while ( lend < end && *lend != '\n' && *lend != '\r' )
            lend++;
        llen = (int)( lend - p );
        if ( llen > 511 ) llen = 511;
        RtlCopyMemory( line, p, llen );
        line[llen] = '\0';
        p = lend;
        while ( p < end && (*p == '\n' || *p == '\r') )
            p++;

        /* Strip comment */
        tok = line;
        while ( *tok && *tok != '#' ) tok++;
        *tok = '\0';

        /* Parse IP token */
        tok = line;
        while ( *tok == ' ' || *tok == '\t' ) tok++;
        if ( !*tok ) continue;
        ip = tok;
        while ( *tok && *tok != ' ' && *tok != '\t' ) tok++;
        if ( !*tok ) continue;
        *tok++ = '\0';

        /* Parse hostname token */
        while ( *tok == ' ' || *tok == '\t' ) tok++;
        if ( !*tok ) continue;
        host = tok;
        while ( *tok && *tok != ' ' && *tok != '\t' ) tok++;
        *tok = '\0';

        /* Resolve IP text → binary for later use */
        bin_addr = inet_addr( ip );
        if ( bin_addr == INADDR_NONE ) continue;

        /* Match */
        if ( ByAddr ) {
            if ( _stricmp( ip, Query ) != 0 ) continue;
            strncpy( gs_hname, host, sizeof(gs_hname) - 1 );
        } else {
            if ( _stricmp( host, Query ) != 0 ) continue;
            strncpy( gs_hname, host, sizeof(gs_hname) - 1 );
        }
        gs_hname[ sizeof(gs_hname) - 1 ] = '\0';
        RtlCopyMemory( gs_addr, &bin_addr, 4 );
        return &gs_hostent;
    }
    return NULL;
}

/* Format a binary IPv4 address as dotted-decimal into Buf (≥16 bytes). */
static VOID
FormatIP4 (
    PCHAR  Buf,
    ULONG  Addr
    )
{
    PUCHAR b = (PUCHAR)&Addr;
    int    i;
    PCHAR  p = Buf;

    for ( i = 0; i < 4; i++ ) {
        int n = b[i];
        if ( n >= 100 ) { *p++ = (char)('0' + n / 100); n %= 100; }
        if ( n >=  10 ) { *p++ = (char)('0' + n /  10); n %=  10; }
        *p++ = (char)('0' + n);
        if ( i < 3 ) *p++ = '.';
    }
    *p = '\0';
}


/* ------------------------------------------------------------------ */
/*  Exported resolver functions                                         */
/* ------------------------------------------------------------------ */

PHOSTENT PASCAL
gethostbyname (
    const char *Name
    )
{
    ULONG    addr;
    char     buf[8192];
    ULONG    len;
    PHOSTENT he;

    if ( !SockEnterApi( FALSE, TRUE, FALSE ) ) {
        return NULL;
    }

    /* Numeric IP string: no file lookup needed */
    if ( Name && *Name ) {
        addr = inet_addr( Name );
        if ( addr != INADDR_NONE ) {
            strncpy( gs_hname, Name, sizeof(gs_hname) - 1 );
            gs_hname[ sizeof(gs_hname) - 1 ] = '\0';
            RtlCopyMemory( gs_addr, &addr, 4 );
                    return &gs_hostent;
        }
    }

    /* Hosts-file lookup */
    len = ReadHostsFile( buf, sizeof(buf) );
    if ( len ) {
        he = HostsLookup( buf, len, (PCHAR)Name, FALSE );
        if ( he ) {
                    return he;
        }
    }

    SetLastError( WSAHOST_NOT_FOUND );
    return NULL;
}

PHOSTENT PASCAL
gethostbyaddr (
    const char *Addr,
    int         Len,
    int         Type
    )
{
    ULONG  bin_addr;
    char   ip_str[20];
    char   buf[8192];
    ULONG  file_len;
    PHOSTENT he;

    if ( !SockEnterApi( FALSE, TRUE, FALSE ) ) {
        return NULL;
    }

    if ( !Addr || Len < 4 || Type != AF_INET ) {
        SetLastError( WSAEINVAL );
            return NULL;
    }

    RtlCopyMemory( &bin_addr, Addr, 4 );
    RtlCopyMemory( gs_addr,   Addr, 4 );
    FormatIP4( ip_str, bin_addr );

    /* Hosts-file reverse lookup */
    file_len = ReadHostsFile( buf, sizeof(buf) );
    if ( file_len ) {
        he = HostsLookup( buf, file_len, ip_str, TRUE );
        if ( he ) {
                    return he;
        }
    }

    /* Fallback: return the dotted-decimal as the name */
    strncpy( gs_hname, ip_str, sizeof(gs_hname) - 1 );
    gs_hname[ sizeof(gs_hname) - 1 ] = '\0';
    return &gs_hostent;
}

int PASCAL
gethostname (
    char *Name,
    int   NameLen
    )
{
    static const char LocalName[] = "micront";

    if ( !SockEnterApi( FALSE, TRUE, FALSE ) ) {
        return SOCKET_ERROR;
    }

    if ( !Name || NameLen < (int)sizeof(LocalName) ) {
        SetLastError( WSAEFAULT );
            return SOCKET_ERROR;
    }
    RtlCopyMemory( Name, LocalName, sizeof(LocalName) );
    return 0;
}


/* ------------------------------------------------------------------ */
/*  Protocol table                                                      */
/* ------------------------------------------------------------------ */

static const struct { const char *name; short proto; } ProtoMap[] = {
    { "ip",   IPPROTO_IP   },
    { "icmp", IPPROTO_ICMP },
    { "tcp",  IPPROTO_TCP  },
    { "udp",  IPPROTO_UDP  },
    { "raw",  IPPROTO_RAW  },
};
#define PROTO_COUNT (sizeof(ProtoMap)/sizeof(ProtoMap[0]))

PPROTOENT PASCAL
getprotobyname (
    const char *Name
    )
{
    ULONG i;
    for ( i = 0; i < PROTO_COUNT; i++ ) {
        if ( _stricmp( Name, ProtoMap[i].name ) != 0 ) continue;
        strncpy( gs_pname, ProtoMap[i].name, sizeof(gs_pname) - 1 );
        gs_pname[ sizeof(gs_pname) - 1 ] = '\0';
        gs_protoent.p_name    = gs_pname;
        gs_protoent.p_aliases = gs_paliases;
        gs_protoent.p_proto   = ProtoMap[i].proto;
        return &gs_protoent;
    }
    SetLastError( WSANO_DATA );
    return NULL;
}

PPROTOENT PASCAL
getprotobynumber (
    int Proto
    )
{
    ULONG i;
    for ( i = 0; i < PROTO_COUNT; i++ ) {
        if ( ProtoMap[i].proto != (short)Proto ) continue;
        strncpy( gs_pname, ProtoMap[i].name, sizeof(gs_pname) - 1 );
        gs_pname[ sizeof(gs_pname) - 1 ] = '\0';
        gs_protoent.p_name    = gs_pname;
        gs_protoent.p_aliases = gs_paliases;
        gs_protoent.p_proto   = (short)Proto;
        return &gs_protoent;
    }
    SetLastError( WSANO_DATA );
    return NULL;
}


/* ------------------------------------------------------------------ */
/*  Service table                                                       */
/* ------------------------------------------------------------------ */

static const struct { const char *name; const char *proto; short port; } ServMap[] = {
    { "echo",   "tcp",   7  },
    { "echo",   "udp",   7  },
    { "ftp",    "tcp",   21 },
    { "ssh",    "tcp",   22 },
    { "telnet", "tcp",   23 },
    { "smtp",   "tcp",   25 },
    { "http",   "tcp",   80 },
    { "pop3",   "tcp",  110 },
    { "imap",   "tcp",  143 },
    { "https",  "tcp",  443 },
};
#define SERV_COUNT (sizeof(ServMap)/sizeof(ServMap[0]))

PSERVENT PASCAL
getservbyname (
    const char *Name,
    const char *Proto
    )
{
    ULONG i;
    for ( i = 0; i < SERV_COUNT; i++ ) {
        if ( _stricmp( Name, ServMap[i].name ) != 0 ) continue;
        if ( Proto && _stricmp( Proto, ServMap[i].proto ) != 0 ) continue;
        strncpy( gs_sname,  ServMap[i].name,  sizeof(gs_sname)  - 1 );
        strncpy( gs_sproto, ServMap[i].proto, sizeof(gs_sproto) - 1 );
        gs_servent.s_name    = gs_sname;
        gs_servent.s_aliases = gs_saliases;
        gs_servent.s_port    = htons( (u_short)ServMap[i].port );
        gs_servent.s_proto   = gs_sproto;
        return &gs_servent;
    }
    SetLastError( WSANO_DATA );
    return NULL;
}

PSERVENT PASCAL
getservbyport (
    int         Port,
    const char *Proto
    )
{
    int   host_port = (int)ntohs( (u_short)Port );
    ULONG i;
    for ( i = 0; i < SERV_COUNT; i++ ) {
        if ( ServMap[i].port != (short)host_port ) continue;
        if ( Proto && _stricmp( Proto, ServMap[i].proto ) != 0 ) continue;
        strncpy( gs_sname,  ServMap[i].name,  sizeof(gs_sname)  - 1 );
        strncpy( gs_sproto, ServMap[i].proto, sizeof(gs_sproto) - 1 );
        gs_servent.s_name    = gs_sname;
        gs_servent.s_aliases = gs_saliases;
        gs_servent.s_port    = (short)Port;
        gs_servent.s_proto   = gs_sproto;
        return &gs_servent;
    }
    SetLastError( WSANO_DATA );
    return NULL;
}
