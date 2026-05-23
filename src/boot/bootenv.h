/*
 * bootenv.h — entry-agnostic facade for the shared boot core under boot/.
 *
 * The core is shared between boot entries (boot/efi/, and the planned
 * boot/vmlinuz/). So it can be compiled without binding to one firmware,
 * the core includes THIS header for its types/services instead of pulling
 * <efi.h> directly. It resolves to:
 *
 *   -DBOOTENV_EFI : the gnu-efi surface (types + Boot/Runtime services),
 *                   used by the UEFI entry. Identical to the pre-split
 *                   build — no behavioural change.
 *
 *   (otherwise)   : freestanding types + the entry service contract, for
 *                   firmware-less entries (vmlinuz/PVH). Added when that
 *                   entry lands; until then building the core without
 *                   BOOTENV_EFI is a hard error rather than silent.
 *
 * As each EFI-coupled bit is lifted out of the core into the per-entry
 * adapter (boot/efi/), its service seam (be_alloc_pages, be_memory_regions,
 * be_log, ...) is declared here and implemented per entry.
 */
#ifndef _BOOT_BOOTENV_H_
#define _BOOT_BOOTENV_H_

#if defined(BOOTENV_EFI)
#  include <efi.h>
#  include <efilib.h>
#else
/* ---- freestanding types (non-EFI entries: vmlinuz/PVH) ----------------
 * EFI-compatible names + widths so the shared core compiles unchanged.
 * UINTN/INTN are the native machine word (32-bit on i386); fixed-width
 * types are explicit; EFI_PHYSICAL_ADDRESS stays 64-bit. */
typedef unsigned char       UINT8;
typedef unsigned short      UINT16;
typedef unsigned int        UINT32;
typedef unsigned long long  UINT64;
typedef signed char         INT8;
typedef short               INT16;
typedef int                 INT32;
typedef long long           INT64;
typedef unsigned long       UINTN;
typedef long                INTN;
typedef unsigned char       BOOLEAN;
typedef unsigned short      CHAR16;
typedef char                CHAR8;
typedef void                VOID;
typedef UINT64              EFI_PHYSICAL_ADDRESS;
typedef UINTN               EFI_STATUS;

/* EFI_TIME — lpb.c's optional wall-clock seed (lpb_set_boot_time). Layout
 * matches UEFI's; a non-EFI entry can fill it from the RTC, or leave it
 * zero (Year == 0 means "no seed"). */
typedef struct {
    UINT16 Year;
    UINT8  Month, Day, Hour, Minute, Second, Pad1;
    UINT32 Nanosecond;
    INT16  TimeZone;
    UINT8  Daylight, Pad2;
} EFI_TIME;

#ifndef NULL
#  define NULL ((void *)0)
#endif
#ifndef TRUE
#  define TRUE  1
#endif
#ifndef FALSE
#  define FALSE 0
#endif

/* EFI_STATUS codes used by the shared core. The high bit of the
 * UINTN-wide status marks an error, per the EFI convention. */
#define BOOTENV_ERR(n) (((EFI_STATUS)1 << (sizeof(EFI_STATUS) * 8 - 1)) | (n))
#define EFI_SUCCESS            ((EFI_STATUS)0)
#define EFI_LOAD_ERROR         BOOTENV_ERR(1)
#define EFI_INVALID_PARAMETER  BOOTENV_ERR(2)
#define EFI_UNSUPPORTED        BOOTENV_ERR(3)
#define EFI_BUFFER_TOO_SMALL   BOOTENV_ERR(5)
#define EFI_NOT_READY          BOOTENV_ERR(6)
#define EFI_OUT_OF_RESOURCES   BOOTENV_ERR(9)
#define EFI_NOT_FOUND          BOOTENV_ERR(14)
#define EFI_ERROR(s) (((EFI_STATUS)(s) >> (sizeof(EFI_STATUS) * 8 - 1)) != 0)
#endif

/* ---- entry service contract -------------------------------------------
 * Implemented per boot entry (boot/efi/bootenv_efi.c, and later
 * boot/vmlinuz/). The shared core calls these; it never touches firmware. */

typedef enum { BE_ALLOC_ANY, BE_ALLOC_AT, BE_ALLOC_MAX } BeAllocMode;

/* Allocate `pages` contiguous physical pages:
 *   BE_ALLOC_ANY : anywhere (`want` ignored).
 *   BE_ALLOC_AT  : exactly at `want` (fail if occupied).
 *   BE_ALLOC_MAX : highest available range ending at or below `want`.
 * Returns the base physical address, or 0 on failure. */
UINT64 be_alloc_pages(BeAllocMode mode, UINTN pages, UINT64 want);

/* System memory regions for NT-descriptor building. Each entry's
 * format-specific source (UEFI GetMemoryMap, e820/PVH) is collapsed by
 * the per-entry implementation to this neutral shape; the shared
 * memmap_to_nt() overlays the mmu allocation registry on top for precise
 * per-allocation typing. base/size are bytes, UINT64 even on 32-bit (the
 * map format is identical across bitness). Fills up to `cap`, returns the
 * count. */
typedef enum {
    BE_MEM_FREE,          /* usable RAM (e820 type 1 / EfiConventional) */
    BE_MEM_BOOT_RECLAIM,  /* boot/loader memory, reclaimable post-handoff (UEFI) */
    BE_MEM_FIRMWARE,      /* keep: ACPI reclaim/NVS, runtime services */
    BE_MEM_RESERVED,      /* not RAM: MMIO/reserved/unusable — excluded from NT map */
} BeMemType;

typedef struct {
    UINT64    base;       /* physical base, bytes */
    UINT64    size;       /* length, bytes */
    BeMemType type;
} BeRegion;

UINT32 be_memory_regions(BeRegion *out, UINT32 cap);

#endif /* _BOOT_BOOTENV_H_ */
