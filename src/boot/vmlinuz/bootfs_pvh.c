/*
 * PVH binding of the bfs_* boot-file-system contract (bootdrv.h) over the
 * in-RAM FAT16 reader (fatread.c).  The reader's signatures already match
 * the contract, so these are thin forwards — they exist so the shared
 * \Boot walk (bootdrv.c) resolves bfs_* per entry, exactly as the bootenv
 * be_* and bxlog symbols are bound.
 */
#include "bootdrv.h"
#include "fatread.h"

int bfs_listdir(const char *path, bootfs_dirent *out, int cap, int *n) {
    return fat_listdir(path, out, cap, n);
}

void *bfs_read(const char *path, PageKind kind, UINT32 *size) {
    return fat_read(path, kind, size);
}
