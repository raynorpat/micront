/*
 * Structured diagnostic output for the boot loaders.
 *
 * One macro — BXLOG — prefixes every line with "boot!<function>: " so the
 * source of each message is self-evident in the log. It forwards to the
 * per-entry bxlog() sink — a real function, not Print directly, so the
 * shared core under boot/ stays firmware-agnostic:
 *
 *   - boot/efi/     : gnu-efi VPrint -> EFI ConOut (VGA + serial console).
 *   - boot/vmlinuz/ : a small wide-format printf -> COM1.
 *
 * Format strings are UEFI-style wide strings; specifiers match gnu-efi
 * Print: %a ASCII, %s CHAR16, %x/%lx hex, %u/%lu/%d decimal, %0Nu width:
 *
 *   BXLOG(L"MBR signature=0x%x sum=0x%x", sig, sum);
 *   BXLOG(L"alloc %u pages at 0x%lx for %a", pages, phys, kind_name);
 *
 * ==== Where BXLOG is safe vs. not (EFI entry only) ====
 *
 * The EFI bxlog() uses gnu-efi Print, so on that entry two boundaries
 * still matter (the vmlinuz com1 sink has neither — port I/O, no pool):
 *
 *   1. memmap_capture. Print allocates from the UEFI pool, invalidating
 *      the MapKey. Code paths between memmap_capture and ExitBootServices
 *      (lpb_link_memmap, memmap_to_nt post-translation logging) must NOT
 *      call BXLOG; stay purely on arena memory.
 *
 *   2. ExitBootServices. Print is gone after this. Post-exit call sites
 *      (mmu_build_and_activate, the handoff marker) use com1_puts directly.
 */
#ifndef _BOOT_EFI_LOG_H_
#define _BOOT_EFI_LOG_H_

#include "bootenv.h"   /* CHAR16 */

/* Per-entry log sink, implemented in boot/efi/ and boot/vmlinuz/. */
void bxlog(const CHAR16 *fmt, ...);

#define BXLOG(fmt, ...) \
    bxlog(L"boot!%a: " fmt L"\n", __func__, ##__VA_ARGS__)

#endif
