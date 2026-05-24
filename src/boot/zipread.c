#include "zipread.h"

/*
 * Read-only STORED ZIP reader, reading straight out of an in-RAM blob.
 * Mirrors the offsets used by the on-target loader (src/cr/preamble.lua):
 * EOCD (0x06054b50) -> central directory (0x02014b50 entries) -> per-entry
 * local header (0x04034b50) for the data offset.
 */

#define SIG_EOCD    0x06054b50u
#define SIG_CDIR    0x02014b50u

#define ZIP_NAME_MAX 255

static const UINT8 *g_blob;
static UINT32       g_size;
static UINT32       g_cd_off;     /* central directory start, absolute */
static int          g_count;

static char g_name[ZIP_NAME_MAX + 1];

/* Bounds-checked little-endian readers; out-of-range reads return 0 so a
 * truncated/malformed blob fails the signature checks rather than faulting. */
static UINT32 rd16(UINT32 off) {
    if (off + 2 > g_size) return 0;
    return g_blob[off] | ((UINT32)g_blob[off + 1] << 8);
}
static UINT32 rd32(UINT32 off) {
    if (off + 4 > g_size) return 0;
    return g_blob[off] | ((UINT32)g_blob[off + 1] << 8)
         | ((UINT32)g_blob[off + 2] << 16) | ((UINT32)g_blob[off + 3] << 24);
}

int zip_mount(const void *blob, UINT32 size) {
    g_blob = (const UINT8 *)blob;
    g_size = size;
    g_cd_off = 0;
    g_count = 0;
    if (!blob || size < 22) return -1;

    /* Scan backward for the EOCD signature.  The record is >=22 bytes and
     * may be followed by a comment, so start at size-22 and walk down. */
    for (UINT32 p = size - 22; ; p--) {
        if (rd32(p) == SIG_EOCD) {
            UINT32 count   = rd16(p + 10);
            UINT32 cd_size = rd32(p + 12);
            UINT32 cd_off  = rd32(p + 16);
            /* Sanity: the central directory must lie within the blob and end
             * at or before this EOCD. */
            if (cd_off <= p && cd_off + cd_size <= size) {
                g_cd_off = cd_off;
                g_count  = (int)count;
                return 0;
            }
        }
        if (p == 0) break;
    }
    return -2;
}

int zip_count(void) { return g_count; }

int zip_entry(int i, const char **name, const void **data,
              UINT32 *comp_size, UINT32 *size, UINT16 *method) {
    if (i < 0 || i >= g_count) return -1;

    /* Walk the central directory to entry i (entries are variable length). */
    UINT32 p = g_cd_off;
    for (int k = 0; k < i; k++) {
        if (rd32(p) != SIG_CDIR) return -1;
        UINT32 namelen  = rd16(p + 28);
        UINT32 extralen = rd16(p + 30);
        UINT32 cmtlen   = rd16(p + 32);
        p += 46 + namelen + extralen + cmtlen;
    }
    if (rd32(p) != SIG_CDIR) return -1;

    UINT32 m        = rd16(p + 10);
    UINT32 csize    = rd32(p + 20);
    UINT32 usize    = rd32(p + 24);
    UINT32 namelen  = rd16(p + 28);
    UINT32 lh_off   = rd32(p + 42);

    /* Copy the (length-prefixed, non-NUL-terminated) name into our buffer. */
    UINT32 nl = namelen > ZIP_NAME_MAX ? ZIP_NAME_MAX : namelen;
    for (UINT32 j = 0; j < nl; j++) {
        if (p + 46 + j >= g_size) return -1;
        g_name[j] = (char)g_blob[p + 46 + j];
    }
    g_name[nl] = 0;

    /* Resolve the data offset via the local header (its name/extra lengths
     * can differ from the central directory's, so read them there). */
    if (rd32(lh_off) != 0x04034b50u) return -1;
    UINT32 lh_namelen  = rd16(lh_off + 26);
    UINT32 lh_extralen = rd16(lh_off + 28);
    UINT32 data_off    = lh_off + 30 + lh_namelen + lh_extralen;
    if (data_off + csize > g_size) return -1;

    if (name)      *name      = g_name;
    if (data)      *data      = g_blob + data_off;
    if (comp_size) *comp_size = csize;
    if (size)      *size      = usize;
    if (method)    *method    = (UINT16)m;
    return 0;
}
