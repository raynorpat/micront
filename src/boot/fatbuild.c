#include "fatbuild.h"
#include "zipread.h"
#include "puff.h"
#include "mmu.h"
#include "log.h"

/*
 * Build an MBR + single FAT16 volume in RAM from a STORED zip, byte-mirroring
 * the host builder (src/pkg/nt/fs/{fat16,drive,mbr}.lua):
 *
 *   sector 0          MBR (disk sig 0x4E544653 @ 0x1B8, one active 0x06
 *                          partition starting at LBA 2048, boot sig 0x55AA)
 *   LBA 1..2047       1 MB alignment gap (zero)
 *   LBA 2048          FAT16 boot sector / BPB
 *   + reserved        FAT #1, FAT #2 (identical)
 *   + 2*sec_per_fat   root directory (512 entries)
 *   + 32 sectors      data region (cluster 2 onward)
 *
 * The ARC disk checksum is computed by the caller (main.c) over the MBR, so we
 * only need to emit a valid MBR.
 */

#define SECTOR_SIZE       512u
#define RESERVED_SECTORS  1u
#define NUM_FATS          2u
#define ROOT_DIR_ENTRIES  512u
#define ROOT_DIR_SECTORS  ((ROOT_DIR_ENTRIES * 32u) / SECTOR_SIZE)   /* 32 */
#define GAP_LBA           2048u            /* 1 MB pre-partition gap */
#define DISK_SIGNATURE    0x4E544653u
#define PART_TYPE_FAT16   0x06u

#define CLUSTER_EOC       0xFFFFu
#define ATTR_VOLUME_ID    0x08u
#define ATTR_DIRECTORY    0x10u
#define ATTR_ARCHIVE      0x20u
#define ATTR_LONG_NAME    0x0Fu     /* VFAT LFN slot */

/* Fixed DOS timestamp (1980-01-01), matching the host zip writer — fastfat
 * doesn't care about boot-time directory timestamps. */
#define DOS_DATE          0x0021u
#define DOS_TIME          0x0000u

#define MAX_NODES         1024

typedef struct {
    char         name[64];     /* original path component (for LFN + dedup) */
    char         name11[11];   /* 8.3 short name (valid only when !is_lfn) */
    UINT8        is_lfn;       /* name doesn't fit 8.3 -> emit VFAT LFN */
    int          parent;       /* node index; 0 = root */
    UINT8        is_dir;
    const UINT8 *data;         /* file payload in the zip (stored or deflated) */
    UINT32       size;         /* uncompressed byte size (FAT file size) */
    UINT32       comp_size;    /* `data` length (== size for STORED) */
    UINT16       method;       /* 0 = STORED, 8 = DEFLATE */
    UINT32       first_cluster;
} Node;

static Node   g_nodes[MAX_NODES];
static int    g_nnodes;        /* node 0 is the (entry-less) root */
static char   g_used[MAX_NODES][11];   /* per-directory taken 8.3 names (write time) */

static UINT32 g_spc;           /* sectors per cluster */
static UINT32 g_total_clusters;
static UINT32 g_next_cluster;

static char up(char c) { return (c >= 'a' && c <= 'z') ? (char)(c - 32) : c; }

static int slen(const char *s) { int n = 0; while (s[n]) n++; return n; }

static int name_ci_eq(const char *a, const char *b) {
    while (*a && *b) { if (up(*a) != up(*b)) return 0; a++; b++; }
    return *a == *b;
}

/* Encode a component into an 11-byte 8.3 name.  Returns 0 if it fits (out
 * filled), 1 if it doesn't (caller marks the node LFN; out is undefined). */
static int enc83(const char *comp, int len, char out[11]) {
    for (int i = 0; i < 11; i++) out[i] = ' ';
    int dot = -1;
    for (int i = len - 1; i >= 0; i--) if (comp[i] == '.') { dot = i; break; }
    int stem_len = (dot >= 0) ? dot : len;
    int ext_len  = (dot >= 0) ? (len - dot - 1) : 0;
    if (stem_len == 0 || stem_len > 8 || ext_len > 3) return 1;
    for (int i = 0; i < stem_len; i++) out[i] = up(comp[i]);
    for (int i = 0; i < ext_len;  i++) out[8 + i] = up(comp[dot + 1 + i]);
    return 0;
}

/* Create a node from an original path component.  Computes the 8.3 short name;
 * if it doesn't fit, marks is_lfn (the 8.3 alias + LFN slots are emitted at
 * write time, once the per-directory name set is known). */
static int new_node(const char *comp, int clen, int parent, UINT8 is_dir,
                    const UINT8 *data, UINT32 size, UINT32 comp_size, UINT16 method) {
    if (g_nnodes >= MAX_NODES) { BXLOG(L"too many entries (>%u)", MAX_NODES); return -1; }
    Node *nd = &g_nodes[g_nnodes];
    int i = 0; for (; i < clen && i < 63; i++) nd->name[i] = comp[i];
    nd->name[i] = 0;
    nd->is_lfn = (enc83(nd->name, i, nd->name11) != 0) ? 1 : 0;
    nd->parent = parent;
    nd->is_dir = is_dir;
    nd->data = data;
    nd->size = size;
    nd->comp_size = comp_size;
    nd->method = method;
    nd->first_cluster = 0;
    return g_nnodes++;
}

static int find_or_add_dir(int parent, const char *comp, int clen) {
    char tmp[64];
    int i = 0; for (; i < clen && i < 63; i++) tmp[i] = comp[i];
    tmp[i] = 0;
    for (int j = 1; j < g_nnodes; j++)
        if (g_nodes[j].is_dir && g_nodes[j].parent == parent
            && name_ci_eq(g_nodes[j].name, tmp))
            return j;
    return new_node(comp, clen, parent, 1, 0, 0, 0, 0);
}

/* Insert one zip member (path + payload) into the tree, creating intermediate
 * directories.  A trailing '/' marks an (empty) directory entry.  Long names
 * are fine — they become VFAT LFN entries at build time. */
static int add_path(const char *path, const UINT8 *data, UINT32 size,
                    UINT32 comp_size, UINT16 method) {
    int len = 0; while (path[len]) len++;
    int ends_slash = (len > 0 && (path[len - 1] == '/' || path[len - 1] == '\\'));

    int cur = 0;                                   /* root */
    const char *p = path;
    while (*p == '/' || *p == '\\') p++;
    while (*p) {
        char comp[64]; int n = 0;
        while (*p && *p != '/' && *p != '\\') { if (n < 63) comp[n] = *p; n++; p++; }
        int clen = (n < 63) ? n : 63;
        while (*p == '/' || *p == '\\') p++;
        int is_last = (*p == 0);

        if (is_last && !ends_slash) {
            return new_node(comp, clen, cur, 0, data, size, comp_size, method) < 0 ? -1 : 0;
        }
        cur = find_or_add_dir(cur, comp, clen);
        if (cur < 0) return -1;
    }
    return 0;                                       /* empty / all-slash path */
}

/* ---- little-endian image writers ---- */
static void wr16(UINT8 *img, UINT32 off, UINT32 v) {
    img[off] = (UINT8)v; img[off + 1] = (UINT8)(v >> 8);
}
static void wr32(UINT8 *img, UINT32 off, UINT32 v) {
    img[off] = (UINT8)v;        img[off + 1] = (UINT8)(v >> 8);
    img[off + 2] = (UINT8)(v >> 16); img[off + 3] = (UINT8)(v >> 24);
}

static void wr_dirent(UINT8 *img, UINT32 off, const char name11[11],
                      UINT8 attr, UINT32 first_clus, UINT32 size) {
    for (int i = 0; i < 11; i++) img[off + i] = (UINT8)name11[i];
    img[off + 11] = attr;
    wr16(img, off + 14, DOS_TIME);   /* create time */
    wr16(img, off + 16, DOS_DATE);   /* create date */
    wr16(img, off + 18, DOS_DATE);   /* last access date */
    wr16(img, off + 22, DOS_TIME);   /* last modify time */
    wr16(img, off + 24, DOS_DATE);   /* last modify date */
    wr16(img, off + 26, first_clus & 0xFFFF);
    wr32(img, off + 28, size);
}

/* VFAT LFN checksum of an 11-byte 8.3 name (matches FatComputeLfnChecksum). */
static UINT8 lfn_checksum(const char name11[11]) {
    UINT8 sum = 0;
    for (int i = 0; i < 11; i++)
        sum = (UINT8)((((sum & 1) << 7) | (sum >> 1)) + (UINT8)name11[i]);
    return sum;
}

/* Generate a unique NAME~N.EXT 8.3 alias (alnum basis, uppercased) for a long
 * name, avoiding the `n_used` entries already taken in this directory. */
static void make_alias(const char *longname, char used[][11], int n_used, char out[11]) {
    int len = slen(longname);
    int dot = -1; for (int i = len - 1; i >= 0; i--) if (longname[i] == '.') { dot = i; break; }
    int stem_end = (dot >= 0) ? dot : len;
    char stem[32]; int sl = 0;
    for (int i = 0; i < stem_end && sl < 31; i++) {
        char c = up(longname[i]);
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) stem[sl++] = c;
    }
    if (sl == 0) { stem[0]='F'; stem[1]='I'; stem[2]='L'; stem[3]='E'; sl = 4; }
    char ext[3]; int el = 0;
    if (dot >= 0) for (int i = dot + 1; i < len && el < 3; i++) {
        char c = up(longname[i]);
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) ext[el++] = c;
    }
    for (UINT32 num = 1; num < 1000000u; num++) {
        char suf[8]; int sn = 0; suf[sn++] = '~';
        char dg[7]; int dn = 0; UINT32 t = num;
        while (t) { dg[dn++] = (char)('0' + (t % 10)); t /= 10; }
        for (int k = dn - 1; k >= 0; k--) suf[sn++] = dg[k];
        int basis = 8 - sn; if (basis > sl) basis = sl;
        char cand[11]; for (int i = 0; i < 11; i++) cand[i] = ' ';
        for (int i = 0; i < basis; i++) cand[i] = stem[i];
        for (int i = 0; i < sn; i++)    cand[basis + i] = suf[i];
        for (int i = 0; i < el; i++)    cand[8 + i] = ext[i];
        int clash = 0;
        for (int u = 0; u < n_used; u++) {
            int eq = 1; for (int i = 0; i < 11; i++) if (used[u][i] != cand[i]) { eq = 0; break; }
            if (eq) { clash = 1; break; }
        }
        if (!clash) { for (int i = 0; i < 11; i++) out[i] = cand[i]; return; }
    }
    for (int i = 0; i < 11; i++) out[i] = ' ';   /* unreachable for sane counts */
}

/* Write the VFAT LFN slot chain (on-disk order: highest seq first, sequence 1
 * just before the 8.3 entry).  13 UTF-16 units/slot, split 5/6/2.  Returns the
 * new byte offset (past the slots). */
static UINT32 wr_lfn_slots(UINT8 *img, UINT32 off, const char *longname,
                           const char alias[11]) {
    static const int coff[13] = { 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
    UINT8 chk = lfn_checksum(alias);
    int len = slen(longname);
    int n_slots = (len + 12) / 13;
    for (int seq = n_slots; seq >= 1; seq--) {
        UINT8 *e = img + off;
        for (int i = 0; i < 32; i++) e[i] = 0;
        e[0]  = (UINT8)(seq | (seq == n_slots ? 0x40 : 0));
        e[11] = ATTR_LONG_NAME;
        e[13] = chk;
        int base = (seq - 1) * 13;
        for (int k = 0; k < 13; k++) {
            int p = base + k;
            UINT32 cu = (p < len) ? (UINT8)longname[p] : (p == len ? 0u : 0xFFFFu);
            e[coff[k]]     = (UINT8)cu;
            e[coff[k] + 1] = (UINT8)(cu >> 8);
        }
        off += 32;
    }
    return off;
}

/* Number of 32-byte dirents a node occupies (1 for 8.3, else LFN slots + 1). */
static UINT32 node_dirents(const Node *nd) {
    if (!nd->is_lfn) return 1;
    return (UINT32)((slen(nd->name) + 12) / 13) + 1;
}

/* Write one child's directory entries at `e` (LFN slots + 8.3 entry, or just
 * the 8.3 entry).  Reserves the resulting 8.3 name in `used`. Returns new off. */
static UINT32 wr_child(UINT8 *img, UINT32 e, const Node *nd,
                       char used[][11], int *n_used) {
    UINT8 attr = nd->is_dir ? ATTR_DIRECTORY : ATTR_ARCHIVE;
    UINT32 sz  = nd->is_dir ? 0 : nd->size;
    char name11[11];
    if (nd->is_lfn) {
        make_alias(nd->name, used, *n_used, name11);
        e = wr_lfn_slots(img, e, nd->name, name11);
    } else {
        for (int i = 0; i < 11; i++) name11[i] = nd->name11[i];
    }
    for (int i = 0; i < 11; i++) used[*n_used][i] = name11[i];
    (*n_used)++;
    wr_dirent(img, e, name11, attr, nd->first_cluster, sz);
    return e + 32;
}

static UINT32 default_spc(UINT32 size_mb) {
    if (size_mb <=  128) return  4;
    if (size_mb <=  256) return  8;
    if (size_mb <=  512) return 16;
    if (size_mb <= 1024) return 32;
    return 64;
}

/* FAT chain allocator: hands out a contiguous run for `nbytes`, links it in
 * FAT #1, returns the first cluster (0 for an empty file). */
static int alloc_clusters(UINT8 *img, UINT32 fat1_byte, UINT32 nbytes,
                          UINT32 *out_first) {
    if (nbytes == 0) { *out_first = 0; return 0; }
    UINT32 cbytes = g_spc * SECTOR_SIZE;
    UINT32 n = (nbytes + cbytes - 1) / cbytes;
    UINT32 first = g_next_cluster;
    for (UINT32 i = 0; i < n; i++) {
        UINT32 cl = first + i;
        if (cl + 1 >= g_total_clusters + 2) { BXLOG(L"FAT16 volume full"); return -1; }
        wr16(img, fat1_byte + cl * 2, (i + 1 < n) ? (cl + 1) : CLUSTER_EOC);
    }
    g_next_cluster += n;
    *out_first = first;
    return 0;
}

int fatbuild_from_zip(const void *zip, UINT32 zip_size,
                      EFI_PHYSICAL_ADDRESS *out_base, UINT32 *out_size) {
    if (zip_mount(zip, zip_size) != 0) { BXLOG(L"not a zip blob"); return -1; }

    /* ---- Build the directory tree from the zip members ---- */
    g_nnodes = 1;                       /* node 0 = root */
    g_nodes[0].is_dir = 1;
    g_nodes[0].parent = -1;

    int count = zip_count();
    UINT32 content = 0;                 /* sum of file sizes rounded to 4 KB */
    for (int i = 0; i < count; i++) {
        const char *name; const void *data; UINT32 csize, size; UINT16 method;
        if (zip_entry(i, &name, &data, &csize, &size, &method) != 0) {
            BXLOG(L"bad central-dir entry %d", i); return -1;
        }
        if (method != 0 && method != 8) {
            BXLOG(L"member '%a' uses unsupported zip method %u", name, method);
            return -1;
        }
        if (add_path(name, (const UINT8 *)data, size, csize, method) != 0) return -1;
        content += (size + 4095u) & ~4095u;
    }

    /* ---- Size the volume (mirror init.lua: content + overhead + headroom) ---- */
    UINT32 overhead = 512u * 1024u;
    UINT32 free_hdr = content / 4;
    if (free_hdr < 8u * 1024u * 1024u) free_hdr = 8u * 1024u * 1024u;
    UINT32 vol_mb = (content + overhead + free_hdr + (1024u * 1024u - 1)) / (1024u * 1024u);
    if (vol_mb < 8) vol_mb = 8;
    UINT32 vol_bytes   = vol_mb * 1024u * 1024u;
    UINT32 part_sectors = vol_bytes / SECTOR_SIZE;
    g_spc = default_spc(vol_mb);

    /* ---- Iterate to a consistent sectors_per_fat ---- */
    UINT32 sec_per_fat = 1, clusters = 0;
    for (;;) {
        UINT32 data_sectors = part_sectors - RESERVED_SECTORS
                            - NUM_FATS * sec_per_fat - ROOT_DIR_SECTORS;
        clusters = data_sectors / g_spc;
        UINT32 needed = ((clusters + 2) * 2 + SECTOR_SIZE - 1) / SECTOR_SIZE;
        if (needed <= sec_per_fat) break;
        sec_per_fat = needed;
    }
    g_total_clusters = clusters;
    g_next_cluster   = 2;

    UINT32 fat1_lba = RESERVED_SECTORS;
    UINT32 fat2_lba = fat1_lba + sec_per_fat;
    UINT32 root_lba = fat2_lba + sec_per_fat;
    UINT32 data_lba = root_lba + ROOT_DIR_SECTORS;

    /* ---- Allocate + zero the whole image (gap + partition) ---- */
    UINT32 total_sectors = GAP_LBA + part_sectors;
    UINT32 image_bytes   = total_sectors * SECTOR_SIZE;
    UINT32 pages = (image_bytes + 4095u) / 4096u;
    EFI_PHYSICAL_ADDRESS phys;
    if (mmu_alloc_reserve(pages, PK_FIRMWARE_PERM, &phys) != EFI_SUCCESS) {
        BXLOG(L"FAT image alloc (%u pages) failed", pages); return -1;
    }
    UINT8 *img = (UINT8 *)(UINTN)phys;
    for (UINT32 i = 0; i < image_bytes; i += 4) wr32(img, i, 0);

    UINT32 part_base = GAP_LBA * SECTOR_SIZE;
    UINT32 fat1_byte = part_base + fat1_lba * SECTOR_SIZE;
    UINT32 fat2_byte = part_base + fat2_lba * SECTOR_SIZE;
    UINT32 root_byte = part_base + root_lba * SECTOR_SIZE;
    UINT32 data_byte = part_base + data_lba * SECTOR_SIZE;

    /* ---- Assign clusters to every node (dirs sized by child count) ---- */
    wr16(img, fat1_byte + 0, 0xFFF8);             /* FAT[0] media */
    wr16(img, fat1_byte + 2, 0xFFFF);             /* FAT[1] reserved */
    for (int i = 1; i < g_nnodes; i++) {
        UINT32 nbytes;
        if (g_nodes[i].is_dir) {
            UINT32 entries = 2;                               /* . + .. */
            for (int c = 1; c < g_nnodes; c++)
                if (g_nodes[c].parent == i) entries += node_dirents(&g_nodes[c]);
            nbytes = entries * 32;
        } else {
            nbytes = g_nodes[i].size;
        }
        if (alloc_clusters(img, fat1_byte, nbytes, &g_nodes[i].first_cluster) != 0)
            return -1;
    }

    /* ---- MBR (sector 0) ---- */
    wr32(img, 0x1B8, DISK_SIGNATURE);
    img[0x1BE + 0] = 0x80;                          /* active */
    img[0x1BE + 4] = PART_TYPE_FAT16;
    wr32(img, 0x1BE + 8,  GAP_LBA);                 /* partition start LBA */
    wr32(img, 0x1BE + 12, part_sectors);
    img[0x1FE] = 0x55; img[0x1FF] = 0xAA;

    /* ---- FAT16 boot sector / BPB (partition LBA 0) ---- */
    UINT8 *bs = img + part_base;
    bs[0] = 0xEB; bs[1] = 0x3C; bs[2] = 0x90;
    { const char *oem = "MSDOS5.0"; for (int i = 0; i < 8; i++) bs[3 + i] = (UINT8)oem[i]; }
    wr16(img, part_base + 0x0B, SECTOR_SIZE);
    bs[0x0D] = (UINT8)g_spc;
    wr16(img, part_base + 0x0E, RESERVED_SECTORS);
    bs[0x10] = NUM_FATS;
    wr16(img, part_base + 0x11, ROOT_DIR_ENTRIES);
    if (part_sectors <= 0xFFFF) { wr16(img, part_base + 0x13, part_sectors); }
    else                        { wr16(img, part_base + 0x13, 0); wr32(img, part_base + 0x20, part_sectors); }
    bs[0x15] = 0xF8;                                 /* media descriptor */
    wr16(img, part_base + 0x16, sec_per_fat);
    wr16(img, part_base + 0x18, 63);                /* sectors per track */
    wr16(img, part_base + 0x1A, 255);               /* heads */
    wr32(img, part_base + 0x1C, GAP_LBA);           /* HiddenSectors */
    bs[0x24] = 0x80;                                /* drive number */
    bs[0x26] = 0x29;                                /* ext boot sig */
    wr32(img, part_base + 0x27, DISK_SIGNATURE);    /* volume serial */
    { const char *lbl = "NT         "; for (int i = 0; i < 11; i++) bs[0x2B + i] = (UINT8)lbl[i]; }
    { const char *ft = "FAT16   ";     for (int i = 0; i < 8; i++)  bs[0x36 + i] = (UINT8)ft[i]; }
    bs[0x1FE] = 0x55; bs[0x1FF] = 0xAA;

    /* ---- Root directory (volume label + root's children) ---- */
    {
        UINT32 e = root_byte;
        int n_used = 0, n_ent = 1;                       /* +1 for the label */
        wr_dirent(img, e, "NT         ", ATTR_VOLUME_ID, 0, 0); e += 32;
        for (int i = 1; i < g_nnodes; i++) {
            if (g_nodes[i].parent != 0) continue;
            if ((UINT32)n_ent + node_dirents(&g_nodes[i]) > ROOT_DIR_ENTRIES) {
                BXLOG(L"root directory full"); return -1;
            }
            n_ent += (int)node_dirents(&g_nodes[i]);
            e = wr_child(img, e, &g_nodes[i], g_used, &n_used);
        }
    }

    /* ---- Subdirectory clusters (. , .. , children) + file data ---- */
    for (int d = 1; d < g_nnodes; d++) {
        if (!g_nodes[d].is_dir) continue;
        UINT32 e = data_byte + (g_nodes[d].first_cluster - 2) * g_spc * SECTOR_SIZE;
        UINT32 pclus = (g_nodes[d].parent == 0) ? 0 : g_nodes[g_nodes[d].parent].first_cluster;
        wr_dirent(img, e, ".          ", ATTR_DIRECTORY, g_nodes[d].first_cluster, 0); e += 32;
        wr_dirent(img, e, "..         ", ATTR_DIRECTORY, pclus, 0); e += 32;
        int n_used = 0;
        for (int c = 1; c < g_nnodes; c++) {
            if (g_nodes[c].parent != d) continue;
            e = wr_child(img, e, &g_nodes[c], g_used, &n_used);
        }
    }
    for (int f = 1; f < g_nnodes; f++) {
        if (g_nodes[f].is_dir || g_nodes[f].first_cluster == 0) continue;
        UINT32 off = data_byte + (g_nodes[f].first_cluster - 2) * g_spc * SECTOR_SIZE;
        const UINT8 *src = g_nodes[f].data;
        if (g_nodes[f].method == 0) {
            for (UINT32 j = 0; j < g_nodes[f].size; j++) img[off + j] = src[j];
        } else {
            /* DEFLATE (method 8): inflate the raw stream straight into the
             * cluster region (sized by the uncompressed length). */
            unsigned long dl = g_nodes[f].size, sl = g_nodes[f].comp_size;
            int pr = puff(img + off, &dl, src, &sl);
            if (pr != 0 || dl != g_nodes[f].size) {
                BXLOG(L"inflate failed (rc=%d, out=%lu/%u)",
                      pr, (UINT64)dl, g_nodes[f].size);
                return -1;
            }
        }
    }

    /* ---- Mirror FAT #1 into FAT #2 ---- */
    {
        UINT32 fat_bytes = sec_per_fat * SECTOR_SIZE;
        for (UINT32 j = 0; j < fat_bytes; j++) img[fat2_byte + j] = img[fat1_byte + j];
    }

    UINT32 used_clusters = g_next_cluster - 2;
    BXLOG(L"built FAT16: %u MB, %u/%u clusters used (spc=%u, %d entries)",
          image_bytes / (1024u * 1024u), used_clusters, g_total_clusters,
          g_spc, g_nnodes - 1);

    if (out_base) *out_base = phys;
    if (out_size) *out_size = image_bytes;
    return 0;
}
