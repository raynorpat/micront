/*
 * k32_internal.h — shared internals across the k32_*.c translation units.
 *
 * Not exposed to consumers of the runtime. Consumers see only kernel32.h's
 * Win32-shape surface.
 */

#ifndef RT_K32_INTERNAL_H
#define RT_K32_INTERNAL_H

#include "nt.h"
#include "kernel32.h"

/* ---------- ASCII <-> wide helpers ----------------------------------- */

/* Copy ASCII string into a wide buffer, NUL-terminating. Truncates if
 * source exceeds cap-1 wchars. Used by LoadLibrary / GetModuleHandle. */
static __inline__ void _k32_ascii_to_wide(const char *s, unsigned short *out,
                                          size_t cap)
{
    size_t i = 0, n = 0;
    while (s[n]) n++;
    if (n >= cap) n = cap - 1;
    for (; i < n; i++) out[i] = (unsigned short)(unsigned char)s[i];
    out[n] = 0;
}

/* Case-insensitive wide-string compare, ASCII only. Good enough for
 * module basename matching ("KERNEL32.DLL" vs "kernel32.dll"). */
static __inline__ int _k32_wcsicmp_ascii(const unsigned short *a,
                                         const unsigned short *b)
{
    for (;;) {
        unsigned short ca = *a++, cb = *b++;
        if (ca >= 'A' && ca <= 'Z') ca += 32;
        if (cb >= 'A' && cb <= 'Z') cb += 32;
        if (ca != cb) return (int)ca - (int)cb;
        if (!ca) return 0;
    }
}

#endif /* RT_K32_INTERNAL_H */
