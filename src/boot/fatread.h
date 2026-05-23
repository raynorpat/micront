/*
 * Read-only FAT16 reader over an in-RAM disk image (MBR + one FAT16
 * partition) — the firmware-less counterpart to boot/efi/fs.c (which uses
 * the UEFI SimpleFileSystem). The image is the initrd already in RAM
 * (vmlinuz/PVH), or a future EFI-UKI .initrd section. Files are gathered
 * (following the cluster chain) into mmu_alloc'd buffers, mirroring
 * fs_read so the staging logic on top is identical.
 */
#ifndef _BOOT_FATREAD_H_
#define _BOOT_FATREAD_H_

#include "bootenv.h"
#include "mmu.h"        /* PageKind */
#include "bootdrv.h"    /* bootfs_dirent (shared directory-entry type) */

/* Mount partition 1 of an in-RAM MBR disk image. Returns 0 on success,
 * negative on a malformed MBR / BPB / unsupported geometry. */
int fat_mount(const void *image, UINT32 image_size);

/* Read a file (path components separated by '/' or '\\', 8.3 names) into
 * a freshly mmu_alloc'd buffer tagged `kind`. Returns the buffer pointer
 * (== its physical address; paging is off pre-handoff) and the byte size
 * via *out_size, or NULL on failure. */
void *fat_read(const char *path, PageKind kind, UINT32 *out_size);

/* File size in bytes without reading. Returns 0 on success, -1 if absent. */
int fat_file_size(const char *path, UINT32 *out_size);

/* Read a file into a caller-provided buffer (clamped to `cap`). *out_read
 * = bytes copied. Returns 0 on success. Used for the contiguous NLS slab. */
int fat_read_into(const char *path, void *dst, UINT32 cap, UINT32 *out_read);

/* Directory listing for the \Boot bucket walk. `path` "" or "/" is the
 * root. Fills up to `cap` entries; *out_n = count. Returns 0 on success. */
int fat_listdir(const char *path, bootfs_dirent *out, int cap, int *out_n);

#endif
