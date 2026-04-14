/*
 * MicroNT UEFI loader — efi_main entry + orchestration.
 *
 * Flow:
 *   1. com1_init            - serial alive before anything else
 *   2. InitializeLib        - gnu-efi globals (gBS, ST, etc.)
 *   3. fs_init              - find the ESP we were loaded from
 *   4. fs_read              - pull ntoskrnl.exe, hal.dll, config/SYSTEM, NLS
 *   5. mmu_alloc_reserved   - grab pages for PD/PT/PCR/TSS/stack
 *   6. loaderblock_build    - stitch LOADER_PARAMETER_BLOCK
 *   7. memmap_capture       - final UEFI memory map, remember MapKey
 *   8. ExitBootServices     - point of no return; UEFI services gone
 *   9. memmap_to_nt         - translate captured map into NT descriptors
 *   10. mmu_build_and_activate - page tables on, GDT/IDT/TSS at KSEG0
 *   11. loaderblock_kseg0_fixup - retarget every internal pointer
 *   12. handoff()           - jump to KiSystemStartup
 *
 * Phase 1 skeleton runs steps 1-2, logs where the other steps would
 * start, and halts. Subsequent commits fill in each stage.
 */

#include <efi.h>
#include <efilib.h>

#include "com1.h"
#include "fs.h"
#include "memmap.h"
#include "mmu.h"
#include "loaderblock.h"
#include "pe.h"

extern void handoff(unsigned long entry_kseg0,
                    unsigned long loader_block_kseg0,
                    unsigned long stack_top_kseg0);

EFI_STATUS EFIAPI efi_main(EFI_HANDLE ImageHandle,
                           EFI_SYSTEM_TABLE *SystemTable) {
    EFI_INPUT_KEY key;

    com1_init();
    com1_puts("\n[MicroNT EFI] loader entered\n");

    InitializeLib(ImageHandle, SystemTable);
    Print(L"MicroNT UEFI loader (Phase 1 skeleton)\n");
    Print(L"FirmwareVendor=%s FirmwareRevision=%x\n",
          SystemTable->FirmwareVendor, SystemTable->FirmwareRevision);

    if (fs_init(ImageHandle) != EFI_SUCCESS) goto halt;

    /* Load only what the kernel handoff needs: the kernel itself, HAL,
     * the boot drivers required to mount the boot volume (atdisk + fastfat),
     * the registry hive, and the NLS tables. User-mode images (smss,
     * ntdll, kernel32) stay on-disk — the kernel mounts the boot volume
     * via atdisk+fastfat and reads them at runtime, just like OSLOADER. */
    void *blob_kernel  = 0, *blob_hal    = 0;
    void *blob_atdisk  = 0, *blob_fastfat = 0;
    UINTN sz_kernel, sz_hal, sz_atdisk, sz_fastfat, sz_dummy;
    {
        void  *buf;
        UINTN  size;
        fs_read(L"\\System32\\ntoskrnl.exe",          PK_FIRMWARE_TEMP, &blob_kernel,  &sz_kernel);
        fs_read(L"\\System32\\hal.dll",                PK_FIRMWARE_TEMP, &blob_hal,     &sz_hal);
        fs_read(L"\\System32\\Drivers\\atdisk.sys",    PK_FIRMWARE_TEMP, &blob_atdisk,  &sz_atdisk);
        fs_read(L"\\System32\\Drivers\\fastfat.sys",   PK_FIRMWARE_TEMP, &blob_fastfat, &sz_fastfat);
        fs_read(L"\\System32\\config\\SYSTEM",         PK_REGISTRY,     &buf, &size); (void)size;
        fs_read(L"\\System32\\c_1252.nls",             PK_NLS,          &buf, &sz_dummy);
        fs_read(L"\\System32\\c_437.nls",              PK_NLS,          &buf, &sz_dummy);
        fs_read(L"\\System32\\l_intl.nls",             PK_NLS,          &buf, &sz_dummy);
        (void)buf;
    }

    /* Stage kernel + HAL + boot drivers via the PE loader: sections to
     * their virtual addresses, base relocations applied. Then resolve
     * imports so calls between modules get patched to real addresses. */
    static pe_image_t kernel, hal;
    static pe_image_t drivers[2];
    UINTN n_drivers = 0;
    {
        pe_image_t all[4];
        UINTN n = 0;

        if (blob_kernel && pe_stage(blob_kernel, sz_kernel,
                                    PK_KERNEL_IMAGE, "ntoskrnl.exe",
                                    &kernel) == EFI_SUCCESS) all[n++] = kernel;
        if (blob_hal && pe_stage(blob_hal, sz_hal,
                                 PK_HAL_IMAGE, "hal.dll",
                                 &hal) == EFI_SUCCESS) all[n++] = hal;
        if (blob_atdisk && pe_stage(blob_atdisk, sz_atdisk,
                                    PK_BOOT_DRIVER, "atdisk.sys",
                                    &drivers[n_drivers]) == EFI_SUCCESS) {
            all[n++] = drivers[n_drivers]; n_drivers++;
        }
        if (blob_fastfat && pe_stage(blob_fastfat, sz_fastfat,
                                     PK_BOOT_DRIVER, "fastfat.sys",
                                     &drivers[n_drivers]) == EFI_SUCCESS) {
            all[n++] = drivers[n_drivers]; n_drivers++;
        }

        /* Two passes for ntoskrnl<->hal circular dep: both are staged
         * before any import resolution. */
        for (UINTN i = 0; i < n; i++) pe_resolve_imports(&all[i], all, n);
    }

    /* Pre-exit: reserve the machine-state pages (PD, PCR, TSS, stacks). */
    mmu_alloc_reserved();

    /* Build the LoaderBlock arena + static fields BEFORE memmap_capture,
     * otherwise the arena's mmu_alloc invalidates the MapKey needed for
     * ExitBootServices. */
    loaderblock_build();
    loaderblock_wire_modules(&kernel, &hal, drivers, n_drivers);

    /* Last UEFI allocation happened above. Capture the map now — no
     * UEFI-side allocation may occur between here and ExitBootServices. */
    UINTN map_key = 0;
    memmap_capture(&map_key);

    /* Descriptor linking is pure arena writes — safe after capture. */
    loaderblock_link_memmap();

    com1_puts("[main] LPB kseg0=");
    com1_put_hex(loaderblock_handoff_ptr());
    com1_puts("  kernel_entry=");
    com1_put_hex(loaderblock_kernel_entry());
    com1_puts("  MapKey=");
    com1_put_hex((unsigned long)map_key);
    com1_puts("\n");

    /* --------------------------------------------------------------------
     * Point of no return. UEFI services will be gone after this call. */
    com1_puts("[main] ExitBootServices...\n");
    {
        EFI_STATUS s = uefi_call_wrapper(BS->ExitBootServices, 2,
                                         ImageHandle, map_key);
        if (EFI_ERROR(s)) {
            com1_puts("[main] ExitBootServices failed: ");
            com1_put_hex((unsigned long)s);
            com1_puts("\n");
            goto halt;
        }
    }

    /* No Print() / ConOut from here on — COM1 only. */
    com1_puts("[main] building page tables / GDT / IDT / TSS\n");
    mmu_build_and_activate();

    com1_puts("[main] handoff to KiSystemStartup\n");
    handoff(loaderblock_kernel_entry(),
            loaderblock_handoff_ptr(),
            mmu_handoff_stack_top());

    /* Unreachable — handoff never returns. */
    com1_puts("[main] kernel returned!?\n");

halt:

    com1_puts("[MicroNT EFI] halt (no kernel handoff yet)\n");

    /* Wait for a keypress so the serial log is readable in interactive runs. */
    SystemTable->ConIn->Reset(SystemTable->ConIn, FALSE);
    while (SystemTable->ConIn->ReadKeyStroke(SystemTable->ConIn, &key)
           == EFI_NOT_READY) { }

    /* Unreached for now: handoff(loaderblock_kernel_entry(),
     *                           loaderblock_handoff_ptr()); */
    return EFI_SUCCESS;
}
