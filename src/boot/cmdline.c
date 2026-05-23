#include "cmdline.h"
#include "fwcfg.h"
#include "log.h"

/* Entry-agnostic resolver policy: the per-launch command line the boot
 * entry already obtained from its firmware (EFI LoadOptions, or the
 * boot_params/PVH cmdline under vmlinuz) wins; otherwise fall back to the
 * fw_cfg blob. The firmware-specific acquisition — and any UTF-16 decode
 * or argv[0] stripping — lives in the per-entry adapter, not here. */
unsigned cmdline(const char *entry_cmdline, char *out, unsigned cap) {
    if (cap == 0) return 0;
    out[0] = 0;

    /* Source 1: entry-supplied command line (per-launch override). */
    if (entry_cmdline && entry_cmdline[0]) {
        unsigned n = 0;
        while (entry_cmdline[n] && n < cap - 1) { out[n] = entry_cmdline[n]; n++; }
        out[n] = 0;
        BXLOG(L"via entry: '%a'", out);
        return n + 1;
    }

    /* Source 2: fw_cfg opt/micront/loadopts (QEMU static-disk default). */
    unsigned n = fwcfg_read_string("opt/micront/loadopts", out, cap);
    if (n > 1) {
        BXLOG(L"via fw_cfg: '%a'", out);
    }
    return n;
}
