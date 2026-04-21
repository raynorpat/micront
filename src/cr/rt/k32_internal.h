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

/* ---------- TEB direct access ---------------------------------------- */
/*
 * Canonical per-thread data lives in the TEB (Thread Environment Block),
 * reached via the FS segment register. Offsets verified against NT 3.5's
 * ntpsapi.h TEB struct (pack 4); same as modern x86 Windows:
 *
 *   fs:0x18      TEB.Self             (points back at TEB base)
 *   fs:0x30      TEB.ProcessEnvironmentBlock
 *   fs:0x34      TEB.LastErrorValue
 *   fs:0xE10     TEB.TlsSlots[64]     (TLS_MINIMUM_AVAILABLE)
 *
 * We access each slot with a direct segment-prefixed load/store — no
 * dereference of TEB base required. Kernel zeroes TlsSlots on thread
 * creation, so TlsGetValue returns NULL for a freshly-allocated index
 * without explicit init work.
 */

#define TEB_TLS_SLOT_COUNT   64

static __inline__ DWORD _k32_last_error_read(void)
{
    DWORD v;
    __asm__ ("movl %%fs:0x34, %0" : "=r"(v));
    return v;
}

static __inline__ void _k32_last_error_write(DWORD v)
{
    __asm__ volatile ("movl %0, %%fs:0x34" : : "r"(v) : "memory");
}

static __inline__ void *_k32_tls_get(unsigned idx)
{
    void *v;
    __asm__ ("movl %%fs:0xE10(,%1,4), %0" : "=r"(v) : "r"(idx));
    return v;
}

static __inline__ void _k32_tls_set(unsigned idx, void *val)
{
    __asm__ volatile ("movl %0, %%fs:0xE10(,%1,4)"
                      : : "r"(val), "r"(idx) : "memory");
}

#endif /* RT_K32_INTERNAL_H */
