/*
 * MicroNT vmlinuz (PVH) entry — boot orchestration.
 *
 * Reached from head.S in 32-bit protected mode with the hvm_start_info
 * physical address. Runs the same load/stage/build sequence as the EFI
 * entry (boot/efi/main.c), but sourcing files from the in-RAM initrd
 * (FAT16) instead of the UEFI filesystem, and with no ExitBootServices
 * (the e820 map is already ours). Ends by materialising the NT page
 * tables; the 32-bit handoff stub (next) does the actual jump.
 *
 * This first cut stages kernel + HAL + hive + NLS (no boot drivers yet)
 * and halts before the handoff, so the load/LPB/page-table flow can be
 * verified against a real NT image before the handoff lands.
 */
#include "pvh.h"
#include "com1.h"
#include "log.h"
#include "cmdline.h"
#include "bootenv_pvh.h"
#include "fatread.h"
#include "mmu.h"
#include "arena.h"
#include "hwtree.h"
#include "lpb.h"
#include "pe.h"
#include "bootdrv.h"

/* Loader image extent, from vmlinux.lds (identity-mapped for handoff). */
extern char _image_start[];
extern char _image_end[];

void vmlinuz_main(uint32_t start_info_phys);

/* The 32-bit handoff stub (handoff.S): installs NT's CR3/GDT/IDT/TSS state
 * and jumps into KiSystemStartup. Same argument order as the EFI handoff. */
extern void vmlinuz_handoff(unsigned long entry, unsigned long lpb,
                            unsigned long stack_top, unsigned long pd_phys,
                            unsigned long gdt_phys, unsigned long idt_phys);

static UINT32 rd32(const UINT8 *p) {
    return p[0] | ((UINT32)p[1] << 8) | ((UINT32)p[2] << 16) | ((UINT32)p[3] << 24);
}

void vmlinuz_main(uint32_t start_info_phys) {
    com1_init();
    BXLOG(L"PVH entry");

    const struct hvm_start_info *si =
        (const struct hvm_start_info *)(uintptr_t)start_info_phys;
    if (!si || si->magic != HVM_START_MAGIC) {
        BXLOG(L"bad/absent hvm_start_info magic");
        return;
    }
    pvh_bootenv_init(si);

    /* The initrd (module[0]) is our boot volume — an MBR + FAT16 image. */
    if (!si->nr_modules || !si->modlist_paddr) {
        BXLOG(L"no initrd module"); return;
    }
    const struct hvm_modlist_entry *m =
        (const struct hvm_modlist_entry *)(uintptr_t)si->modlist_paddr;
    const UINT8 *initrd = (const UINT8 *)(uintptr_t)m[0].paddr;
    UINT32 initrd_size  = (UINT32)m[0].size;
    if (fat_mount(initrd, initrd_size) != 0) {
        BXLOG(L"fat_mount failed"); return;
    }
    BXLOG(L"initrd mounted (%lu bytes)", (UINT64)initrd_size);

    /* Reserve the initrd region in the NT memory map (LoaderFirmwarePermanent)
     * so MM won't reclaim it — ramscsi serves it as the system volume. It's
     * memmap-overlay only (ramscsi maps it on demand; no identity/KSEG0). */
    {
        UINT32 rd_lo = (UINT32)(uintptr_t)initrd & ~0xFFFu;
        UINT32 rd_hi = ((UINT32)(uintptr_t)initrd + initrd_size + 0xFFFu) & ~0xFFFu;
        mmu_reserve(rd_lo, (rd_hi - rd_lo) >> 12, PK_FIRMWARE_PERM);
    }

    /* Load kernel, HAL (temp blobs, pe_stage relocates them later) + hive. */
    UINT32 ksz = 0, hsz = 0, vsz = 0;
    void *blob_kernel = fat_read("System32/ntoskrnl.exe", PK_FIRMWARE_TEMP, &ksz);
    void *blob_hal    = fat_read("System32/hal.dll",       PK_FIRMWARE_TEMP, &hsz);
    void *hive        = fat_read("System32/config/SYSTEM", PK_REGISTRY,      &vsz);
    if (!blob_kernel || !blob_hal || !hive) {
        BXLOG(L"missing ntoskrnl/hal/hive"); return;
    }
    (void)hive;   /* lpb finds the hive via the PK_REGISTRY registry entry */
    BXLOG(L"loaded ntoskrnl=%lu hal=%lu hive=%lu",
          (UINT64)ksz, (UINT64)hsz, (UINT64)vsz);

    /* NLS: c_1252 / c_437 / l_intl in one contiguous, page-aligned block —
     * Phase1Initialization computes the case-table offsets from the ANSI
     * base, so they must be adjacent. */
    {
        struct { const char *path; UINT32 size, off; } nls[] = {
            { "System32/c_1252.nls", 0, 0 },   /* Ansi */
            { "System32/c_437.nls",  0, 0 },   /* Oem  */
            { "System32/l_intl.nls", 0, 0 },   /* UnicodeCase */
        };
        UINT32 total = 0;
        for (int i = 0; i < 3; i++) {
            if (fat_file_size(nls[i].path, &nls[i].size) != 0) {
                BXLOG(L"NLS size probe failed (%a)", nls[i].path); return;
            }
            nls[i].off = total;
            total += (nls[i].size + 0xFFF) & ~0xFFFu;
        }
        EFI_PHYSICAL_ADDRESS nls_phys;
        if (mmu_alloc((total + 0xFFF) >> 12, PK_NLS, &nls_phys) != EFI_SUCCESS) {
            BXLOG(L"NLS alloc failed"); return;
        }
        UINT8 *p = (UINT8 *)(UINTN)nls_phys;
        for (UINT32 i = 0; i < total; i++) p[i] = 0;
        for (int i = 0; i < 3; i++) {
            UINT32 got;
            fat_read_into(nls[i].path, p + nls[i].off, nls[i].size, &got);
        }
        lpb_set_nls(nls_phys, nls[0].off, nls[1].off, nls[2].off);
        BXLOG(L"NLS block at 0x%lx (%lu bytes)", (UINT64)nls_phys, (UINT64)total);
    }

    /* Stage kernel + HAL + boot drivers: sections to their bases,
     * relocations applied, then resolve imports in one pass (ntoskrnl<->hal
     * circular, plus each driver against ntoskrnl/hal — and scsidisk/nvme2k
     * against scsiport).  Boot drivers come from the \Boot\<NN>\ tree on the
     * initrd via the shared walk (stage_boot_drivers, over the bfs_* FAT
     * binding in bootfs_pvh.c). */
    static pe_image_t kernel, hal;
    static pe_image_t drivers[MAX_BOOT_DRIVERS];
    UINTN n_drivers = 0;
    {
        pe_image_t all[2 + MAX_BOOT_DRIVERS];   /* kernel + hal + drivers[] */
        UINTN n = 0;
        if (pe_stage(blob_kernel, ksz, PK_KERNEL_IMAGE, "ntoskrnl.exe",
                     &kernel) == EFI_SUCCESS) all[n++] = kernel;
        if (pe_stage(blob_hal, hsz, PK_HAL_IMAGE, "hal.dll",
                     &hal) == EFI_SUCCESS) all[n++] = hal;
        if (n != 2) { BXLOG(L"pe_stage failed"); return; }
        n_drivers = stage_boot_drivers(drivers, MAX_BOOT_DRIVERS);
        for (UINTN i = 0; i < n_drivers; i++) all[n++] = drivers[i];
        for (UINTN i = 0; i < n; i++) pe_resolve_imports(&all[i], all, n);
    }
    BXLOG(L"staged ntoskrnl + hal + %lu boot driver(s)", (UINT64)n_drivers);

    /* Hand the RAM disk's physical base+size to whichever staged boot driver
     * declares a RAMDCFG section (ramscsi). We link the driver image, so we
     * init its own data directly — no ntoskrnl export needed. Layout:
     * { ULONG magic='RAMD', base, len }. */
    for (UINTN i = 0; i < n_drivers; i++) {
        EFI_PHYSICAL_ADDRESS sec_phys;
        UINT32 sec_size;
        if (pe_find_section(&drivers[i], "RAMDCFG", &sec_phys, &sec_size)
            != EFI_SUCCESS)
            continue;
        volatile UINT32 *cfg = (volatile UINT32 *)(UINTN)sec_phys;
        if (sec_size >= 12 && cfg[0] == 0x52414D44u /* 'RAMD' */) {
            cfg[1] = (UINT32)(uintptr_t)initrd;   /* base (sector 0 = MBR) */
            cfg[2] = initrd_size;                 /* length in bytes */
            BXLOG(L"RAMDCFG <- %a: base=0x%x len=%u",
                  drivers[i].name, (UINT32)(uintptr_t)initrd, initrd_size);
        }
    }

    /* Boot-disk identity from the initrd's MBR (single FAT16 partition →
     * boot = HAL = partition 1). Signature at 0x1B8; checksum is the two's
     * complement of the first 128 DWORDs so the kernel's sum nets to 0. */
    {
        const UINT32 *dw = (const UINT32 *)initrd;
        UINT32 sum = 0;
        for (int i = 0; i < 128; i++) sum += dw[i];
        UINT32 mbr_sig = rd32(initrd + 0x1B8);
        lpb_set_boot_disk(mbr_sig, (UINT32)-(INT32)sum, 1, 1);
        BXLOG(L"boot disk sig=0x%x", mbr_sig);
    }

    /* Reserved <16 MiB core pages, the arena, the hardware tree, the
     * command line — same shared builders the EFI entry uses. */
    if (mmu_alloc_reserved() != EFI_SUCCESS) {
        BXLOG(L"mmu_alloc_reserved failed"); return;
    }
    arena_init(LPB_ARENA_PAGES);
    {
        hwtree_disk_info hw = {
            .total_blocks = initrd_size / 512,
            .block_size   = 512,
        };
        lpb_set_configuration_root(hwtree_build(&hw));
    }
    {
        const char *entry_cmd = si->cmdline_paddr
            ? (const char *)(uintptr_t)si->cmdline_paddr : 0;
        char opts[256];
        cmdline(entry_cmd, opts, sizeof opts);
        lpb_set_load_options(opts);
    }

    /* LOADER_PARAMETER_BLOCK + module wiring (kernel, HAL, boot drivers). */
    lpb_build();
    lpb_wire_modules(&kernel, &hal, drivers, n_drivers);

    /* Identity-map our own image (covers the boot stack + the handoff
     * stub) so we survive the CR3 swap, like EFI's mmu_register_image. */
    {
        EFI_PHYSICAL_ADDRESS base = (EFI_PHYSICAL_ADDRESS)(UINTN)_image_start;
        UINTN pages = ((UINTN)(_image_end - _image_start) + 0xFFF) >> 12;
        mmu_register_image(base, pages);
    }

    mmu_alloc_pt_pool();
    lpb_link_memmap();          /* e820 -> NT descriptors; no ExitBootServices */
    mmu_build_and_activate();   /* materialise PD/PT/GDT/IDT/TSS (no CR3 yet) */

    BXLOG(L"staged + LPB + page tables built; handoff -> KiSystemStartup");
    /* Casts mirror boot/efi/main.c: mmu_*_base() return EFI_PHYSICAL_ADDRESS
     * (64-bit); the stub takes them as 4-byte cdecl args (all <16 MiB). */
    vmlinuz_handoff(lpb_kernel_entry(), lpb_handoff_ptr(), mmu_handoff_stack_top(),
                    (unsigned long)mmu_pd_base(),
                    (unsigned long)mmu_gdt_base(),
                    (unsigned long)mmu_idt_base());
}
