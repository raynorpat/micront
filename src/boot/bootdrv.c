/*
 * Boot-driver staging — the \Boot\<NN>\ bucket walk, shared by every
 * boot entry.  FS access goes through the bfs_* contract (bootdrv.h), so
 * this file has no knowledge of UEFI SimpleFileSystem vs raw FAT16.
 *
 * \Boot\ holds 2-digit bucket subdirectories (\Boot\10, \Boot\20, …).
 * Lexical bucket order IS the load order: the kernel's
 * IopInitializeBootDrivers walks LoaderBlock->BootDriverListHead in the
 * order we wire it and does NOT re-sort by ServiceGroupOrder.  The bucket
 * convention (set by ntosbe's layer system) keeps the framework ahead of
 * its dependants:
 *   10  scsiport             (miniports import ScsiPortInitialize)
 *   20  atdisk/nvme2k/vioblk  (storage miniports, mutually independent)
 *   30  scsidisk             (class driver — walks the miniports' devices)
 *   90  fastfat/ntfs         (FS recognizers — no hardware at DriverEntry)
 * Within a bucket the drivers are independent, so file order is immaterial.
 *
 * The bucket directory is invisible to the kernel: pe_stage records the
 * bare filename ("nvme2k.sys"), from which lpb.c rebuilds both the image
 * path and the Services\<name> registry path.
 */
#include "bootdrv.h"
#include "log.h"

/* ASCII lexical compare. */
static int acmp(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

/* Insertion sort bootfs_dirent[] by name, ascending — small N. */
static void sort_dirents(bootfs_dirent *e, int n) {
    for (int i = 1; i < n; i++) {
        bootfs_dirent tmp = e[i];
        int j = i;
        while (j > 0 && acmp(e[j - 1].name, tmp.name) > 0) {
            e[j] = e[j - 1];
            j--;
        }
        e[j] = tmp;
    }
}

/* Append NUL-terminated `src` into `dst` at *pos, advancing *pos. */
static void appends(char *dst, int *pos, const char *src) {
    while (*src) dst[(*pos)++] = *src++;
}

UINTN stage_boot_drivers(pe_image_t *out, UINTN max) {
    /* pe_stage stores the name pointer (it does not copy), so the name
     * strings must outlive this function — keep a static pool. */
    static char          namepool[MAX_BOOT_DRIVERS][32];
    static bootfs_dirent buckets[24];
    static bootfs_dirent files[MAX_BOOT_DRIVERS];
    int   n_buckets = 0;
    UINTN staged = 0;

    if (bfs_listdir("\\Boot", buckets, 24, &n_buckets) != 0) {
        BXLOG(L"\\Boot enumeration failed — no boot drivers staged");
        return 0;
    }
    sort_dirents(buckets, n_buckets);

    for (int b = 0; b < n_buckets; b++) {
        if (!buckets[b].is_dir) continue;

        char dirpath[80];                       /* "\Boot\<bucket>" */
        int  p = 0;
        appends(dirpath, &p, "\\Boot\\");
        appends(dirpath, &p, buckets[b].name);
        dirpath[p] = 0;

        int n_files = 0;
        if (bfs_listdir(dirpath, files, MAX_BOOT_DRIVERS, &n_files) != 0)
            continue;
        sort_dirents(files, n_files);

        for (int f = 0; f < n_files; f++) {
            if (files[f].is_dir) continue;
            if (staged >= max) {
                BXLOG(L"boot-driver count exceeds %lu — truncating",
                      (UINT64)max);
                return staged;
            }

            char fpath[160];                    /* "\Boot\<bucket>\<file>" */
            int  q = 0;
            appends(fpath, &q, dirpath);
            fpath[q++] = '\\';
            appends(fpath, &q, files[f].name);
            fpath[q] = 0;

            /* ASCII basename for pe_stage -> lpb (Services\<name>). */
            char *aname = namepool[staged];
            int   a = 0;
            for (int k = 0;
                 files[f].name[k] && a < (int)sizeof namepool[0] - 1; k++)
                aname[a++] = files[f].name[k];
            aname[a] = 0;

            UINT32 bsz = 0;
            void  *blob = bfs_read(fpath, PK_FIRMWARE_TEMP, &bsz);
            if (!blob) continue;
            if (pe_stage(blob, bsz, PK_BOOT_DRIVER, aname, &out[staged])
                == EFI_SUCCESS) {
                staged++;
            } else {
                BXLOG(L"%a: pe_stage failed", aname);
            }
        }
    }
    BXLOG(L"staged %lu boot driver(s) from \\Boot", (UINT64)staged);
    return staged;
}
