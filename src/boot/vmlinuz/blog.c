/*
 * vmlinuz log sink: the per-entry bxlog() (boot/log.h) for the PVH entry.
 * A small wide-format (CHAR16) printf to COM1, mirroring the gnu-efi Print
 * specifiers the shared core uses: %a (ASCII str), %s (CHAR16 str), %c,
 * %d, %u, %x, the 'l' (64-bit) modifier, and "%0N" zero-pad width.
 *
 * The EFI entry's bxlog() is gnu-efi VPrint instead; both must interpret
 * the same BXLOG format identically.
 */
#include <stdarg.h>
#include "bootenv.h"
#include "com1.h"

static void put_ascii(const CHAR8 *s) {
    if (!s) { com1_putc('('); com1_putc('n'); com1_putc(')'); return; }
    while (*s) com1_putc((char)*s++);
}

static void put_wide(const CHAR16 *s) {
    if (!s) { com1_putc('('); com1_putc('n'); com1_putc(')'); return; }
    while (*s) com1_putc((char)(*s++ & 0x7f));
}

static void put_uint(UINT64 v, unsigned base, int width, char pad) {
    static const char d[] = "0123456789abcdef";
    char tmp[24];
    int n = 0;
    if (v == 0) tmp[n++] = '0';
    while (v) { tmp[n++] = d[v % base]; v /= base; }
    while (n < width) tmp[n++] = pad;
    while (n) com1_putc(tmp[--n]);
}

static void put_int(INT64 v, int width, char pad) {
    if (v < 0) { com1_putc('-'); v = -v; }
    put_uint((UINT64)v, 10, width, pad);
}

void bxlog(const CHAR16 *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    for (const CHAR16 *p = fmt; *p; p++) {
        if (*p != L'%') { com1_putc((char)(*p & 0x7f)); continue; }
        p++;
        char pad = ' ';
        int width = 0, is_long = 0;
        if (*p == L'0') { pad = '0'; p++; }
        while (*p >= L'0' && *p <= L'9') { width = width * 10 + (int)(*p - L'0'); p++; }
        if (*p == L'l') { is_long = 1; p++; }
        switch (*p) {
        case L'a': put_ascii(va_arg(ap, const CHAR8 *)); break;
        case L's': put_wide(va_arg(ap, const CHAR16 *)); break;
        case L'c': com1_putc((char)va_arg(ap, int)); break;
        case L'd': put_int(is_long ? va_arg(ap, INT64) : (INT64)va_arg(ap, int),
                           width, pad); break;
        case L'u': put_uint(is_long ? va_arg(ap, UINT64) : (UINT64)va_arg(ap, unsigned),
                            10, width, pad); break;
        case L'x': put_uint(is_long ? va_arg(ap, UINT64) : (UINT64)va_arg(ap, unsigned),
                            16, width, pad); break;
        case L'%': com1_putc('%'); break;
        case 0:    va_end(ap); return;          /* trailing '%' */
        default:   com1_putc('%'); com1_putc((char)(*p & 0x7f)); break;
        }
    }
    va_end(ap);
}
