/*
 * ESP file reading.
 *
 * Uses EFI_LOADED_IMAGE_PROTOCOL on our own ImageHandle to find the
 * device we were loaded from, then EFI_SIMPLE_FILE_SYSTEM_PROTOCOL to
 * open files by path. Allocates pages via AllocatePages(LoaderData) and
 * owns them past ExitBootServices — the kernel will see these pages
 * through memory descriptors (type LoaderSystemCode / LoaderHalCode /
 * etc. depending on the caller's intent).
 */
#ifndef _BOOT_EFI_FS_H_
#define _BOOT_EFI_FS_H_

#include <efi.h>
#include <efilib.h>
#include "mmu.h"

EFI_STATUS fs_init(EFI_HANDLE ImageHandle);

/*
 * Read `path` into a freshly-AllocatePages'd buffer via mmu_alloc, tagging
 * the allocation with `kind` so memmap.c can emit the correct NT memory
 * type. Path uses backslashes, e.g. L"\\System32\\ntoskrnl.exe".
 * On success: *out_buf points at page-aligned image; *out_size is byte size.
 * Caller does NOT free — the pages become part of the handed-off image set.
 */
EFI_STATUS fs_read(const CHAR16 *path, PageKind kind,
                   void **out_buf, UINTN *out_size);

#endif
