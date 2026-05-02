/*++

Copyright (c) 1989-1993  Microsoft Corporation

Module Name:

    errnsg.c

Abstract:

    Contained the linkers global error messages.
    Now it uses a separate text file.
    It may be replaced by a string resource at a later date.

Author:

    Mike O'Leary (mikeol) 01-Dec-1989

Revision History:

    15-Oct-1992 AzeemK  Added new warning for obsolete switches.
    10-Sep-1992 AzeemK  Added new error for bug fix 1060.
    09-Sep-1992 AzeemK  Changed all writes to stdout. Fix 604.
    29-Jul-1992 GeoffS  Added BADSTUBFILE error

--*/


#include "shared.h"

#include <stdarg.h>



#define MAX_MSG_LENGTH 256

static char ErrMsgBuf[MAX_MSG_LENGTH];

static FILE *pErrorFile;

/* Table of offsets into error file */
static long ErrorTable[LAST_MSG + 1];

/* Mapping of internal to External error Codes */
static const WORD InternalToExternal[LAST_MSG + 1] = {
#include "errdat.h"
};

/* Table of messages disabled by /WARNING directive */
static char WarningDisabled[LAST_MSG + 1];


#if defined(NT_BUILD)

/*
 * MicroNT: stock NT_BUILD path called LoadLibrary("USER32") +
 * GetProcAddress("LoadStringA") at first use, ignored both return
 * values, and called through the resulting (potentially NULL)
 * function pointer.  On a system without USER32 (which we don't
 * ship — too much csrss-coupling) that's a guaranteed AV the moment
 * LINK reports any error.
 *
 * Replace it with a 30-line inline LoadStringA against kernel32's
 * resource APIs (FindResourceA / LoadResource / LockResource /
 * SizeofResource).  String resources are stored as 16-string blocks
 * keyed by ((id >> 4) + 1); each entry is a USHORT length followed
 * by `length` UTF-16 wchars (no NUL terminator).  We index into
 * the block at (id & 0xF) and copy the chosen string out as ANSI.
 *
 * On any failure (resource missing, conversion fails, block under-
 * runs) GetErrorFormatString falls back to a generic format that
 * still includes the error number — better than returning NULL and
 * crashing the caller's printf.
 */
static const char *FallbackErrorFormat(unsigned errInt)
{
    static char fallbackBuf[64];
    sprintf(fallbackBuf, "LNK%u: (error message resource missing)", errInt);
    return fallbackBuf;
}

static int MyLoadStringA(UINT id, LPSTR ansiOut, int cchMax)
{
    HRSRC    hRes;
    HGLOBAL  hGlob;
    LPCWSTR  pBlock;
    DWORD    cbBlock;
    UINT     blockId   = (id >> 4) + 1;
    UINT     subIndex  = id & 0xF;
    UINT     i;
    USHORT   cwch;

    if (cchMax <= 0) return 0;
    ansiOut[0] = 0;

    hRes = FindResourceA(NULL, MAKEINTRESOURCE(blockId), RT_STRING);
    if (hRes == NULL) return 0;
    hGlob = LoadResource(NULL, hRes);
    if (hGlob == NULL) return 0;
    pBlock = (LPCWSTR)LockResource(hGlob);
    if (pBlock == NULL) return 0;
    cbBlock = SizeofResource(NULL, hRes);

    /* Walk the block: 16 entries each `USHORT len + len wchars`. */
    for (i = 0; i < subIndex; i++) {
        if ((PUCHAR)(pBlock + 1) > (PUCHAR)pBlock + cbBlock) return 0;
        cwch    = *pBlock++;
        pBlock += cwch;
    }
    if ((PUCHAR)(pBlock + 1) > (PUCHAR)pBlock + cbBlock) return 0;
    cwch = *pBlock++;
    if (cwch == 0) return 0;

    /* UTF-16 → ANSI lossy-cast.  WideCharToMultiByte / CP_ACP are
     * declared in <winnls.h>, but SHARED.H sets WIN32_LEAN_AND_MEAN
     * AND `#define NONLS`, and winnls.h's declarations are wrapped
     * in `#ifndef NONLS` — so the symbols are unreachable from any
     * source file that includes shared.h.  An `#undef NONLS` +
     * explicit `#include <winnls.h>` doesn't help either: by the
     * time we get there, windows.h has already visited winnls.h
     * with NONLS active and latched its header guard, so the second
     * include is a no-op.
     *
     * LINK's error strings are pure ASCII English, so high-byte
     * truncation is the correct ANSI conversion here.  Non-ASCII
     * input (which we don't have) would garble visually but never
     * crash. */
    {
        int copy = (int)cwch < cchMax - 1 ? (int)cwch : cchMax - 1;
        int j;
        for (j = 0; j < copy; j++) {
            ansiOut[j] = (char)pBlock[j];
        }
        ansiOut[copy] = 0;
        return copy;
    }
}

#endif // defined(NT_BUILD)

const char *GetErrorFormatString(unsigned errInt)
{
#if defined(NT_BUILD)

    int n = MyLoadStringA(errInt, ErrMsgBuf, MAX_MSG_LENGTH);
    if (n <= 0) {
        return FallbackErrorFormat(errInt);
    }
    ErrMsgBuf[n < MAX_MSG_LENGTH ? n : MAX_MSG_LENGTH - 1] = 0;
    return ErrMsgBuf;

#else // defined(NT_BUILD)

    static BOOL fInitialized;
    char        *pLine;
    int         i = 0;

    if (!fInitialized) {
        char szDir[_MAX_DIR];
        char szDrive[_MAX_DRIVE];
        char szLinkErrPath[_MAX_PATH];

        fInitialized = TRUE;

        // Look for LINK.ERR in this the directory from which we were loaded

        _splitpath(_pgmptr, szDrive, szDir, NULL, NULL);
        _makepath(szLinkErrPath, szDrive, szDir, "link", ".err");

        // UNDONE: Opening the file here might be a problem for out of mem.

        pErrorFile = fopen(szLinkErrPath, "rt");

        if (pErrorFile == NULL) {
            printf("%s : warning: file not found \"%s\"\n",
                   ToolName, szLinkErrPath);
        }

        // pErrorFile is NULL if no error messages available

        if (pErrorFile) {
            long offset;

            offset = ftell(pErrorFile);

            while (pLine = fgets(ErrMsgBuf, MAX_MSG_LENGTH, pErrorFile)) {
                ErrorTable[i++] = offset;
                offset = ftell(pErrorFile);
            }
        }
    }

    if (pErrorFile == NULL) {
        return(NULL);
    }

    fseek(pErrorFile, ErrorTable[errInt], SEEK_SET);

    pLine = fgets(ErrMsgBuf, MAX_MSG_LENGTH, pErrorFile);

    // UNDONE: This is ugly, fgets isn't quite what we want.

    i = strlen(pLine);
    if (i) {
        pLine[i - 1] = '\0';
    }

    // Skip up to ":"

    pLine = strchr(pLine, ':') + 1;

    return(pLine);

#endif // defined(NT_BUILD)
}


unsigned GetExternalErrorCode(unsigned errInt)
{
    return InternalToExternal[errInt];
}


VOID DisableWarning(unsigned errExt)
{
    unsigned errInt;

    for (errInt = 0; errInt <= LAST_MSG; errInt++) {
        if (errExt == InternalToExternal[errInt]) {
            WarningDisabled[errInt] = TRUE;
            break;
        }
    }
}


BOOL FIgnoreWarning(unsigned errInt)
{
    if (errInt > LAST_MSG) {
        return 1;
    }

    return((BOOL) WarningDisabled[errInt]);
}


#if 0

void FinalizeErrorFile(void)
{
    if (pErrorFile != NULL) {
        fclose(pErrorFile);
    }
}

#endif


void DisplayMessage(const char *szFilename, UINT Prefix, UINT Message, va_list valist)
{
    const char *szFormat;

    if (FIgnoreWarning(Message)) {
        return;
    }

    if (fNeedBanner) {
        PrintBanner();
    }

    fflush(NULL);

    if (szFilename == NULL) {
        szFilename = ToolName;
    }

    if (Prefix != MSGSTR) {
        printf("%s :", szFilename);
    }

    if ((Prefix != NOTESTR) && (Prefix != MSGSTR)) {
        const char *szPrefix;

        szPrefix = GetErrorFormatString(Prefix);

        if (szPrefix) {
            printf("%s", szPrefix);
        }
    }

    if ((Message != ILINKSUCCESS) && (Message != ILINKNOCHNG) && (Prefix != MSGSTR)) {
        printf(" LNK%04u:", GetExternalErrorCode(Message));
    }

    szFormat = GetErrorFormatString(Message);
    if (szFormat) {
        vprintf(szFormat, valist);
    }

    fputc('\n', stdout);
    fflush(stdout);
}

void __cdecl Message(UINT MsgNumber, ...)

/*++

Routine Description:

    Prints a user message.

Arguments:

    MsgNumber - Internal code on message.

Return Value:

    None.

--*/

{
    va_list valist;

    va_start(valist, MsgNumber);

    DisplayMessage(NULL, MSGSTR, MsgNumber, valist);

    va_end(valist);
}

void __cdecl PostNote(const char *szFilename, UINT NoteNumber, ...)

/*++

Routine Description:

    Prints a note user.

Arguments:

    szFilename - File which caused the warning.

    NoteNumber - Internal code on note.

Return Value:

    None.

--*/

{
    va_list valist;

    va_start(valist, NoteNumber);

    DisplayMessage(szFilename, NOTESTR, NoteNumber, valist);

    va_end(valist);
}


void __cdecl Warning(const char *szFilename, UINT WarningNumber, ...)

/*++

Routine Description:

    Prints a warning message.

Arguments:

    Filename - File which caused the warning.

    WarningNumber - Internal error code.

Return Value:

    None.

--*/

{
    va_list valist;

    va_start(valist, WarningNumber);

    DisplayMessage(szFilename, WARNSTR, WarningNumber, valist);

    va_end(valist);
}


void __cdecl WarningPcon(PCON pcon, UINT WarningNumber, ...)
{
    va_list valist;
    UCHAR szComFileName[MAXFILENAMELEN * 2];

    va_start(valist, WarningNumber);

    SzComNamePMOD(PmodPCON(pcon), szComFileName);

    DisplayMessage(szComFileName, WARNSTR, WarningNumber, valist);

    va_end(valist);
}


void __cdecl ErrorContinue(const char *szFilename, UINT ErrorNumber, ...)
/*++

Routine Description:

    Prints an error message, closes all open files, and exits with
    an error number. The error number is the index used to lookup
    the error string.

Arguments:

    szFilename - File which caused the error.

    ErrorNumber - An index into the ErrorInfo structure.

Return Value:

    Exits the program.

--*/

{
    va_list valist;

    va_start(valist, ErrorNumber);

    DisplayMessage(szFilename, ERRORSTR, ErrorNumber, valist);
    
    va_end(valist);

    cError++;
}


void __cdecl ErrorContinuePcon(PCON pcon, UINT ErrorNumber, ...)
{
    va_list valist;
    UCHAR szComFileName[MAXFILENAMELEN * 2];

    va_start(valist, ErrorNumber);

    SzComNamePMOD(PmodPCON(pcon), szComFileName);

    DisplayMessage(szComFileName, ERRORSTR, ErrorNumber, valist);

    va_end(valist);

    cError++;
}


void DisplayError(const char *szFilename, UINT ErrorNumber, va_list valist)
{
    static BOOL fErr;

    if (!fErr) {
        fErr = TRUE;

        DisplayMessage(szFilename, ERRORSTR, ErrorNumber, valist);

        FileCloseAll();
        RemoveConvertTempFiles();

        if (OutFilename != NULL && OutFilename[0] != '\0') {
            _unlink(OutFilename);
        }

        // in the incr case just blow away inc db which will
        // be in an invalid state (.ixe is corrupt - hit an error)
        if (fINCR && !_access(szIncrDbFilename, 0)) {
            _unlink(szIncrDbFilename);
        }
    }

    exit((int) ErrorNumber);
}


void __cdecl Error(const char *szFilename, UINT ErrorNumber, ...)

/*++

Routine Description:

    Prints an error message, closes all open files, and exits with
    an error number. The error number is the index used to lookup
    the error string.

Arguments:

    szFilename - File which caused the error.

    ErrorNumber - An index into the ErrorInfo structure.

Return Value:

    Exits the program.

--*/

{
    va_list valist;

    va_start(valist, ErrorNumber);

    DisplayError(szFilename, ErrorNumber, valist);

    va_end(valist);
}


void __cdecl ErrorPcon(PCON pcon, UINT ErrorNumber, ...)
{
    va_list valist;
    UCHAR szComFileName[MAXFILENAMELEN * 2];

    va_start(valist, ErrorNumber);

    SzComNamePMOD(PmodPCON(pcon), szComFileName);

    DisplayError(szComFileName, ErrorNumber, valist);

    va_end(valist);
}


void
OutOfMemory(void)

/*++

Routine Description:

    Prints an out of memory error message.

Arguments:

    None.

Return Value:

    None.

--*/

{
    Error(NULL, OUTOFMEMORY);
}
