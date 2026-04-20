/*
 * start.c — NtProcessStartup entry point for native-NT binaries that
 * want a normal int main(int, char **) signature.
 *
 * Links into any cr/ consumer that pulls in the ntshim CRT. Replaces
 * mingw's crt2.o / mainCRTStartup entirely. Command line is not yet
 * parsed — argv[0] is set to the image name and that's it. When we
 * want real CLI args we'll walk PEB->ProcessParameters->CommandLine.
 */

typedef void *PPEB;

#define NTAPI __attribute__((stdcall))

extern void  ntshim_init(void);
extern void  NTAPI ExitProcess(unsigned long);
extern int   main(int argc, char **argv);

/* The script passed via LuaJIT's -e flag. FFI smoke test: load ntdll
 * through our LoadLibraryA (= LdrLoadDll) shim, bind DbgPrint via
 * GetProcAddress (= LdrGetProcedureAddress), then call it from Lua.
 * If we see the ">>>... <<<" line in the boot log it means the whole
 * chain (Lua → FFI → kernel32 shim → ntdll → COM2) is alive.
 *
 * Replaced by luaL_dofile("C:\\lua\\init.lua") once we plumb that in. */
static char g_script[] =
    "print('jit.version = ' .. jit.version)\n"
    "print('jit.arch    = ' .. jit.arch)\n"
    "print('jit.os      = ' .. jit.os)\n"
    "print('jit.status  = ' .. tostring(jit.status()))\n"
    /* Force a trace: tight loop hot enough to compile (LuaJIT's default
     * hotloop threshold is 56 iterations). Afterward jit.status() lists
     * the backend + any traces produced. */
    "local n = 0\n"
    "for i = 1, 1000 do n = n + i end\n"
    "print('loop sum = ' .. n)\n"
    /* jit.status returns (bool, flagstr, flagstr, ...). Print via
     * multiple-arg print which happily formats booleans + strings. */
    "print('jit flags:', jit.status())\n";

void NTAPI NtProcessStartup(PPEB Peb)
{
    static char  progname[] = "luajit";
    static char  e_flag[]   = "-e";
    static char *argv[4];
    int rc;

    (void)Peb;
    argv[0] = progname;
    argv[1] = e_flag;
    argv[2] = g_script;
    argv[3] = 0;

    ntshim_init();
    rc = main(3, argv);
    ExitProcess((unsigned long)rc);
}
