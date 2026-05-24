/*
 * fatbuild.h — construct an MBR + FAT16 disk image in RAM from a zip.
 *
 * The shipped initrd is a STORED zip of the system tree; the loader builds a
 * RAM FAT16 volume from it at boot so everything downstream (fat_mount, the
 * kernel/hal/driver loads, ramscsi serving the volume) is unchanged.  The
 * image is byte-compatible with what the host nt.fs.fat16 + nt.fs.drive emit.
 */
#ifndef _BOOT_FATBUILD_H_
#define _BOOT_FATBUILD_H_

#include "bootenv.h"

/* Build the image from the STORED zip blob and return its physical base +
 * byte size (allocated memmap-only via mmu_alloc_reserve, so ramscsi maps it
 * on demand).  Returns 0 on success, negative on error (bad zip, a non-8.3
 * member name, DEFLATE member in Phase 1, OOM, or volume overflow). */
int fatbuild_from_zip(const void *zip, UINT32 zip_size,
                      EFI_PHYSICAL_ADDRESS *out_base, UINT32 *out_size);

#endif
