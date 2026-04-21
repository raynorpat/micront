/*
 * libc_mingw.c — libmingwex / libntdllcrt / libgcc gap-fillers.
 *
 * Everything here is motivated by a specific link-time unresolved symbol
 * or a specific runtime miss in the mingw distribution we build against.
 * No consumer of the public API (ntshim.h) should need to touch these.
 *
 * Contents fall into four buckets:
 *   - Math: libmingwex has log/exp/sqrt/atan2 natively, but log10/asin/
 *     acos/sinh/cosh/tanh are only in msvcrt (unavailable here). We
 *     derive them from what libmingwex provides.
 *   - Runtime startup stubs: atexit, _pei386_runtime_relocator.
 *   - mingw SEH cleanup: __DestructExceptionObject (pulled in by
 *     libgcc's personality routine).
 *   - libmingwex math error hook: __mingw_raise_matherr.
 *   - LuaJIT CLI: signal + _fileno + _isatty + __p__fmode + putc.
 */

#include "libc_internal.h"

/* ---------- Math helpers -------------------------------------------- */

extern double log (double);
extern double exp (double);
extern double sqrt(double);
extern double atan2(double, double);

static const double LN_10 = 2.302585092994045684017991454684364207601101488628772976;
static const double PI_2  = 1.570796326794896619231321691639751442098584699687552910;

double log10(double x) { return log(x) / LN_10; }

double asin(double x)
{
    if (x >=  1.0) return  PI_2;
    if (x <= -1.0) return -PI_2;
    return atan2(x, sqrt((1.0 - x) * (1.0 + x)));
}

double acos(double x)
{
    if (x >=  1.0) return 0.0;
    if (x <= -1.0) return 2.0 * PI_2;
    return atan2(sqrt((1.0 - x) * (1.0 + x)), x);
}

double sinh(double x)
{
    double e = exp(x);
    return (e - 1.0 / e) * 0.5;
}

double cosh(double x)
{
    double e = exp(x);
    return (e + 1.0 / e) * 0.5;
}

double tanh(double x)
{
    /* (e^2x - 1) / (e^2x + 1); saturate for large |x| to avoid exp overflow. */
    double e2;
    if (x >  20.0) return  1.0;
    if (x < -20.0) return -1.0;
    e2 = exp(2.0 * x);
    return (e2 - 1.0) / (e2 + 1.0);
}

/* ---------- libgcc / mingw startup stubs ----------------------------- */

/* libgcc's __main.o (called by mingw's default startup) registers a
 * destructor via atexit. We don't support atexit — nothing runs on
 * native NT ExitProcess. Pretend success and forget. */
int atexit(void (*fn)(void)) { (void)fn; return 0; }

/* mingw's auto-import runtime helper. Pulled in unconditionally by any
 * binary that uses dllimport data; harmless no-op when we're not. */
void _pei386_runtime_relocator(void) {}

/* mingw's C++ SEH cleanup helper. lj_err.c's __try/__except pull this
 * in via libgcc's personality routine even when no C++ is involved.
 * Stub — our exception path is longjmp-based. */
void __DestructExceptionObject(void *obj) { (void)obj; }

/* libmingwex math error hook (SVR4-style). Fired by every math function
 * in libmingwex on domain/range errors. Real impl lives in libmingw32.a
 * (we don't link it). Swallow the report — math funcs still return NaN/
 * Inf/clamped values, which is what LuaJIT expects. */
void __mingw_raise_matherr(int typ, const char *name,
                           double a1, double a2, double rslt)
{
    (void)typ; (void)name; (void)a1; (void)a2; (void)rslt;
}

/* ---------- LuaJIT CLI stubs ----------------------------------------- */

/* Signal handling: LuaJIT's CLI registers SIGINT to break long Lua
 * evals. We don't deliver signals on native NT — pretend we registered. */
typedef void (*__sighandler_t)(int);
__sighandler_t signal(int sig, __sighandler_t h) { (void)sig; (void)h; return 0; }

/* putc is a macro in standard stdio.h; mingw also provides it as a
 * real function. LuaJIT's CLI uses it — forward to fputc. */
int putc(int c, FILE *fp) { return fputc(c, fp); }

/* TTY detection for the REPL prompt. _isatty returns whether fd is a
 * terminal; _fileno maps FILE* → fd. Under native NT we have no tty
 * concept and our stdio is serial-backed — report "not a tty" so
 * LuaJIT uses its batched read path instead of per-char. */
int _fileno(FILE *fp)     { (void)fp; return -1; }
int _isatty(int fd)       { (void)fd; return 0; }

/* lj_clib.c checks __p__fmode (msvcrt internal for text/binary default
 * file mode) when opening shared objects. Returns a pointer to an int;
 * 0 = _O_TEXT, which is the value LuaJIT wants. */
static int _ntshim_fmode = 0;
int *__p__fmode(void) { return &_ntshim_fmode; }
