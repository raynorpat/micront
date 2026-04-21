/*
 * entry.c — NtProcessStartup trampoline + CommandLine → argv tokeniser.
 *
 * Replaces mingw's crt2.o / mainCRTStartup. First runs ntshim_init so
 * libc state (heap, clock, stdio) is ready, then hands control to
 * main(argc, argv) where argv is built from PEB->ProcessParameters
 * ->CommandLine (whitespace-tokenised, UTF-16 → ASCII, high byte dropped).
 * No quote handling yet — callers that need spaces inside a single argv
 * entry need a richer tokeniser.
 */

#include "nt.h"

extern void  ntshim_init(void);
extern int   main(int argc, char **argv);

extern NTSTATUS NTAPI NtTerminateProcess(HANDLE, NTSTATUS);

#define ARGV_MAX     32
#define CMDLINE_MAX  1024

static int tokenise_cmdline(const USHORT *src, USHORT src_bytes,
                            char *out, char **argv)
{
    USHORT i = 0, nwc = src_bytes / sizeof(USHORT);
    int    argc = 0;

    while (i < nwc && argc < ARGV_MAX - 1) {
        while (i < nwc && (src[i] == ' ' || src[i] == '\t')) i++;
        if (i >= nwc) break;
        argv[argc++] = out;
        while (i < nwc && src[i] != ' ' && src[i] != '\t') {
            *out++ = (char)src[i++];
        }
        *out++ = '\0';
    }
    argv[argc] = 0;
    return argc;
}

void NTAPI NtProcessStartup(PPEB Peb)
{
    static char  fallback_argv0[] = "run";
    static char  argv_buf[CMDLINE_MAX];
    static char *argv[ARGV_MAX];
    int argc;
    int rc;

    ntshim_init();

    if (Peb && Peb->ProcessParameters &&
        Peb->ProcessParameters->CommandLine.Buffer &&
        Peb->ProcessParameters->CommandLine.Length > 0)
    {
        USHORT len = Peb->ProcessParameters->CommandLine.Length;
        if (len >= CMDLINE_MAX) len = CMDLINE_MAX - 1;
        argc = tokenise_cmdline(Peb->ProcessParameters->CommandLine.Buffer,
                                len, argv_buf, argv);
    } else {
        argc = 0;
    }

    if (argc == 0) {
        argv[0] = fallback_argv0;
        argv[1] = 0;
        argc = 1;
    }

    rc = main(argc, argv);
    NtTerminateProcess(NT_CURRENT_PROCESS, (NTSTATUS)rc);
    for (;;) { }
}
