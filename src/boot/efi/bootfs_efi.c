/*
 * EFI binding of the bfs_* boot-file-system contract (bootdrv.h) over the
 * UEFI SimpleFileSystem layer (fs.c).  The ASCII<->CHAR16 conversion lives
 * here so the shared \Boot walk (bootdrv.c) stays entry-agnostic.
 */
#include "bootdrv.h"
#include "fs.h"

static void a2w(const char *a, CHAR16 *w, int cap) {
    int i = 0;
    for (; a[i] && i < cap - 1; i++) w[i] = (CHAR16)(unsigned char)a[i];
    w[i] = 0;
}

static void w2a(const CHAR16 *w, char *a, int cap) {
    int i = 0;
    for (; w[i] && i < cap - 1; i++) a[i] = (char)w[i];
    a[i] = 0;
}

int bfs_listdir(const char *path, bootfs_dirent *out, int cap, int *n) {
    static fs_dirent tmp[MAX_BOOT_DRIVERS];
    CHAR16 wpath[160];
    UINTN  cnt = 0;

    if (cap > MAX_BOOT_DRIVERS) cap = MAX_BOOT_DRIVERS;
    a2w(path, wpath, (int)(sizeof wpath / sizeof wpath[0]));
    if (fs_listdir(wpath, tmp, (UINTN)cap, &cnt) != EFI_SUCCESS) return -1;
    for (UINTN i = 0; i < cnt && (int)i < cap; i++) {
        w2a(tmp[i].name, out[i].name, (int)sizeof out[i].name);
        out[i].is_dir = tmp[i].is_dir;
    }
    *n = (int)cnt;
    return 0;
}

void *bfs_read(const char *path, PageKind kind, UINT32 *size) {
    CHAR16 wpath[160];
    void  *buf = 0;
    UINTN  sz = 0;

    a2w(path, wpath, (int)(sizeof wpath / sizeof wpath[0]));
    if (fs_read(wpath, kind, &buf, &sz) != EFI_SUCCESS) return 0;
    if (size) *size = (UINT32)sz;
    return buf;
}
