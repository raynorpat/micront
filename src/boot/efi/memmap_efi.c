/*
 * EFI memory-map adapter. Two responsibilities, both inherently EFI-
 * specific (so they live with the EFI entry, not the shared core):
 *
 *   - capture the UEFI map and hand back the MapKey for ExitBootServices
 *     (the key must match the latest GetMemoryMap, so capture has to be
 *     the last allocation before ExitBootServices);
 *   - translate the captured EFI descriptors to neutral BeRegion[] for the
 *     shared memmap_to_nt() builder (be_memory_regions, boot/bootenv.h).
 */
#include "bootenv.h"
#include "log.h"
#include "memmap_efi.h"

/* Iteration walks byte-by-byte using the GetMemoryMap-returned
 * DescriptorSize, NOT sizeof(EFI_MEMORY_DESCRIPTOR): the spec lets UEFI
 * extend descriptors with trailing fields; naive array indexing would
 * silently skip or duplicate entries on extended maps. */
static EFI_MEMORY_DESCRIPTOR *g_map       = NULL;
static UINTN                  g_map_bytes = 0;
static UINTN                  g_desc_size = 0;

/* Slack: the moment we AllocatePool, the map gains an entry (the pool
 * allocation itself), and the ExitBootServices MapKey must match the
 * latest map. Enough headroom to GetMemoryMap twice without re-allocating. */
#define MAP_SLACK_BYTES 1024

EFI_STATUS memmap_capture(UINTN *out_map_key) {
    UINTN  size = 0, map_key = 0, ds = 0;
    UINT32 dv = 0;
    EFI_STATUS status;

    /* First call: 0-sized buffer to learn the required size. */
    status = uefi_call_wrapper(BS->GetMemoryMap, 5,
                               &size, NULL, &map_key, &ds, &dv);
    if (status != EFI_BUFFER_TOO_SMALL) {
        BXLOG(L"unexpected GetMemoryMap (sizing) status=0x%lx", (UINT64)status);
        return status;
    }

    size += MAP_SLACK_BYTES;
    status = uefi_call_wrapper(BS->AllocatePool, 3,
                               EfiLoaderData, size, (void **)&g_map);
    if (EFI_ERROR(status)) {
        BXLOG(L"AllocatePool failed");
        return status;
    }

    /* Second call: actual fill. Must be the last allocation before
     * ExitBootServices, otherwise map_key is stale. */
    status = uefi_call_wrapper(BS->GetMemoryMap, 5,
                               &size, g_map, &map_key, &ds, &dv);
    if (EFI_ERROR(status)) {
        BXLOG(L"GetMemoryMap (fill) failed status=0x%lx", (UINT64)status);
        uefi_call_wrapper(BS->FreePool, 1, g_map);
        g_map = NULL;
        return status;
    }

    g_map_bytes = size;
    g_desc_size = ds;
    if (out_map_key) *out_map_key = map_key;

    /* DO NOT BXLOG past this point — Print() calls AllocatePool internally,
     * which invalidates the MapKey we just captured and makes
     * ExitBootServices return EFI_INVALID_PARAMETER. The error paths above
     * are fine because they return failure anyway. */
    return EFI_SUCCESS;
}

EFI_STATUS memmap_refresh_key(UINTN *out_map_key) {
    /* Re-call GetMemoryMap into the buffer memmap_capture already
     * allocated. No AllocatePool here, so the new MapKey is current.
     * UEFI 2.10 §7.4.2 mandates this retry for the INVALID_PARAMETER case. */
    if (g_map == NULL) return EFI_NOT_READY;

    UINTN  size = g_map_bytes, map_key = 0, ds = 0;
    UINT32 dv = 0;
    EFI_STATUS status = uefi_call_wrapper(BS->GetMemoryMap, 5,
                                          &size, g_map, &map_key, &ds, &dv);
    if (EFI_ERROR(status)) return status;

    g_map_bytes = size;
    g_desc_size = ds;
    if (out_map_key) *out_map_key = map_key;
    return EFI_SUCCESS;
}

/* be_memory_regions (boot/bootenv.h): collapse the captured UEFI map to
 * neutral BeRegion[]. Per-allocation typing is layered on by the shared
 * memmap_to_nt() via the mmu registry, so here we only need the coarse
 * free / boot-reclaim / firmware / reserved distinction. The map types
 * collapse exactly as the pre-split memmap_to_nt() did:
 *   Conventional                       -> FREE         (LoaderFree)
 *   BootServices + Loader              -> BOOT_RECLAIM (LoaderFirmwareTemporary)
 *   RuntimeServices + ACPI             -> FIRMWARE     (LoaderFirmwarePermanent)
 *   MMIO/IOPort/PalCode/Reserved/Bad   -> RESERVED     (excluded from NT map) */
UINT32 be_memory_regions(BeRegion *out, UINT32 cap) {
    if (!g_map || cap == 0) return 0;

    UINT32 n = 0;
    UINT8 *p   = (UINT8 *)g_map;
    UINT8 *end = p + g_map_bytes;
    for (; p < end && n < cap; p += g_desc_size) {
        EFI_MEMORY_DESCRIPTOR *d = (EFI_MEMORY_DESCRIPTOR *)p;
        if (d->NumberOfPages == 0) continue;

        BeMemType t;
        switch (d->Type) {
        case EfiConventionalMemory:
            t = BE_MEM_FREE; break;
        case EfiBootServicesCode:
        case EfiBootServicesData:
        case EfiLoaderCode:
        case EfiLoaderData:
            t = BE_MEM_BOOT_RECLAIM; break;
        case EfiRuntimeServicesCode:
        case EfiRuntimeServicesData:
        case EfiACPIReclaimMemory:
        case EfiACPIMemoryNVS:
            t = BE_MEM_FIRMWARE; break;
        default:
            t = BE_MEM_RESERVED; break;
        }

        out[n].base = d->PhysicalStart;
        out[n].size = (UINT64)d->NumberOfPages << 12;
        out[n].type = t;
        n++;
    }
    return n;
}
