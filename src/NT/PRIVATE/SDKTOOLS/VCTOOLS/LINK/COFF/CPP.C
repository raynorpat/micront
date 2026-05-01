/*++

Copyright (c) 1989  Microsoft Corporation

Module Name:

    cpp.c

Abstract:

    C++ specific support for Link32

--*/

#include "shared.h"

/* MicroNT: always use the in-tree unDName demangler (HUNDNAME.CXX
 * compiled into LINK.EXE) instead of imagehlp.dll's
 * UnDecorateSymbolName.  This drops LINK.EXE's only IMAGEHLP.dll
 * import — the rest of the file is name-mangling for diagnostic
 * pretty-printing, fully covered by the static implementation.
 *
 * Define unconditionally rather than removing -DNT_BUILD globally
 * (NT_BUILD gates other behaviours in COFF.C / LIB.C / etc. we want
 * to keep). */
#define M_I386 1
#define _loadds
#include "undname.h"

PUCHAR
SzOutputSymbolName(
    PUCHAR szIn,
    BOOL fDnameAlso
    )
{
    PUCHAR szDname;
    BOOL fImport;
    /* MicroNT: always use the local unDName (in-tree HUNDNAME.CXX). */
    PUCHAR szUndecorated;
    size_t cchOut;
    PUCHAR szOut;

#define szDeclspec "__declspec(dllimport) "

    szDname = szIn;

    fImport = strncmp(szDname, "__imp_", 6) == 0;
    if (fImport) {
        szDname += 6;
    }

    if (szDname[0] != '?') {
        return(szIn);
    }

    szUndecorated = unDName(NULL, szDname, 0,
#ifdef  _INC_DMALLOC
                            (Alloc_t) D_malloc, (Free_t) D_free,
#else   /* !_INC_DMALLOC */
                            (Alloc_t) malloc, (Free_t) free,
#endif  /* !_INC_DMALLOC */
                            UNDNAME_32_BIT_DECODE);

    if (szUndecorated == NULL) {
        // Undecorator failed

        return(szIn);
    }

    // Alloc: '(', undname, ')', '\0'

    cchOut = strlen(szUndecorated) + 3;

    if (fImport) {
        // Prefix "__declspec(dllimport) " to the undecorated name

        cchOut += strlen(szDeclspec);
    }

    if (fDnameAlso) {
        // Alloc: [dname (with space)], '(', undname, ')', '\0'

        cchOut += strlen(szIn) + 1;
    }

    szOut = (PUCHAR) PvAlloc(cchOut);

    if (fDnameAlso) {
        strcpy(szOut, szIn);
        strcat(szOut, " ");
    } else {
        szOut[0] = '\0';
    }

    strcat(szOut, "(");

    if (fImport) {
        strcat(szOut, szDeclspec);
    }

    strcat(szOut, szUndecorated);
    strcat(szOut, ")");

    /* MicroNT: unDName allocates szUndecorated via the passed Alloc_t
     * (malloc) — must free unconditionally now that the imagehlp
     * (caller-buffer) path is gone.  Original code had this under
     * #ifndef NT_BUILD; we drop the guard. */
    free(szUndecorated);

    return(szOut);
}
