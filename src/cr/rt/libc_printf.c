/*
 * libc_printf.c — printf family, layered on ntdll's _vsnprintf and the
 * FILE-based fwrite from libc_stdio.c.
 *
 * ntdll's _vsnprintf doesn't null-terminate on overflow and returns -1 —
 * vsnprintf here normalises to C99 semantics (always NUL, returns chars
 * that would have been written).
 */

#include "libc_internal.h"

int vsnprintf(char *buf, size_t sz, const char *fmt, va_list ap)
{
    int n;
    if (sz == 0) return 0;
    n = _vsnprintf(buf, sz, fmt, ap);
    if (n < 0 || (size_t)n >= sz) {
        buf[sz - 1] = 0;
        return (int)(sz - 1);    /* approximate — good enough for LuaJIT */
    }
    return n;
}

int snprintf(char *buf, size_t sz, const char *fmt, ...)
{
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = vsnprintf(buf, sz, fmt, ap);
    va_end(ap);
    return n;
}

int sprintf(char *buf, const char *fmt, ...)
{
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = _vsnprintf(buf, 0x7FFFFFFF, fmt, ap);
    va_end(ap);
    return n;
}

int vfprintf(FILE *fp, const char *fmt, va_list ap)
{
    char buf[1024];
    int n = _vsnprintf(buf, sizeof(buf), fmt, ap);
    if (n < 0) { buf[sizeof(buf)-1] = 0; n = (int)strlen(buf); }
    return (int)fwrite(buf, 1, (size_t)n, fp);
}

int fprintf(FILE *fp, const char *fmt, ...)
{
    va_list ap; int n;
    va_start(ap, fmt);
    n = vfprintf(fp, fmt, ap);
    va_end(ap);
    return n;
}

int printf(const char *fmt, ...)
{
    va_list ap; int n;
    va_start(ap, fmt);
    n = vfprintf(stdout, fmt, ap);
    va_end(ap);
    return n;
}
