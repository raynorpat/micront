/*
 * Minimal PE32 loader + import resolver.
 *
 * Stage A (pe_stage):
 *   - Parse IMAGE_DOS_HEADER -> IMAGE_NT_HEADERS32 -> IMAGE_OPTIONAL_HEADER32
 *   - Allocate SizeOfImage pages (via mmu_alloc with caller-supplied kind)
 *   - memcpy each IMAGE_SECTION_HEADER from file@PointerToRawData to
 *     dest+VirtualAddress; zero-fill (VirtualSize > SizeOfRawData)
 *   - Walk .reloc (DataDirectory[IMAGE_DIRECTORY_ENTRY_BASERELOC]) and
 *     apply HIGHLOW relocations for (actual_base - ImageBase) delta
 *
 * Stage B (pe_resolve_imports):
 *   - Walk DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT] IIDs
 *   - For each imported DLL: look up by case-insensitive name in the
 *     modules[] array, walk its IMAGE_EXPORT_DIRECTORY to resolve each
 *     thunk (by-name and by-ordinal), patch FirstThunk entries
 *
 * The image's effective virtual base is (KSEG0_BASE | phys_mapped).
 * PE relocations are patched with this virtual base so kernel code
 * references itself via KSEG0 once paging is active.
 */
#ifndef _BOOT_EFI_PE_H_
#define _BOOT_EFI_PE_H_

#include <efi.h>
#include "mmu.h"

typedef struct {
    const char          *name;            /* lowercase DLL name, e.g. "ntoskrnl.exe" */
    EFI_PHYSICAL_ADDRESS phys_mapped;     /* phys base of the staged copy */
    UINT32               image_base_va;   /* KSEG0|phys_mapped — the image's live virtual base */
    UINT32               size_of_image;
    UINT32               entry_rva;       /* AddressOfEntryPoint (add to base for EP) */
} pe_image_t;

EFI_STATUS pe_stage(const void *blob, UINTN blob_size,
                    PageKind kind, const char *name,
                    pe_image_t *out);

EFI_STATUS pe_resolve_imports(pe_image_t *img,
                              const pe_image_t *modules, UINTN n_modules);

/* Number of 4 KiB pages SizeOfImage rounds up to (0 on a bad PE). Lets the
 * caller size a contiguous staging block before staging. */
UINTN pe_image_pages(const void *blob, UINTN blob_size);

/* Boot drivers are all linked at the same ImageBase (0x10000), so only the
 * first could ever get its preferred phys; the rest used to fall back to
 * AllocateMaxAddress and scatter — nondeterministic, firmware-dependent
 * placement interleaved with the LPB arena / machine-state pages. Instead,
 * main.c reserves one contiguous block (registered PK_BOOT_DRIVER) and
 * pe_stage sub-allocates PK_BOOT_DRIVER images from it — deterministic and
 * firmware-independent. base=0 disables (per-image fallback). */
void pe_set_driver_arena(EFI_PHYSICAL_ADDRESS base, UINTN pages);

#endif
