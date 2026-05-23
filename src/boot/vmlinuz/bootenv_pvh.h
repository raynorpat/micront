/*
 * PVH implementation of the bootenv service contract (boot/bootenv.h):
 * be_memory_regions() (from hvm_start_info's e820) and be_alloc_pages()
 * (a bump allocator over free RAM). Call pvh_bootenv_init() once with the
 * start_info before the shared core uses either.
 */
#ifndef _BOOT_VMLINUZ_BOOTENV_PVH_H_
#define _BOOT_VMLINUZ_BOOTENV_PVH_H_

#include "pvh.h"

void pvh_bootenv_init(const struct hvm_start_info *si);

#endif
