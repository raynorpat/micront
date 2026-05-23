#include "memmap.h"
#include "mmu.h"

/*
 * NT memory-descriptor builder. The base map comes from the boot entry via
 * be_memory_regions() (UEFI GetMemoryMap on boot/efi/, e820/PVH on
 * boot/vmlinuz/), collapsed to neutral BeRegion[]; the mmu allocation
 * registry is overlaid on top so our own loaded images/data get their
 * precise NT types.
 *
 * NT's MmInitSystem is picky about which types are "free" vs "reserved" —
 * the page-table triple-fault bug taught us to mark pages carrying our own
 * data (page tables, PCR, TSS) as something MmFreeLoaderBlock won't
 * reclaim. That precision is the registry overlay; the BeRegion base type
 * is deliberately coarse.
 *
 * ARC MEMORY_TYPE values — must match the enum in nt.h / arc.h exactly.
 * Getting these wrong corrupts the kernel's MM bitmap logic silently.
 */
#define NT_LoaderFree                  2
#define NT_LoaderBad                   3
#define NT_LoaderFirmwareTemporary     5
#define NT_LoaderFirmwarePermanent     6
#define NT_LoaderSystemCode            9
#define NT_LoaderHalCode               10
#define NT_LoaderBootDriver            11
#define NT_LoaderStartupPcrPage        17
#define NT_LoaderRegistryData          19
#define NT_LoaderMemoryData            20
#define NT_LoaderNlsData               21

/* Registered allocation kind -> NT type (the precise overlay). */
static UINT32 kind_to_nt(PageKind k) {
    switch (k) {
    case PK_KERNEL_IMAGE:   return NT_LoaderSystemCode;
    case PK_HAL_IMAGE:      return NT_LoaderHalCode;
    case PK_BOOT_DRIVER:    return NT_LoaderBootDriver;
    case PK_REGISTRY:       return NT_LoaderRegistryData;
    case PK_NLS:            return NT_LoaderNlsData;
    case PK_PCR:            return NT_LoaderStartupPcrPage;
    case PK_MEMORY_DATA:    return NT_LoaderMemoryData;
    case PK_FIRMWARE_PERM:  return NT_LoaderFirmwarePermanent;
    case PK_FIRMWARE_TEMP:  return NT_LoaderFirmwareTemporary;
    default:                return NT_LoaderFree;
    }
}

/* Coarse base type (regions with no registry overlap) -> NT type. */
static UINT32 be_memtype_to_nt(BeMemType t) {
    switch (t) {
    case BE_MEM_FREE:         return NT_LoaderFree;
    case BE_MEM_BOOT_RECLAIM: return NT_LoaderFirmwareTemporary;
    case BE_MEM_FIRMWARE:     return NT_LoaderFirmwarePermanent;
    default:                  return NT_LoaderFirmwarePermanent;
    }
}

static void emit_entry(NtMemEntry *out, UINTN cap, UINTN *n,
                       UINT32 type, UINT32 base_page, UINT32 pages) {
    if (pages == 0 || *n >= cap) return;
    /* Merge with previous entry if adjacent and same type. */
    if (*n > 0) {
        NtMemEntry *prev = &out[*n - 1];
        if (prev->memory_type == type &&
            prev->base_page + prev->page_count == base_page) {
            prev->page_count += pages;
            return;
        }
    }
    out[*n].memory_type = type;
    out[*n].base_page   = base_page;
    out[*n].page_count  = pages;
    (*n)++;
}

/*
 * For a base region [desc_base, desc_base + desc_pages) with coarse type
 * coarse_nt, walk the allocation registry and emit NT entries that use the
 * registered PageKind for overlapping ranges and coarse_nt for the gaps.
 * The registry is tiny, so an O(region x registry) pass is cheap and
 * simple. Pieces are emitted in address order.
 */
static void split_by_registry(UINT32 desc_base, UINT32 desc_pages,
                              UINT32 coarse_nt,
                              NtMemEntry *out, UINTN cap, UINTN *n) {
    UINT32 cursor = desc_base;
    UINT32 end    = desc_base + desc_pages;

    while (cursor < end) {
        UINTN i;
        UINT32 best_overlap_start = end;
        UINT32 best_overlap_end   = end;
        UINT32 best_nt            = 0;
        int    found              = 0;

        /* Find the registry entry whose overlap with [cursor, end)
         * starts earliest. */
        for (i = 0; i < mmu_registry_count(); i++) {
            const AllocEntry *e = mmu_registry_entry(i);
            UINT32 rb = (UINT32)(e->phys >> 12);
            UINT32 re = rb + (UINT32)e->pages;
            UINT32 os = rb > cursor ? rb : cursor;
            UINT32 oe = re < end    ? re : end;
            if (os >= oe) continue;     /* no overlap */
            if (os < best_overlap_start) {
                best_overlap_start = os;
                best_overlap_end   = oe;
                best_nt            = kind_to_nt(e->kind);
                found              = 1;
            }
        }

        if (!found) {
            /* Rest of the region is uncovered — emit as coarse. */
            emit_entry(out, cap, n, coarse_nt, cursor, end - cursor);
            return;
        }

        /* Gap before the overlap: coarse type. */
        if (best_overlap_start > cursor) {
            emit_entry(out, cap, n, coarse_nt,
                       cursor, best_overlap_start - cursor);
        }
        /* The overlap itself: registry type. */
        emit_entry(out, cap, n, best_nt,
                   best_overlap_start, best_overlap_end - best_overlap_start);
        cursor = best_overlap_end;
    }
}

/* Scratch for the entry-supplied base map. UEFI maps run a few dozen
 * descriptors on our guests; 256 is generous headroom. */
#define BE_MAX_REGIONS 256
static BeRegion g_regions[BE_MAX_REGIONS];

EFI_STATUS memmap_to_nt(NtMemEntry *out, UINTN out_cap, UINTN *out_n) {
    if (!out || !out_n || out_cap == 0) return EFI_INVALID_PARAMETER;
    *out_n = 0;

    UINT32 nreg = be_memory_regions(g_regions, BE_MAX_REGIONS);
    if (nreg == 0) return EFI_NOT_READY;

    for (UINT32 r = 0; r < nreg; r++) {
        const BeRegion *reg = &g_regions[r];
        /* Skip non-RAM (MMIO/reserved/unusable). NT sizes its PFN bitmap
         * from the highest base_page + page_count; including regions far
         * above real RAM (LAPIC at 0xFEC00000, etc.) would balloon the
         * bitmap and walk off the end of KSEG0. */
        if (reg->type == BE_MEM_RESERVED) continue;
        UINT32 base_page = (UINT32)(reg->base >> 12);
        UINT32 pages     = (UINT32)(reg->size >> 12);
        if (pages == 0) continue;
        split_by_registry(base_page, pages, be_memtype_to_nt(reg->type),
                          out, out_cap, out_n);
    }
    return EFI_SUCCESS;
}
