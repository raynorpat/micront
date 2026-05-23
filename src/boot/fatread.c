#include "fatread.h"

/*
 * Read-only FAT16, reading straight out of an in-RAM disk image. Geometry
 * (reserved sectors, FAT count, root size, cluster size) is read from the
 * BPB, not assumed, so it tracks whatever nt.fs.fat16 emitted.
 */

static const UINT8 *g_img;          /* base of the in-RAM image           */
static UINT32 g_sec_per_clus;
static UINT32 g_fat_lba;            /* FAT start, absolute image sectors  */
static UINT32 g_root_lba;           /* root dir start                     */
static UINT32 g_root_entries;
static UINT32 g_data_lba;           /* cluster 2 start                    */

static UINT32 rd16(const UINT8 *p) { return p[0] | ((UINT32)p[1] << 8); }
static UINT32 rd32(const UINT8 *p) {
    return p[0] | ((UINT32)p[1] << 8) | ((UINT32)p[2] << 16) | ((UINT32)p[3] << 24);
}
static char up(char c) { return (c >= 'a' && c <= 'z') ? (char)(c - 32) : c; }

static const UINT8 *sec_ptr(UINT32 lba) { return g_img + (UINT64)lba * 512; }
static const UINT8 *clus_ptr(UINT32 c)  {
    return sec_ptr(g_data_lba + (c - 2) * g_sec_per_clus);
}
static UINT32 fat_next(UINT32 c) {
    return rd16(sec_ptr(g_fat_lba) + c * 2);
}

int fat_mount(const void *image, UINT32 image_size) {
    if (!image || image_size < 1024) return -1;
    g_img = (const UINT8 *)image;

    if (rd16(g_img + 510) != 0xAA55) return -1;          /* MBR signature */

    /* Partition table entry 1 (offset 446): byte 4 = type, +8 = start LBA. */
    const UINT8 *pe = g_img + 446;
    UINT32 part_lba = rd32(pe + 8);
    if (part_lba == 0) return -2;

    const UINT8 *bpb = sec_ptr(part_lba);
    if (rd16(bpb + 510) != 0xAA55) return -3;            /* FAT boot sig  */
    UINT32 bytes_per_sec = rd16(bpb + 11);
    if (bytes_per_sec != 512) return -4;                 /* only 512 today */

    g_sec_per_clus     = bpb[13];
    UINT32 reserved    = rd16(bpb + 14);
    UINT32 num_fats    = bpb[16];
    g_root_entries     = rd16(bpb + 17);
    UINT32 sec_per_fat = rd16(bpb + 22);
    if (g_sec_per_clus == 0 || num_fats == 0 || sec_per_fat == 0) return -5;

    g_fat_lba  = part_lba + reserved;
    g_root_lba = g_fat_lba + num_fats * sec_per_fat;
    UINT32 root_sectors = (g_root_entries * 32 + 511) / 512;
    g_data_lba = g_root_lba + root_sectors;
    return 0;
}

/* Encode an ASCII component into an 11-byte space-padded 8.3 name. */
static void enc83(const char *name, char out[11]) {
    for (int i = 0; i < 11; i++) out[i] = ' ';
    int len = 0; while (name[len]) len++;
    int dot = -1;
    for (int i = len - 1; i >= 0; i--) if (name[i] == '.') { dot = i; break; }
    int stem_len  = (dot >= 0) ? dot : len;
    int ext_start = (dot >= 0) ? dot + 1 : len;
    for (int i = 0; i < stem_len && i < 8; i++)  out[i]     = up(name[i]);
    for (int i = 0; ext_start + i < len && i < 3; i++) out[8 + i] = up(name[ext_start + i]);
}

/* Decode an 11-byte 8.3 entry name into "STEM.EXT" (NUL-terminated). */
static void dec83(const UINT8 *e, char out[16]) {
    int n = 0;
    for (int i = 0; i < 8 && e[i] != ' '; i++) out[n++] = (char)e[i];
    int has_ext = 0;
    for (int i = 8; i < 11; i++) if (e[i] != ' ') has_ext = 1;
    if (has_ext) {
        out[n++] = '.';
        for (int i = 8; i < 11 && e[i] != ' '; i++) out[n++] = (char)e[i];
    }
    out[n] = 0;
}

/* match: 1 = name11 matched (fills outs), -1 = end of directory, 0 = skip. */
static int match_entry(const UINT8 *e, const char *n11,
                       UINT32 *fc, UINT32 *sz, int *isdir) {
    if (e[0] == 0x00) return -1;
    if (e[0] == 0xE5) return 0;
    UINT8 attr = e[11];
    if ((attr & 0x0F) == 0x0F) return 0;                 /* LFN slot      */
    if (attr & 0x08)           return 0;                 /* volume label  */
    for (int i = 0; i < 11; i++) if (e[i] != (UINT8)n11[i]) return 0;
    if (fc)    *fc    = rd16(e + 26);
    if (sz)    *sz    = rd32(e + 28);
    if (isdir) *isdir = (attr & 0x10) ? 1 : 0;
    return 1;
}

/* Find name11 in directory dir_clus (0 = the fixed root region). */
static int dir_find(UINT32 dir_clus, const char *n11,
                    UINT32 *fc, UINT32 *sz, int *isdir) {
    if (dir_clus == 0) {
        const UINT8 *e = sec_ptr(g_root_lba);
        for (UINT32 i = 0; i < g_root_entries; i++, e += 32) {
            int r = match_entry(e, n11, fc, sz, isdir);
            if (r == 1) return 0;
            if (r == -1) return -1;
        }
        return -1;
    }
    UINT32 per = (g_sec_per_clus * 512) / 32;
    for (UINT32 c = dir_clus; c >= 2 && c < 0xFFF8; c = fat_next(c)) {
        const UINT8 *e = clus_ptr(c);
        for (UINT32 i = 0; i < per; i++, e += 32) {
            int r = match_entry(e, n11, fc, sz, isdir);
            if (r == 1) return 0;
            if (r == -1) return -1;
        }
    }
    return -1;
}

/* Walk a path to its directory entry. Returns 0 + (fc,sz,isdir). */
static int path_lookup(const char *path, UINT32 *out_fc, UINT32 *out_sz,
                       int *out_isdir) {
    UINT32 cur = 0;                                       /* root */
    const char *p = path;
    while (*p == '/' || *p == '\\') p++;
    if (!*p) {                                            /* "" / "/" = root */
        if (out_fc) *out_fc = 0;
        if (out_sz) *out_sz = 0;
        if (out_isdir) *out_isdir = 1;
        return 0;
    }
    while (*p) {
        char comp[16]; int n = 0;
        while (*p && *p != '/' && *p != '\\' && n < 15) comp[n++] = *p++;
        comp[n] = 0;
        while (*p == '/' || *p == '\\') p++;

        char n11[11];
        enc83(comp, n11);
        UINT32 fc, sz; int isdir;
        if (dir_find(cur, n11, &fc, &sz, &isdir) != 0) return -1;
        if (*p) {                                         /* intermediate */
            if (!isdir) return -1;
            cur = fc;
        } else {                                          /* last component */
            if (out_fc) *out_fc = fc;
            if (out_sz) *out_sz = sz;
            if (out_isdir) *out_isdir = isdir;
            return 0;
        }
    }
    return -1;
}

/* Copy up to `lim` bytes of the cluster chain at `clus` into dst. */
static UINT32 copy_chain(UINT32 clus, UINT32 lim, UINT8 *dst) {
    UINT32 csize = g_sec_per_clus * 512, done = 0;
    for (UINT32 c = clus; done < lim && c >= 2 && c < 0xFFF8; c = fat_next(c)) {
        const UINT8 *src = clus_ptr(c);
        UINT32 want = lim - done;
        if (want > csize) want = csize;
        for (UINT32 i = 0; i < want; i++) dst[done + i] = src[i];
        done += want;
    }
    return done;
}

void *fat_read(const char *path, PageKind kind, UINT32 *out_size) {
    UINT32 clus, size; int isdir;
    if (!g_img || path_lookup(path, &clus, &size, &isdir) != 0 || isdir) return NULL;

    UINT32 pages = (size + 4095) / 4096;
    if (pages == 0) pages = 1;
    EFI_PHYSICAL_ADDRESS phys;
    if (mmu_alloc(pages, kind, &phys) != EFI_SUCCESS) return NULL;
    UINT8 *buf = (UINT8 *)(UINTN)phys;
    copy_chain(clus, size, buf);
    if (out_size) *out_size = size;
    return buf;
}

int fat_file_size(const char *path, UINT32 *out_size) {
    UINT32 clus, size; int isdir;
    if (!g_img || path_lookup(path, &clus, &size, &isdir) != 0 || isdir) return -1;
    if (out_size) *out_size = size;
    return 0;
}

int fat_read_into(const char *path, void *dst, UINT32 cap, UINT32 *out_read) {
    UINT32 clus, size; int isdir;
    if (!g_img || path_lookup(path, &clus, &size, &isdir) != 0 || isdir) return -1;
    UINT32 lim = (size < cap) ? size : cap;
    UINT32 got = copy_chain(clus, lim, (UINT8 *)dst);
    if (out_read) *out_read = got;
    return 0;
}

int fat_listdir(const char *path, bootfs_dirent *out, int cap, int *out_n) {
    if (!g_img || !out_n) return -1;
    *out_n = 0;

    UINT32 dir_clus = 0;
    {
        UINT32 fc, sz; int isdir;
        if (path_lookup(path, &fc, &sz, &isdir) != 0 || !isdir) return -1;
        dir_clus = fc;                                    /* 0 for root */
    }

    int n = 0;
    /* Iterate the directory (root region or cluster chain), collecting
     * real entries up to cap. */
    UINT32 per = (g_sec_per_clus * 512) / 32;
    UINT32 c = dir_clus;
    int using_root = (dir_clus == 0);
    UINT32 root_i = 0;
    for (;;) {
        const UINT8 *base;
        UINT32 count;
        if (using_root) { base = sec_ptr(g_root_lba); count = g_root_entries; }
        else {
            if (!(c >= 2 && c < 0xFFF8)) break;
            base = clus_ptr(c); count = per;
        }
        const UINT8 *e = using_root ? base + root_i * 32 : base;
        UINT32 i = using_root ? root_i : 0;
        for (; i < count; i++, e += 32) {
            if (e[0] == 0x00) { *out_n = n; return 0; }   /* end of dir */
            if (e[0] == 0xE5) continue;
            UINT8 attr = e[11];
            if ((attr & 0x0F) == 0x0F) continue;          /* LFN */
            if (attr & 0x08) continue;                    /* volume label */
            if (n < cap) {
                dec83(e, out[n].name);
                out[n].is_dir = (attr & 0x10) ? 1 : 0;
            }
            n++;
        }
        if (using_root) break;
        c = fat_next(c);
    }
    *out_n = (n < cap) ? n : cap;
    return 0;
}
