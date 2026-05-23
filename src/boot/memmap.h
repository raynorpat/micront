/*
 * NT memory-descriptor builder.
 *
 * memmap_to_nt() turns the system memory map — obtained from the boot
 * entry via be_memory_regions() (UEFI GetMemoryMap on boot/efi/, e820/PVH
 * on boot/vmlinuz/) — plus the mmu allocation registry into NT-style
 * descriptors. The firmware-specific map capture and the ExitBootServices
 * MapKey dance live in the entry adapter (boot/efi/memmap_efi.c), not here.
 */
#ifndef _BOOT_EFI_MEMMAP_H_
#define _BOOT_EFI_MEMMAP_H_

#include "bootenv.h"

/*
 * NT memory descriptor emitted from translate. Mirrors the fields of
 * MEMORY_ALLOCATION_DESCRIPTOR but without the NT LIST_ENTRY — lpb links
 * them into the loader-block list when it stitches things together.
 */
typedef struct {
    UINT32 memory_type;    /* ARC MEMORY_TYPE value */
    UINT32 base_page;      /* phys / 4096 */
    UINT32 page_count;
} NtMemEntry;

/* Build NT descriptors from be_memory_regions() + the allocation
 * registry. Sorted by base_page, adjacent same-type entries merged.
 * Returns EFI_SUCCESS; writes into the caller-supplied array, no alloc. */
EFI_STATUS memmap_to_nt(NtMemEntry *out, UINTN out_cap, UINTN *out_n);

#endif
