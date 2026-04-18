/****************************************************************************/
/*                                                                          */
/*  RC.C -                                                                  */
/*                                                                          */
/*    Windows 3.5 Resource Compiler - Main Module                           */
/*                                                                          */
/*                                                                          */
/****************************************************************************/

#include "prerc.h"
#pragma hdrstop
#include <setjmp.h>


/* Module handle */
HINSTANCE hInstance;
HWND      hWndCaller;

RC_CALLBACK  lpfnRCCallback;


/* Function prototypes */
int     _CRTAPI1    rc_main(int, char**);
int     _CRTAPI1    rcpp_main(int argc, PWCHAR*argv);


BOOL APIENTRY LibMain(HANDLE hDll, DWORD dwReason, LPVOID lpReserved)
{
    hInstance = hDll;

    return TRUE;
}


int CALLBACK RC(HWND hWnd, int fStatus, RC_CALLBACK lpfn, int argc, char**argv)
{
    WriteFile(GetStdHandle((DWORD)-12), "RC: RC() entered\r\n", 18, NULL, NULL);
    hWndCaller     = hWnd;

    lpfnRCCallback = lpfn;

    return (rc_main(argc, argv));
}


int RCPP(int argc, PCHAR *argv, PCHAR env)
{
    WCHAR    **wargv;

    wargv = UnicodeCommandLine(argc, argv);
    return rcpp_main(argc, wargv);
}


void SendError(PSTR str)
{
    (*lpfnRCCallback)(0, 0, str);

    (void)hWndCaller;
}


void UpdateStatus(unsigned nCode, unsigned long dwStatus)
{
    (void)hWndCaller;
    (void)nCode;
    (void)dwStatus;
}


