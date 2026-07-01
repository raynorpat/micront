/*++

Copyright (c) 1991-1994 Microsoft Corporation

Module Name:

    xsstub.c

Abstract:

    Stubs for the downlevel (LanMan / OS2 RAP) transaction server entry
    points that srvsvc's startup (ssinit.c) calls.

    MicroNT does not build the downlevel "transaction server" (xactsrv) and
    its RPCXLATE / browser subsystem — the Server service still serves shares
    to modern SMB clients over RPC, but it does not remote the legacy RAP
    admin API to downlevel (OS/2 / LAN Manager) clients.  The real
    implementations live in xsinit.c / xsproc.c / xsdata.c, which link
    against xactsrv.lib; these no-op stubs let ssinit.c link without it.

    XsStartXactsrv is only invoked when sv599_acceptdownlevelapis is set,
    which MicroNT leaves off, so these are never reached at run time.

--*/

#include "srvsvcp.h"


DWORD
XsStartXactsrv (
    VOID
    )
{
    return NO_ERROR;
}


VOID
XsStopXactsrv (
    VOID
    )
{
}
