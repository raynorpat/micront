/*
 * Boot-driver staging — the shared \Boot\<NN>\ bucket walk plus the
 * link-time "boot file system" contract it runs over.
 *
 * The walk (stage_boot_drivers) is entry-agnostic core: it lists the
 * \Boot tree, orders it, and pe_stage()s each driver. It reaches the
 * underlying volume only through the bfs_* contract below — the same
 * pattern as the bootenv be_* and bxlog set — so each entry binds it to
 * its own file backend:
 *   boot/vmlinuz/  -> the in-RAM FAT16 reader (fatread.c)   [bootfs_pvh.c]
 *   boot/efi/      -> UEFI SimpleFileSystem (fs.c)           [bootfs_efi.c]
 */
#ifndef _BOOT_BOOTDRV_H_
#define _BOOT_BOOTDRV_H_

#include "bootenv.h"   /* UINTN / UINT32 / EFI_STATUS */
#include "mmu.h"       /* PageKind */
#include "pe.h"        /* pe_image_t */

/* Upper bound on boot drivers staged from \Boot\.  The real set is ~7
 * (scsiport, atdisk, nvme2k, vioblk, scsidisk, fastfat, ntfs); 32 leaves
 * generous headroom for future storage/FS layers. */
#define MAX_BOOT_DRIVERS 32

/* One directory entry, ASCII 8.3 name.  Shared by every bfs backend so
 * the walk consumes listings without knowing the source FS. */
typedef struct { char name[16]; int is_dir; } bootfs_dirent;

/* ---- bfs_* contract (link-time, bound per entry) -----------------------
 * Paths are ASCII, '\' or '/' separated, e.g. "\\Boot\\10\\scsiport.sys". */

/* List directory `path`: up to `cap` entries into out[], *n = count.
 * Returns 0 on success, nonzero on failure. */
int bfs_listdir(const char *path, bootfs_dirent *out, int cap, int *n);

/* Read `path` into a freshly mmu_alloc'd buffer tagged `kind`; returns the
 * buffer (== its physical address, paging off pre-handoff) with *size set,
 * or NULL on failure. */
void *bfs_read(const char *path, PageKind kind, UINT32 *size);

/* Walk \Boot\<NN>\ buckets in lexical (= load) order, pe_stage()ing each
 * driver as PK_BOOT_DRIVER.  Returns the count staged into out[0..N-1]. */
UINTN stage_boot_drivers(pe_image_t *out, UINTN max);

#endif /* _BOOT_BOOTDRV_H_ */
