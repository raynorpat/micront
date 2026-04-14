/*
 * LOADER_PARAMETER_BLOCK construction + PE image loader.
 *
 * Phases:
 *
 *   1. loaderblock_stage_images()
 *        For ntoskrnl.exe and hal.dll, parse the PE header of the file
 *        blob we read via fs_read, allocate a fresh SizeOfImage-sized
 *        buffer (via mmu_alloc with PK_KERNEL_IMAGE / PK_HAL_IMAGE),
 *        copy each section to its VirtualAddress+ImageBase offset,
 *        apply base relocations (since ImageBase may not match where
 *        we landed).
 *
 *        Outputs per image:
 *          - image_base_kseg0   (KSEG0|phys of staged copy)
 *          - size_of_image
 *          - entry_point_kseg0  (KSEG0|image_base + AddressOfEntryPoint)
 *
 *   2. loaderblock_build()
 *        Allocate a page for the LOADER_PARAMETER_BLOCK itself and
 *        accessory buffers (Arc* strings, NlsData, ArcDiskInformation,
 *        LoadOrder entries, BootDriver entries, MemoryDescriptor entries
 *        emitted by memmap_to_nt).
 *
 *        Populate with KSEG0 pointers directly:
 *          LoadOrderListHead  = { ntoskrnl, hal }
 *          BootDriverListHead = { atdisk, fastfat } referencing LoaderBootDriver
 *                                phys/size from the registry
 *          MemoryDescriptorListHead = link every NtMemEntry into a list
 *          NlsData -> { Ansi(1252), Oem(437), Unicode(l_intl) }
 *          RegistryBase/RegistryLength
 *          ArcBootDeviceName / ArcHalDeviceName / NtBootPathName / NtHalPathName
 *          ArcDiskInformation -> disk GUID entry (phase 2 — for now MBR stub)
 *          I386.{CommonDataArea, MachineType}
 *          KernelStack (idle stack top, KSEG0)
 *          Thread      (idle thread ETHREAD placeholder page, KSEG0)
 *          ConfigurationRoot -> single SystemClass node
 *
 *   3. loaderblock_handoff()
 *        Returns (kernel_entry_kseg0, loader_block_kseg0) for handoff.S.
 */
#ifndef _BOOT_EFI_LOADERBLOCK_H_
#define _BOOT_EFI_LOADERBLOCK_H_

#include <efi.h>
#include "pe.h"

/* Stage a PE image (ntoskrnl / hal / driver): parse headers, copy sections,
 * apply relocations. `file_blob` + `file_size` are the bytes we got from
 * fs_read. `kind` selects the PageKind for the newly-staged image pages.
 * Outputs:
 *   *out_base        = phys of staged copy (KSEG0|this gives virtual)
 *   *out_size        = staged SizeOfImage
 *   *out_entry_offset= AddressOfEntryPoint (add to image base for entry) */
EFI_STATUS loaderblock_stage_pe(const void *file_blob, UINTN file_size,
                                int kind,
                                EFI_PHYSICAL_ADDRESS *out_base,
                                UINTN *out_size,
                                UINT32 *out_entry_offset);

/* Must be called before loaderblock_build() so NlsData pointers can be
 * written. The three code-page tables MUST live in one contiguous block
 * (NT's Phase1Initialization computes UnicodeCaseTableData as an offset
 * from AnsiCodePageData — see NTOS/INIT/INIT.C:392). */
void loaderblock_set_nls(EFI_PHYSICAL_ADDRESS base_phys,
                         UINTN ansi_off, UINTN oem_off, UINTN uni_off);

EFI_STATUS loaderblock_build(void);

/* After build() + all images staged, wire LoadOrderList and BootDriverList
 * with KSEG0 pointers into each pe_image_t. The kernel/hal pair are
 * required; drivers may be zero. */
EFI_STATUS loaderblock_wire_modules(const pe_image_t *kernel,
                                    const pe_image_t *hal,
                                    const pe_image_t *boot_drivers,
                                    UINTN n_boot_drivers);

/* After memmap_capture + wire_modules: link the memory descriptors
 * captured by memmap_capture into the LoaderBlock's list. Does not
 * allocate UEFI pages, so MapKey stays valid for ExitBootServices. */
EFI_STATUS loaderblock_link_memmap(void);

/* Returns the KSEG0 virtual address of the LOADER_PARAMETER_BLOCK. */
unsigned long loaderblock_handoff_ptr(void);

/* Returns the KSEG0 virtual address of KiSystemStartup. */
unsigned long loaderblock_kernel_entry(void);

#endif
