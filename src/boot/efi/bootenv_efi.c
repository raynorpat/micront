/*
 * EFI implementation of the bootenv service contract (boot/bootenv.h) and
 * the per-entry log sink (boot/log.h). These are the firmware-specific
 * seams the shared boot core calls; the core never touches UEFI directly.
 */
#include <stdarg.h>
#include "bootenv.h"
#include "log.h"

/* Log sink: gnu-efi's Print engine -> EFI ConOut (VGA + serial console).
 * Identical to the pre-seam BXLOG, which called Print() directly. */
void bxlog(const CHAR16 *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    VPrint(fmt, ap);
    va_end(ap);
}

UINT64 be_alloc_pages(BeAllocMode mode, UINTN pages, UINT64 want) {
    EFI_ALLOCATE_TYPE etype;
    switch (mode) {
    case BE_ALLOC_AT:  etype = AllocateAddress;    break;
    case BE_ALLOC_MAX: etype = AllocateMaxAddress; break;
    case BE_ALLOC_ANY:
    default:           etype = AllocateAnyPages;   break;
    }

    EFI_PHYSICAL_ADDRESS phys = (EFI_PHYSICAL_ADDRESS)want;
    EFI_STATUS s = uefi_call_wrapper(BS->AllocatePages, 4,
                                     etype, EfiLoaderData, pages, &phys);
    if (EFI_ERROR(s)) {
        BXLOG(L"be_alloc_pages: AllocatePages(%u) failed: 0x%lx",
              (UINT32)pages, (UINT64)s);
        return 0;
    }
    return (UINT64)phys;
}
