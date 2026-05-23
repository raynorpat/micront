/*
 * EFI memory-map capture (for the ExitBootServices MapKey). The neutral
 * be_memory_regions() (boot/bootenv.h), implemented alongside in
 * memmap_efi.c, reads the captured map for the shared memmap_to_nt().
 */
#ifndef _BOOT_EFI_MEMMAP_EFI_H_
#define _BOOT_EFI_MEMMAP_EFI_H_

#include "bootenv.h"

/* Capture the current UEFI map; returns the MapKey for ExitBootServices.
 * Must be the last allocation before ExitBootServices. */
EFI_STATUS memmap_capture(UINTN *out_map_key);

/* Refresh the MapKey in place (no AllocatePool, so it does not itself
 * invalidate the key) for the ExitBootServices INVALID_PARAMETER retry. */
EFI_STATUS memmap_refresh_key(UINTN *out_map_key);

#endif
