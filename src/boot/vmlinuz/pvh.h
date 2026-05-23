/*
 * x86/HVM direct boot (PVH) ABI structures.
 * Ref: xen/include/public/arch-x86/hvm/start_info.h
 *
 * QEMU (qemu-system-x86_64 -kernel, PVH direct boot) enters the kernel at
 * the XEN_ELFNOTE_PHYS32_ENTRY in 32-bit protected mode, paging off, flat
 * segments, with %ebx = physical address of struct hvm_start_info.
 */
#ifndef _BOOT_VMLINUZ_PVH_H_
#define _BOOT_VMLINUZ_PVH_H_

#include <stdint.h>

#define HVM_START_MAGIC 0x336ec578u   /* XEN_HVM_START_MAGIC_VALUE ("xEn3", 'E'|0x80) */

struct hvm_start_info {
    uint32_t magic;
    uint32_t version;
    uint32_t flags;
    uint32_t nr_modules;
    uint64_t modlist_paddr;     /* -> hvm_modlist_entry[nr_modules] */
    uint64_t cmdline_paddr;     /* -> NUL-terminated ASCII command line */
    uint64_t rsdp_paddr;
    /* version >= 1 */
    uint64_t memmap_paddr;      /* -> hvm_memmap_table_entry[memmap_entries] */
    uint32_t memmap_entries;
    uint32_t reserved;
};

struct hvm_modlist_entry {
    uint64_t paddr;             /* module (initrd) base phys */
    uint64_t size;             /* module size in bytes */
    uint64_t cmdline_paddr;
    uint64_t reserved;
};

struct hvm_memmap_table_entry {
    uint64_t addr;
    uint64_t size;
    uint32_t type;             /* E820 type */
    uint32_t reserved;
};

#endif /* _BOOT_VMLINUZ_PVH_H_ */
