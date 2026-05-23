/*
 * PVH implementation of the bootenv service contract — the firmware-less
 * counterpart to boot/efi/{bootenv_efi,memmap_efi}.c.
 *
 *   be_memory_regions() : translate hvm_start_info's e820 to BeRegion[].
 *   be_alloc_pages()    : a free-region physical allocator that mirrors
 *                         UEFI AllocatePages, since the shared core's
 *                         allocation strategy was written against it:
 *                           BE_ALLOC_ANY -> AllocateAnyPages  (top-down)
 *                           BE_ALLOC_MAX -> AllocateMaxAddress(top-down,
 *                                           capped — the <16 MiB world)
 *                           BE_ALLOC_AT  -> AllocateAddress    (exact)
 *                         Top-down ANY (matching EDK2) keeps low memory
 *                         free for the fixed-base kernel images.
 *
 * Free space = e820 usable regions minus the null page, our own image,
 * and the initrd. Overlaps are tracked so AT images, the <16 MiB MAX
 * structures, and high ANY data never collide.
 */
#include "bootenv.h"
#include "bootenv_pvh.h"

/* Image extent, from vmlinux.lds. */
extern char _image_start[];
extern char _image_end[];

static const struct hvm_memmap_table_entry *g_e820;
static UINT32 g_e820_n;

#define MAX_FREE 32
typedef struct { UINT64 base, end; } Region;       /* [base, end), page-aligned */
static Region g_free[MAX_FREE];
static int    g_nfree;

static UINT64 pgup(UINT64 x) { return (x + 0xfffull) & ~0xfffull; }
static UINT64 pgdn(UINT64 x) { return x & ~0xfffull; }

/* Remove [base, end) from the free list (split / trim / drop), rebuilding
 * it so the bookkeeping stays simple and overlap-correct. */
static void carve(UINT64 base, UINT64 end) {
    if (end <= base) return;
    Region nw[MAX_FREE];
    int nn = 0;
    for (int i = 0; i < g_nfree; i++) {
        UINT64 b = g_free[i].base, e = g_free[i].end;
        if (end <= b || base >= e) {               /* disjoint — keep whole */
            if (nn < MAX_FREE) nw[nn++] = g_free[i];
            continue;
        }
        if (b < base && nn < MAX_FREE) { nw[nn].base = b;   nw[nn].end = base; nn++; }
        if (end < e && nn < MAX_FREE) { nw[nn].base = end; nw[nn].end = e;    nn++; }
    }
    for (int i = 0; i < nn; i++) g_free[i] = nw[i];
    g_nfree = nn;
}

void pvh_bootenv_init(const struct hvm_start_info *si) {
    g_e820 = 0; g_e820_n = 0; g_nfree = 0;
    if (si->version >= 1 && si->memmap_paddr && si->memmap_entries) {
        g_e820   = (const struct hvm_memmap_table_entry *)(uintptr_t)si->memmap_paddr;
        g_e820_n = si->memmap_entries;
    }

    /* Free list = e820 usable (type 1), page-aligned inward. */
    for (UINT32 i = 0; i < g_e820_n && g_nfree < MAX_FREE; i++) {
        if (g_e820[i].type != 1) continue;
        UINT64 b = pgup(g_e820[i].addr);
        UINT64 e = pgdn(g_e820[i].addr + g_e820[i].size);
        if (e > b) { g_free[g_nfree].base = b; g_free[g_nfree].end = e; g_nfree++; }
    }

    /* Exclusions: null page, our own image, the initrd. */
    carve(0, 0x1000);
    carve(pgdn((UINT64)(UINTN)_image_start), pgup((UINT64)(UINTN)_image_end));
    if (si->nr_modules && si->modlist_paddr) {
        const struct hvm_modlist_entry *m =
            (const struct hvm_modlist_entry *)(uintptr_t)si->modlist_paddr;
        carve(pgdn(m[0].paddr), pgup(m[0].paddr + m[0].size));
    }
}

UINT32 be_memory_regions(BeRegion *out, UINT32 cap) {
    UINT32 n = 0;
    for (UINT32 i = 0; i < g_e820_n && n < cap; i++) {
        BeMemType t;
        switch (g_e820[i].type) {
        case 1:           t = BE_MEM_FREE;     break;   /* usable RAM       */
        case 3: case 4:   t = BE_MEM_FIRMWARE; break;   /* ACPI reclaim/NVS */
        default:          t = BE_MEM_RESERVED; break;   /* reserved/bad/... */
        }
        out[n].base = g_e820[i].addr;
        out[n].size = g_e820[i].size;
        out[n].type = t;
        n++;
    }
    return n;
}

/* Highest [x, x+bytes) with x+bytes <= cap across all free regions.
 * Carves it out and returns x; 0 on failure. (UEFI AnyPages / MaxAddress
 * are both top-down; ANY just passes cap = ~0.) */
static UINT64 alloc_high(UINT64 cap, UINT64 bytes) {
    UINT64 best = 0;
    int    found = 0;
    for (int i = 0; i < g_nfree; i++) {
        UINT64 top = (g_free[i].end < cap) ? g_free[i].end : cap;
        top = pgdn(top);
        if (top < bytes) continue;
        UINT64 x = top - bytes;
        if (x < g_free[i].base) continue;
        if (!found || x > best) { best = x; found = 1; }
    }
    if (!found) return 0;
    carve(best, best + bytes);
    return best;
}

static UINT64 alloc_at(UINT64 want, UINT64 bytes) {
    for (int i = 0; i < g_nfree; i++) {
        if (want >= g_free[i].base && want + bytes <= g_free[i].end) {
            carve(want, want + bytes);
            return want;
        }
    }
    return 0;
}

UINT64 be_alloc_pages(BeAllocMode mode, UINTN pages, UINT64 want) {
    UINT64 bytes = (UINT64)pages << 12;
    if (bytes == 0) return 0;
    switch (mode) {
    case BE_ALLOC_AT:  return alloc_at(want, bytes);
    case BE_ALLOC_MAX: return alloc_high(want, bytes);
    case BE_ALLOC_ANY:
    default:           return alloc_high(~(UINT64)0, bytes);
    }
}
