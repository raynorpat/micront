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

#include "bootenv.h"
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

/*
 * Locate a section by name (<= 8 chars, NUL-padded) in an already-staged
 * image.  On success *out_phys = the section's physical base (phys_mapped +
 * VirtualAddress, directly writable while paging is off) and *out_size =
 * VirtualSize.  Lets the loader fill a boot driver's own data section
 * (e.g. ramscsi's RAMDCFG) with runtime values before handoff.
 */
EFI_STATUS pe_find_section(const pe_image_t *img, const char *name,
                           EFI_PHYSICAL_ADDRESS *out_phys, UINT32 *out_size);

#endif
