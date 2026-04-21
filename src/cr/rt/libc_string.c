/*
 * libc_string.c — string/mem helpers, numeric parsing, and errno glue.
 *
 * ntdll exports memcpy / memset / memcmp / strcpy / strlen; we fill in
 * the gap (memmove, strcmp family, strchr/strrchr/strstr, strtoX,
 * strerror). _ntshim_errno and _errno() live here since they're touched
 * by multiple string/number helpers.
 */

#include "libc_internal.h"

int _ntshim_errno = 0;

void *memmove(void *dst, const void *src, size_t n)
{
    char *d = (char *)dst;
    const char *s = (const char *)src;
    if (d == s || n == 0) return dst;
    if (d < s) { while (n--) *d++ = *s++; }
    else       { d += n; s += n; while (n--) *--d = *--s; }
    return dst;
}

int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n)
{
    while (n && *a && *a == *b) { a++; b++; n--; }
    if (!n) return 0;
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

char *strncpy(char *dst, const char *src, size_t n)
{
    size_t i = 0;
    while (i < n && src[i]) { dst[i] = src[i]; i++; }
    while (i < n)            { dst[i++] = 0; }
    return dst;
}

char *strcat(char *dst, const char *src)
{
    char *d = dst + strlen(dst);
    while ((*d++ = *src++) != 0) {}
    return dst;
}

char *strchr(const char *s, int c)
{
    char target = (char)c;
    for (; *s; s++) if (*s == target) return (char *)s;
    return target == 0 ? (char *)s : 0;
}

char *strrchr(const char *s, int c)
{
    const char *last = 0;
    char target = (char)c;
    for (; *s; s++) if (*s == target) last = s;
    if (target == 0) return (char *)s;
    return (char *)last;
}

char *strstr(const char *hay, const char *needle)
{
    size_t nl = strlen(needle);
    if (nl == 0) return (char *)hay;
    for (; *hay; hay++) {
        if (*hay == *needle && strncmp(hay, needle, nl) == 0) return (char *)hay;
    }
    return 0;
}

/* ---------- Numeric parsing ------------------------------------------ */

int  atoi(const char *s)    { return (int)strtol(s, 0, 10); }
long atol(const char *s)    { return strtol(s, 0, 10); }

long strtol(const char *s, char **endp, int base)
{
    long result = 0;
    int  neg = 0;
    while (*s == ' ' || *s == '\t' || *s == '\n') s++;
    if (*s == '+') s++;
    else if (*s == '-') { neg = 1; s++; }
    if (base == 0) {
        if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { base = 16; s += 2; }
        else if (s[0] == '0')                            { base = 8;  s++; }
        else                                              { base = 10; }
    } else if (base == 16 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        s += 2;
    }
    for (;;) {
        int d;
        char c = *s;
        if (c >= '0' && c <= '9')      d = c - '0';
        else if (c >= 'a' && c <= 'z') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'Z') d = c - 'A' + 10;
        else break;
        if (d >= base) break;
        result = result * base + d;
        s++;
    }
    if (endp) *endp = (char *)s;
    return neg ? -result : result;
}

/* libntdllcrt.a lists strtoul as a dllimport from ntdll.dll. NT 3.5 doesn't
 * export it (modern Windows added it) — we pre-empt the import by defining
 * our own, linked earlier than libntdllcrt. */
unsigned long strtoul(const char *s, char **endp, int base)
{
    unsigned long result = 0;
    while (*s == ' ' || *s == '\t' || *s == '\n') s++;
    if (*s == '+') s++;                    /* reject leading '-' silently */
    if (base == 0) {
        if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { base = 16; s += 2; }
        else if (s[0] == '0')                            { base = 8;  s++; }
        else                                              { base = 10; }
    } else if (base == 16 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        s += 2;
    }
    for (;;) {
        int d;
        char c = *s;
        if      (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'z') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'Z') d = c - 'A' + 10;
        else break;
        if (d >= base) break;
        result = result * base + (unsigned long)d;
        s++;
    }
    if (endp) *endp = (char *)s;
    return result;
}

/* strtod: naive — handles the well-formed inputs LuaJIT's tonumber
 * tends to feed it. Doesn't round-trip all IEEE754 patterns. */
double strtod(const char *s, char **endp)
{
    double result = 0, frac = 0, scale = 1;
    int neg = 0, exp_sign = 0, exp_val = 0, has_digits = 0;
    while (*s == ' ' || *s == '\t' || *s == '\n') s++;
    if (*s == '+') s++;
    else if (*s == '-') { neg = 1; s++; }
    while (*s >= '0' && *s <= '9') { result = result * 10 + (*s++ - '0'); has_digits = 1; }
    if (*s == '.') {
        s++;
        while (*s >= '0' && *s <= '9') {
            frac  = frac * 10 + (*s++ - '0');
            scale *= 10;
            has_digits = 1;
        }
        result += frac / scale;
    }
    if (has_digits && (*s == 'e' || *s == 'E')) {
        s++;
        if (*s == '+') s++;
        else if (*s == '-') { exp_sign = 1; s++; }
        while (*s >= '0' && *s <= '9') exp_val = exp_val * 10 + (*s++ - '0');
        {
            double m = 1;
            int i;
            for (i = 0; i < exp_val; i++) m *= 10;
            result = exp_sign ? result / m : result * m;
        }
    }
    if (endp) *endp = (char *)s;
    return neg ? -result : result;
}

/* ---------- errno + strerror ----------------------------------------- */

/* libntdllcrt's _errno is a dllimport that NT 3.5's ntdll doesn't
 * export. Shadow the import with our own definition. */
int *_errno(void) { return &_ntshim_errno; }

/* LuaJIT passes strerror's return straight to lua_pushstring, so the
 * contents don't need to match a standard table; just be non-NULL. */
static char _strerror_buf[32];
char *strerror(int err)
{
    static const char digits[] = "0123456789";
    char *p = _strerror_buf;
    int i, n;
    const char *prefix = "errno ";
    for (i = 0; prefix[i]; i++) *p++ = prefix[i];
    if (err < 0) { *p++ = '-'; err = -err; }
    n = 0; { int t = err; do { n++; t /= 10; } while (t); }
    for (i = n - 1; i >= 0; i--) { p[i] = digits[err % 10]; err /= 10; }
    p += n;
    *p = 0;
    return _strerror_buf;
}

/* ---------- env --------------------------------------------------- */
/* TODO: walk PEB->ProcessParameters->Environment for real env reads. */
char *getenv(const char *name) { (void)name; return 0; }
