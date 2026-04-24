/*
 * winentry.c — freestanding entry adapter for runc.exe and runw.exe.
 *
 * The Win32 stubs (subsystem=console / windows) share this entry. The
 * loader has already loaded ntdll + kernel32 via the binaries' static
 * imports; kernel32's DllMain has done the csrss handshake (allocated
 * a console for runc, registered as GUI for runw) before we are
 * called. Our job:
 *
 *   1. Tokenise PEB->ProcessParameters->CommandLine to argv.
 *   2. Hand off to LuaJIT's main(argc, argv).
 *   3. ExitProcess on return.
 *
 * No mingw mainCRTStartup / WinMainCRTStartup, no atexit, no TLS
 * callback dispatch, no _pioinfo. Hand-written entry, every step is
 * ours.
 *
 * argv tokenisation is the same byte-for-byte as rt/entry.c —
 * destructive in-place ASCII rewrite of the CommandLine UTF-16 buffer,
 * MS CommandLineToArgvW quoting rules. Duplicated here rather than
 * shared with rt/entry.c because we want this file to depend on
 * absolutely nothing in librt (the whole point of the split).
 *
 * Two entry points are defined: _StartConsole and _StartWindows. The
 * Makefile picks one via -Wl,--entry per binary; the unused one is
 * dead-stripped.
 */

#include "nt.h"     /* rt/nt.h via -Irt: PEB/PROCESS_PARAMETERS layout */

extern int  main(int argc, char **argv);

/* librt's CRT initialiser — captures PEB->ProcessHeap into _libc_heap,
 * seeds the clock, etc. rt/entry.c::NtProcessStartup calls this for
 * native run.exe; the Win32 stubs need the same setup before any
 * libc-from-librtw call (e.g., LuaJIT calling fopen) — without it
 * malloc dereferences a NULL heap handle. */
extern void ntshim_init(void);

/* kernel32 — statically imported via the binary's import table. The
 * loader's processed kernel32's DllMain before our entry runs. */
extern void __attribute__((stdcall)) ExitProcess(unsigned long ExitCode);

#define ARGV_MAX   64

static int parse_cmdline(USHORT *wbuf, USHORT wide_bytes, char **argv)
{
    USHORT  nwc  = wide_bytes / sizeof(USHORT);
    USHORT *in   = wbuf;
    USHORT *end  = wbuf + nwc;
    char   *out  = (char *)wbuf;
    int     argc = 0;

    while (in < end && argc < ARGV_MAX - 1) {
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
                int slashes = 0;
                while (in < end && *in == '\\') { slashes++; in++; }

                if (in < end && *in == '"') {
                    int i;
                    for (i = 0; i < slashes / 2; i++) *out++ = '\\';
                    if (slashes & 1) {
                        *out++ = '"';
                    } else {
                        in_quote = !in_quote;
                    }
                    in++;
                } else {
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

static __inline__ PPEB get_peb(void)
{
    PPEB p;
    __asm__ volatile ("movl %%fs:0x30, %0" : "=r"(p));
    return p;
}

static void common_entry(void)
{
    static char  fallback_argv0[] = "run";
    static char *argv[ARGV_MAX];
    int argc = 0;
    int rc;
    PPEB peb;

    /* Run librt's CRT init first — _libc_heap = PEB->ProcessHeap,
     * clock seed, etc. Must precede any malloc/fopen/printf from
     * librtw (and LuaJIT through it). */
    ntshim_init();

    peb = get_peb();
    if (peb && peb->ProcessParameters &&
        peb->ProcessParameters->CommandLine.Buffer &&
        peb->ProcessParameters->CommandLine.Length > 0)
    {
        argc = parse_cmdline(peb->ProcessParameters->CommandLine.Buffer,
                             peb->ProcessParameters->CommandLine.Length,
                             argv);
    }

    if (argc == 0) {
        argv[0] = fallback_argv0;
        argv[1] = 0;
        argc = 1;
    }

    rc = main(argc, argv);
    ExitProcess((unsigned long)rc);
}

/* Distinct entry symbols for distinct subsystems. The Makefile picks
 * the matching one per binary via -Wl,--entry. Both delegate to the
 * shared common_entry; the only purpose of two symbols is to make the
 * two binaries' entry-point fields differ in case anything inspects
 * them. Names omit the leading underscore — gcc's PE convention adds
 * one (and stdcall adds @N), so the actual exported symbol matches
 * the linker --entry flag (_StartConsole@0 / _StartWindows@0). */
/* used: see entry.c — LTO can't see the linker --entry reference. */
__attribute__((stdcall, used)) void StartConsole(void) { common_entry(); }
__attribute__((stdcall, used)) void StartWindows(void) { common_entry(); }
