/*
 * entry.c — NtProcessStartup trampoline + CommandLine → argv tokeniser.
 *
 * Replaces mingw's crt2.o / mainCRTStartup. Runs ntshim_init first so
 * libc state (heap, clock, stdio) is live before we touch anything,
 * then parses PEB->ProcessParameters->CommandLine into argv and hands
 * control to main(argc, argv).
 *
 * Parsing is destructive and in-place in CommandLine.Buffer:
 *   - The buffer is our own memory (kernel allocates ProcessParameters
 *     via ZwAllocateVirtualMemory in our address space, ref INIT.C).
 *   - UTF-16 input is 2 bytes/wchar; ASCII output is 1 byte/char.
 *     Decoded bytes always fit within the input span with room to
 *     spare, so `out` pointer never clobbers the next unread wchar.
 *   - argv[] entries point into the rewritten buffer.
 *   - Consequence: the original UNICODE_STRING content is destroyed.
 *     We don't expose GetCommandLineW; if a future caller needs it,
 *     preserve a copy of the Buffer before calling this.
 *
 * Quoting follows Microsoft's CommandLineToArgvW rules (documented in
 * the old C runtime docs and observable from `cmd.exe` forever):
 *   - Outside quotes: whitespace (space/tab) separates args.
 *   - Inside quotes: whitespace is literal; a closing " ends quote mode.
 *   - 2N backslashes + "  -> N backslashes,    " toggles quote mode.
 *   - 2N+1 backslashes + " -> N backslashes,   " is a literal char.
 *   - Backslashes not followed by " are literal.
 *
 * Non-ASCII wchars (high byte ≠ 0) are clamped to '?' — our whole
 * userland is ASCII today. Revisit when Lua wants UTF-8.
 */

#include "nt.h"

extern void  ntshim_init(void);
extern int   main(int argc, char **argv);

extern NTSTATUS NTAPI NtTerminateProcess(HANDLE, NTSTATUS);

/* Practical upper bound on argc. Not a length cap — arg content is
 * limited only by the CommandLine buffer's MaximumLength (which the
 * kernel sizes from DOS_MAX_PATH_LENGTH * 4 in INIT.C). */
#define ARGV_MAX  64

static int parse_cmdline(USHORT *wbuf, USHORT wide_bytes, char **argv)
{
    USHORT  nwc  = wide_bytes / sizeof(USHORT);
    USHORT *in   = wbuf;
    USHORT *end  = wbuf + nwc;
    char   *out  = (char *)wbuf;      /* ASCII written back over UTF-16 */
    int     argc = 0;

    while (in < end && argc < ARGV_MAX - 1) {
        /* Skip inter-argument whitespace. */
        while (in < end && (*in == ' ' || *in == '\t')) in++;
        if (in >= end) break;

        argv[argc++] = out;

        int in_quote = 0;
        while (in < end) {
            USHORT wc = *in;

            if (!in_quote && (wc == ' ' || wc == '\t')) {
                in++;
                break;
            }

            if (wc == '\\') {
                /* Count the run of backslashes. */
                int slashes = 0;
                while (in < end && *in == '\\') { slashes++; in++; }

                if (in < end && *in == '"') {
                    /* MS rule: half the backslashes are literal. */
                    int i;
                    for (i = 0; i < slashes / 2; i++) *out++ = '\\';
                    if (slashes & 1) {
                        /* Odd: remainder is a literal quote. */
                        *out++ = '"';
                    } else {
                        /* Even: quote toggles the mode. */
                        in_quote = !in_quote;
                    }
                    in++;    /* consume the " */
                } else {
                    /* Backslashes not before " are literal. */
                    int i;
                    for (i = 0; i < slashes; i++) *out++ = '\\';
                }
                continue;
            }

            if (wc == '"') {
                in_quote = !in_quote;
                in++;
                continue;
            }

            *out++ = (wc < 0x80) ? (char)wc : '?';
            in++;
        }
        *out++ = '\0';
    }
    argv[argc] = 0;
    return argc;
}

void NTAPI NtProcessStartup(PPEB Peb)
{
    static char  fallback_argv0[] = "run";
    static char *argv[ARGV_MAX];
    int argc = 0;
    int rc;

    ntshim_init();

    if (Peb && Peb->ProcessParameters &&
        Peb->ProcessParameters->CommandLine.Buffer &&
        Peb->ProcessParameters->CommandLine.Length > 0)
    {
        argc = parse_cmdline(Peb->ProcessParameters->CommandLine.Buffer,
                             Peb->ProcessParameters->CommandLine.Length,
                             argv);
    }

    if (argc == 0) {
        argv[0] = fallback_argv0;
        argv[1] = 0;
        argc = 1;
    }

    rc = main(argc, argv);
    NtTerminateProcess(NT_CURRENT_PROCESS, (NTSTATUS)rc);
    for (;;) {}
}
