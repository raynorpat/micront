/*
 * MicroNT UEFI loader — efi_main entry + orchestration.
 *
 * Flow:
 *   1. com1_init              - serial alive before anything else
 *   2. InitializeLib          - gnu-efi globals (gBS, ST, etc.)
 *   3. fs_init + fs_read      - pull ntoskrnl / hal / drivers / NLS / hive
 *   4. pe_stage               - relocate PE images to their bases
 *   5. mmu_alloc_reserved     - grab pages for PD/PT/PCR/TSS/stack
 *   6. arena_init             - reserve the arena for LPB + hwtree
 *   7. hwtree_build           - ARC config tree (disk geometry + UART probe)
 *   8. lpb_build + wire       - LOADER_PARAMETER_BLOCK and its lists
 *   9. mmu_register_image     - identity-map loader image + current stack
 *   10. mmu_alloc_pt_pool     - size PT pool (last UEFI allocation)
 *   11. memmap_capture        - final UEFI memory map, remember MapKey
 *   12. lpb_link_memmap       - translate + attach descriptor list (no UEFI)
 *   13. ExitBootServices      - point of no return; UEFI services gone
 *   14. mmu_build_and_activate - 32-bit PD/PT/GDT/IDT/TSS in memory
 *   15. handoff()             - 64→32 mode drop + jump to KiSystemStartup
 */

#include <efi.h>
#include <efilib.h>

#include "com1.h"
#include "log.h"
#include "fs.h"
#include "memmap.h"
#include "mmu.h"
#include "arena.h"
#include "hwtree.h"
#include "lpb.h"
#include "pe.h"

extern void handoff(unsigned long entry_kseg0,
                    unsigned long loader_block_kseg0,
                    unsigned long stack_top_kseg0,
                    unsigned long pd_phys,
                    unsigned long gdt_phys,
                    unsigned long idt_phys);

EFI_STATUS EFIAPI efi_main(EFI_HANDLE ImageHandle,
                           EFI_SYSTEM_TABLE *SystemTable) {
    EFI_INPUT_KEY key;

    com1_init();
    InitializeLib(ImageHandle, SystemTable);
    BXLOG(L"loader entered; FirmwareVendor=%s FirmwareRevision=%x",
          SystemTable->FirmwareVendor, SystemTable->FirmwareRevision);

    if (fs_init(ImageHandle) != EFI_SUCCESS) goto halt;

    /* Load what the kernel handoff needs: the kernel itself, HAL, every
     * candidate boot-disk driver (atdisk for legacy IDE, scsiport+
     * scsidisk+nvme2k for NVMe, vioblk for virtio-blk), the FS drivers
     * (fastfat for FAT16, ntfs for NTFS volumes), the registry hive,
     * and NLS.  We pre-load *all* candidate disk + FS drivers
     * unconditionally — discovery in each driver's DriverEntry decides
     * which one binds at runtime.  Same image boots on pc+IDE (atdisk
     * wins, nvme2k+vioblk bail on PCI walk), q35+NVMe (nvme2k claims),
     * q35+virtio-blk (vioblk claims).  fastfat claims FAT16 volumes;
     * ntfs returns STATUS_UNRECOGNIZED_VOLUME on FAT BPBs (no NTFS
     * volumes today — driver loaded but inactive).  All ErrorControl=
     * Normal so no-hardware/no-volume returns are logged not
     * bugchecked.  User-mode images (ntdll, kernel32) stay on disk. */
    void *blob_kernel   = 0, *blob_hal      = 0;
    void *blob_atdisk   = 0, *blob_scsiport = 0;
    void *blob_scsidisk = 0, *blob_nvme2k   = 0;
    void *blob_vioblk   = 0, *blob_fastfat  = 0;
    void *blob_ntfs     = 0;
    UINTN sz_kernel, sz_hal;
    UINTN sz_atdisk, sz_scsiport, sz_scsidisk, sz_nvme2k, sz_vioblk, sz_fastfat, sz_ntfs;
    {
        void  *buf;
        UINTN  size;
        fs_read(L"\\System32\\ntoskrnl.exe",            PK_FIRMWARE_TEMP, &blob_kernel,   &sz_kernel);
        fs_read(L"\\System32\\hal.dll",                  PK_FIRMWARE_TEMP, &blob_hal,      &sz_hal);
        fs_read(L"\\System32\\Drivers\\atdisk.sys",      PK_FIRMWARE_TEMP, &blob_atdisk,   &sz_atdisk);
        fs_read(L"\\System32\\Drivers\\scsiport.sys",    PK_FIRMWARE_TEMP, &blob_scsiport, &sz_scsiport);
        fs_read(L"\\System32\\Drivers\\scsidisk.sys",    PK_FIRMWARE_TEMP, &blob_scsidisk, &sz_scsidisk);
        fs_read(L"\\System32\\Drivers\\nvme2k.sys",      PK_FIRMWARE_TEMP, &blob_nvme2k,   &sz_nvme2k);
        fs_read(L"\\System32\\Drivers\\vioblk.sys",      PK_FIRMWARE_TEMP, &blob_vioblk,   &sz_vioblk);
        fs_read(L"\\System32\\Drivers\\fastfat.sys",     PK_FIRMWARE_TEMP, &blob_fastfat,  &sz_fastfat);
        fs_read(L"\\System32\\Drivers\\ntfs.sys",        PK_FIRMWARE_TEMP, &blob_ntfs,     &sz_ntfs);
        fs_read(L"\\System32\\config\\SYSTEM",           PK_REGISTRY,      &buf, &size); (void)size;
        (void)buf;
    }

    /* NLS: NT's Phase1Initialization (NTOS/INIT/INIT.C:392) computes
     * UnicodeCaseTableData and OemCodePageData as BYTE OFFSETS from
     * AnsiCodePageData, so the three tables MUST live in one contiguous
     * block. Probe each file's size, lay them out page-aligned back-to-
     * back, alloc once, read each into its slot. */
    {
        struct { const CHAR16 *path; UINTN size, off; } nls[] = {
            /* Order matches NLS_DATA_BLOCK: Ansi, Oem, UnicodeCase */
            { L"\\System32\\c_1252.nls", 0, 0 },
            { L"\\System32\\c_437.nls",  0, 0 },
            { L"\\System32\\l_intl.nls", 0, 0 },
        };
        const UINTN N = sizeof(nls)/sizeof(nls[0]);
        UINTN total = 0;
        for (UINTN i = 0; i < N; i++) {
            if (fs_file_size(nls[i].path, &nls[i].size) != EFI_SUCCESS) {
                BXLOG(L"NLS size probe failed"); goto halt;
            }
            nls[i].off = total;
            total += (nls[i].size + 0xFFF) & ~0xFFFu;  /* page-align slab */
        }

        EFI_PHYSICAL_ADDRESS nls_phys;
        if (mmu_alloc((total + 0xFFF) >> 12, PK_NLS, &nls_phys) != EFI_SUCCESS) {
            BXLOG(L"NLS alloc failed"); goto halt;
        }
        {
            UINT8 *p = (UINT8 *)(UINTN)nls_phys;
            for (UINTN i = 0; i < total; i++) p[i] = 0;
        }

        UINTN nread;
        for (UINTN i = 0; i < N; i++) {
            fs_read_into(nls[i].path,
                         (UINT8 *)(UINTN)nls_phys + nls[i].off,
                         nls[i].size, &nread);
        }

        lpb_set_nls(nls_phys, nls[0].off, nls[1].off, nls[2].off);
    }

    /* Stage kernel + HAL + boot drivers via the PE loader: sections to
     * their virtual addresses, base relocations applied. Then resolve
     * imports so calls between modules get patched to real addresses.
     *
     * Drivers staged unconditionally as a profile-agnostic candidate
     * set: atdisk (legacy IDE), scsiport+scsidisk+nvme2k (NVMe via the
     * SCSI miniport stack), fastfat (FS).  Each disk driver decides at
     * DriverEntry whether its hardware is present; the losers return
     * STATUS_NO_SUCH_DEVICE and the kernel logs + skips.  Order in the
     * pre-load list doesn't dictate runtime load order — the kernel's
     * IopInitializeBootDrivers walks LoadOrderList by ServiceGroupOrder
     * and DependOnService dependencies. */
    static pe_image_t kernel, hal;
    static pe_image_t drivers[7];   /* atdisk, scsiport, nvme2k, vioblk, scsidisk, fastfat, ntfs */
    UINTN n_drivers = 0;
    {
        pe_image_t all[2 + 7];      /* kernel + hal + drivers[] */
        UINTN n = 0;

        /* Order matters: the kernel's IopInitializeBootDrivers walks
         * LoaderBlock->BootDriverListHead in the order we wire it here
         * (it does NOT re-sort by ServiceGroupOrder — real NT's
         * OSLOADER sorted before handoff; we hand-sort instead).
         *
         * Constraints:
         *   - scsiport.sys before any miniport (nvme2k / vioblk import
         *     the framework's ScsiPortInitialize).
         *   - All SCSI miniports (nvme2k, vioblk) before scsidisk:
         *     scsidisk's DriverEntry eagerly walks \Device\ScsiPort0..N
         *     and returns STATUS_NO_SUCH_DEVICE if the namespace is
         *     empty.  Loading scsidisk before any miniport has
         *     registered surfaces zero disks even when the hardware
         *     is present.
         *   - fastfat.sys at any point — it doesn't touch disk state
         *     at DriverEntry. */
        struct { void *blob; UINTN size; const char *name; } stage_list[] = {
            { blob_atdisk,   sz_atdisk,   "atdisk.sys"   },
            { blob_scsiport, sz_scsiport, "scsiport.sys" },
            { blob_nvme2k,   sz_nvme2k,   "nvme2k.sys"   },
            { blob_vioblk,   sz_vioblk,   "vioblk.sys"   },
            { blob_scsidisk, sz_scsidisk, "scsidisk.sys" },
            /* FS drivers last; they don't touch hardware at DriverEntry,
             * just register a recognizer with the I/O manager.  fastfat
             * before ntfs is alphabetic-ish; both probe each volume's
             * BPB at mount time, the matching one claims it. */
            { blob_fastfat,  sz_fastfat,  "fastfat.sys"  },
            { blob_ntfs,     sz_ntfs,     "ntfs.sys"     },
        };
        const UINTN N_STAGE = sizeof(stage_list) / sizeof(stage_list[0]);

        if (blob_kernel && pe_stage(blob_kernel, sz_kernel,
                                    PK_KERNEL_IMAGE, "ntoskrnl.exe",
                                    &kernel) == EFI_SUCCESS) all[n++] = kernel;
        if (blob_hal && pe_stage(blob_hal, sz_hal,
                                 PK_HAL_IMAGE, "hal.dll",
                                 &hal) == EFI_SUCCESS) all[n++] = hal;

        /* Reserve ONE contiguous sub-16 MiB block for every boot driver and
         * have pe_stage pack them into it. The drivers all share ImageBase
         * 0x10000, so without this only the first gets its preferred slot and
         * the rest scatter via AllocateMaxAddress — nondeterministic placement
         * that depends on the firmware's free-memory layout and interleaves
         * driver images with the LPB arena / machine-state pages. One block
         * makes staging deterministic and firmware-independent. */
        {
            UINTN drv_total = 0;
            for (UINTN i = 0; i < N_STAGE; i++)
                if (stage_list[i].blob)
                    drv_total += pe_image_pages(stage_list[i].blob, stage_list[i].size);
            EFI_PHYSICAL_ADDRESS drv_base = 0;
            if (drv_total &&
                mmu_alloc_below(drv_total, PK_BOOT_DRIVER, 0x01000000, &drv_base) == EFI_SUCCESS) {
                pe_set_driver_arena(drv_base, drv_total);
                BXLOG(L"driver arena: %u pages at phys 0x%lx", (UINT32)drv_total, (UINT64)drv_base);
            } else {
                BXLOG(L"driver arena reserve failed (%u pages) — per-image fallback",
                      (UINT32)drv_total);
            }
        }

        for (UINTN i = 0; i < N_STAGE; i++) {
            if (!stage_list[i].blob) {
                BXLOG(L"%a: missing blob, skipping", stage_list[i].name);
                continue;
            }
            if (pe_stage(stage_list[i].blob, stage_list[i].size,
                         PK_BOOT_DRIVER, stage_list[i].name,
                         &drivers[n_drivers]) == EFI_SUCCESS) {
                all[n++] = drivers[n_drivers];
                n_drivers++;
            } else {
                BXLOG(L"%a: pe_stage failed", stage_list[i].name);
            }
        }

        /* Two passes for ntoskrnl<->hal circular dep: both are staged
         * before any import resolution.  scsidisk imports scsiport,
         * nvme2k imports scsiport — same pre-stage-then-resolve pattern
         * handles those naturally. */
        for (UINTN i = 0; i < n; i++) pe_resolve_imports(&all[i], all, n);
    }

    /* Query boot disk geometry + MBR signature/checksum + partition
     * layout while UEFI is still up.  Geometry feeds atdisk's INT13
     * table (hwtree); MBR sig/checksum + partition numbers feed the
     * kernel's IopCreateArcNames matching + ArcBootDeviceName /
     * ArcHalDeviceName (lpb).
     *
     * Partition selection (single rule for all layouts):
     *   - Walk the 4 MBR partition entries in slot order.
     *   - If exactly one slot has type != 0 → that's both boot + HAL
     *     (single-partition layout).
     *   - Otherwise → HAL = first slot with type 0xEF (the UEFI ESP);
     *                 boot = first non-empty slot that isn't HAL.
     *     Fallback when there's no 0xEF slot (some firmware boots
     *     plain FAT type 0x06): HAL = first non-empty slot, boot =
     *     next non-empty slot. */
    UINT64 total_blocks = 0;
    UINT32 block_size   = 0;
    UINT32 mbr_sig      = 0;
    UINT32 mbr_neg_sum  = 0;
    UINT8  boot_part    = 1;
    UINT8  hal_part     = 1;
    if (fs_boot_disk_size(&total_blocks, &block_size) == EFI_SUCCESS) {
        /* Read MBR (sector 0). FAT/MBR sectors are 512 B; pad for safety. */
        static UINT8 mbr[4096] __attribute__((aligned(4)));
        if (fs_boot_disk_read_sector0(mbr, sizeof mbr) == EFI_SUCCESS) {
            UINT32 *dw = (UINT32 *)mbr;
            UINT32 sum = 0;
            for (int i = 0; i < 128; i++) sum += dw[i];
            mbr_neg_sum = (UINT32)-(INT32)sum;   /* so sum + ours == 0 */
            /* Disk signature lives at MBR offset 0x1B8 (4 bytes, LE). */
            mbr_sig = *(UINT32 *)(mbr + 0x1B8);
            BXLOG(L"MBR signature=0x%x sum=0x%x negsum=0x%x", mbr_sig, sum, mbr_neg_sum);

            /* Walk 4 partition entries at offset 0x1BE; type byte is
             * at entry[+4].  Slot index in MBR maps 1:1 onto NT's
             * partition(N) numbering. */
            UINT8 esp_slot      = 0;
            UINT8 first_used    = 0;
            UINT8 second_used   = 0;
            UINT8 first_non_esp = 0;
            int   n_used        = 0;
            for (int i = 0; i < 4; i++) {
                UINT8 *e = mbr + 0x1BE + i * 16;
                UINT8 type = e[4];
                if (type == 0) continue;
                UINT8 slot = (UINT8)(i + 1);
                n_used++;
                if (!first_used) first_used = slot;
                else if (!second_used) second_used = slot;
                if (type == 0xEF && !esp_slot) esp_slot = slot;
                if (type != 0xEF && !first_non_esp) first_non_esp = slot;
            }
            if (n_used == 0) {
                BXLOG(L"MBR has no usable partitions — boot will fail");
            } else if (n_used == 1) {
                boot_part = hal_part = first_used;
            } else if (esp_slot && first_non_esp) {
                hal_part  = esp_slot;
                boot_part = first_non_esp;
            } else if (esp_slot) {
                /* All non-empty slots are 0xEF — degenerate, treat
                 * the first as both. */
                boot_part = hal_part = esp_slot;
            } else {
                /* No 0xEF slot: assume firmware booted from slot 1
                 * (typical for raw-FAT bootable layouts), system on
                 * slot 2. */
                hal_part  = first_used;
                boot_part = second_used ? second_used : first_used;
            }
            BXLOG(L"layout: %d partitions, ArcBoot=partition(%d) ArcHal=partition(%d)",
                  n_used, boot_part, hal_part);
        } else {
            BXLOG(L"MBR read failed — ARC name match will fail");
        }
        lpb_set_boot_disk(mbr_sig, mbr_neg_sum, boot_part, hal_part);
    } else {
        BXLOG(L"boot disk size query failed — atdisk may not mount");
    }

    /* Wall-clock seed.  RT->GetTime() is a UEFI Runtime Service — it
     * doesn't allocate and Runtime Services survive ExitBootServices,
     * so timing is flexible.  HAL converts EFI_TIME → 100-ns since
     * 1601 at HAL init and anchors KeBootTime against the boot-time
     * TSC.  Year==0 sentinel = no seed (RT->GetTime failed); HAL falls
     * back to the old "1601" zero-time behaviour gracefully
     * (HalQueryRealTimeClock returns FALSE).  qemu / EC2 / GCE / Azure
     * all return UTC. */
    {
        EFI_TIME t = { 0 };
        EFI_STATUS s = uefi_call_wrapper(RT->GetTime, 2, &t, NULL);
        if (!EFI_ERROR(s)) {
            lpb_set_boot_time(&t);
            BXLOG(L"UEFI time: %u-%02u-%02u %02u:%02u:%02u tz=%d",
                  t.Year, t.Month, t.Day,
                  t.Hour, t.Minute, t.Second, t.TimeZone);
        } else {
            BXLOG(L"RT->GetTime failed: 0x%lx", (UINT64)s);
        }
    }

    /* Pre-exit: reserve the machine-state pages (PD, PCR, TSS, stacks). */
    mmu_alloc_reserved();

    /* Arena must exist BEFORE hwtree/lpb emit into it, and all these
     * mmu_alloc's must happen BEFORE memmap_capture or the MapKey
     * needed for ExitBootServices goes stale. */
    arena_init(LPB_ARENA_PAGES);

    /* Hardware inventory (disk CHS + UART probe → MultifunctionAdapter /
     * SerialController tree). Returned KSEG0 VA becomes the LPB's
     * ConfigurationRoot, which the kernel materialises under
     * \Registry\Machine\Hardware\Description\System. */
    {
        hwtree_disk_info hw = {
            .total_blocks = total_blocks,
            .block_size   = block_size,
        };
        lpb_set_configuration_root(hwtree_build(&hw));
    }

    /* LOADER_PARAMETER_BLOCK + its referenced lists + strings. */
    lpb_build();
    lpb_wire_modules(&kernel, &hal, drivers, n_drivers);

    /* Identity-map the loader image. UEFI can place our PE anywhere in
     * available RAM (including above 256 MB on larger guests), so rather
     * than blanket-mapping a fixed window, we ask LoadedImageProtocol
     * where we are and register the exact range. */
    {
        static EFI_GUID lip_guid = LOADED_IMAGE_PROTOCOL;
        EFI_LOADED_IMAGE_PROTOCOL *lip = 0;
        EFI_STATUS s = uefi_call_wrapper(BS->HandleProtocol, 3,
                                         ImageHandle, &lip_guid, (void **)&lip);
        if (!EFI_ERROR(s) && lip) {
            UINTN base  = (UINTN)lip->ImageBase;
            UINTN size  = (UINTN)lip->ImageSize;
            UINTN start = base & ~0xFFFul;
            UINTN end   = (base + size + 0xFFFul) & ~0xFFFul;
            mmu_register_image(start, (end - start) >> 12);
        } else {
            BXLOG(L"LoadedImageProtocol failed; identity map may miss loader");
        }
    }

    /* Identity-map the current stack too — we keep using it until
     * handoff.S switches to the KSEG0 idle stack. Snapshot ESP now and
     * register the page containing it plus a few pages below for the
     * frames mmu_build_and_activate + handoff() will use. UEFI hands us
     * stacks that are typically 16 KB; 8 pages of identity cover well
     * past any realistic depth from here to the stack switch. */
    {
        UINTN rsp;
        __asm__ volatile("mov %%rsp, %0" : "=r"(rsp));
        UINTN top    = (rsp + 0xFFFul) & ~0xFFFul;
        UINTN bottom = (top - 8 * 0x1000) & ~0xFFFul;
        mmu_register_image(bottom, 8);
    }

    /* Size + allocate the PT pool now that every identity/KSEG0 input
     * is known. Must be the last UEFI allocation before memmap_capture. */
    mmu_alloc_pt_pool();

    /* Last UEFI allocation happened above. Capture the map now — no
     * UEFI-side allocation may occur between here and ExitBootServices. */
    UINTN map_key = 0;
    memmap_capture(&map_key);

    /* Descriptor linking is pure arena writes — safe after capture. */
    lpb_link_memmap();

    /* Stamp CMOS so atdisk.sys finds our IDE drive.
     *
     * NT 3.5's atdisk reads CMOS byte 0x12 (via RTC index 0x70 / data 0x71)
     * to learn which drives are installed on the primary IDE controller.
     * High nibble = drive 0 type (0xF = "extended type, see byte 0x19"),
     * low nibble = drive 1. If both nibbles are zero, atdisk treats the
     * controller as empty and stops before probing hardware (see
     * NTOS/DD/HARDDISK/I386/ATD_CONF.C:499). Legacy BIOSes populated CMOS
     * during POST; OVMF does not, so we do it here. 0x19 = 47 is the
     * "user-defined type" marker — the value itself doesn't matter because
     * atdisk's IssueIdentify will query real geometry from the drive. */
    {
        __asm__ volatile(
            "outb %%al, $0x70\n\t"      /* index = 0x12 */
            "movb $0x12, %%al\n\t"
            "outb %%al, $0x70\n\t"
            "movb $0xF0, %%al\n\t"      /* drive0=ext, drive1=none */
            "outb %%al, $0x71\n\t"
            "movb $0x19, %%al\n\t"      /* index = 0x19 */
            "outb %%al, $0x70\n\t"
            "movb $47,   %%al\n\t"      /* user-defined type */
            "outb %%al, $0x71\n\t"
            : : : "al");
    }

    /* --------------------------------------------------------------------
     * Point of no return. UEFI services will be gone after this call.
     *
     * Retry loop: UEFI 2.10 §7.4.2 mandates that on EFI_INVALID_PARAMETER
     * (stale map_key) the caller refresh the memory map and retry.  OVMF's
     * UEFI IDE driver on q35 (PIIX3-IDE bridge) has been observed allocating
     * between our memmap_capture and this call — locally and on most other
     * disk shapes the race never closes, but on CI's q35+ide it triggered
     * deterministically after our kernel binary shrank by ~7 pages and
     * shifted the allocator pattern.  memmap_refresh_key() reuses the
     * already-allocated buffer, so it doesn't itself invalidate the key it
     * returns.  Three attempts is generous; one retry is what the spec
     * implies should suffice. */
    {
        EFI_STATUS s = EFI_LOAD_ERROR;
        for (int attempt = 0; attempt < 3; attempt++) {
            s = uefi_call_wrapper(BS->ExitBootServices, 2,
                                  ImageHandle, map_key);
            if (!EFI_ERROR(s)) break;
            if (s != EFI_INVALID_PARAMETER) break;  /* non-key error: give up */
            if (memmap_refresh_key(&map_key) != EFI_SUCCESS) break;
        }
        if (EFI_ERROR(s)) {
            BXLOG(L"ExitBootServices failed: 0x%lx", (UINT64)s);
            goto halt;
        }
    }

    /* No Print() / ConOut from here on — COM1 only. */
    mmu_build_and_activate();
    com1_puts("boot!efi_main: handoff to KiSystemStartup\n");
    /* Pass GDT/IDT as phys — handoff.S does the KSEG0 remap. We need the
     * long-mode LGDT (before the mode drop) to access the GDT via UEFI's
     * identity PML4, which only maps phys. But once the NT kernel takes
     * over and switches CR3 to a new process PD, MmCreateProcessAddressSpace
     * (NTOS/MM/PROCSUP.C:297-305) copies only PDE[512..515] + the non-paged
     * range into that new PD; the identity PDEs [0..511] are NOT copied, so
     * any descriptor referenced by its phys address becomes unreachable and
     * the next trap triple-faults. Fix is in handoff.S: after the CR3 swap
     * to our NT PD (which has both identity + KSEG0), re-LGDT/LIDT with the
     * KSEG0-aliased base so the descriptor tables stay reachable forever. */
    handoff(lpb_kernel_entry(),
            lpb_handoff_ptr(),
            mmu_handoff_stack_top(),
            (unsigned long)mmu_pd_base(),
            (unsigned long)mmu_gdt_base(),
            (unsigned long)mmu_idt_base());

    /* Unreachable — handoff never returns. */
    com1_puts("boot!efi_main: kernel returned!?\n");

halt:

    com1_puts("boot!efi_main: halt\n");

    /* Wait for a keypress so the serial log is readable in interactive runs. */
    SystemTable->ConIn->Reset(SystemTable->ConIn, FALSE);
    while (SystemTable->ConIn->ReadKeyStroke(SystemTable->ConIn, &key)
           == EFI_NOT_READY) { }

    /* Unreached for now: handoff(lpb_kernel_entry(),
     *                           lpb_handoff_ptr()); */
    return EFI_SUCCESS;
}
