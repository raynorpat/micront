/*
 * zipread.h — minimal read-only ZIP access for the boot loader.
 *
 * Mirrors the STORED-zip conventions of the on-target package loader
 * (src/cr/preamble.lua): it parses the End-Of-Central-Directory + central
 * directory and resolves each member's data via its local header.  Phase 1
 * is STORED (method 0) only; DEFLATE is a planned follow-up.
 */
#ifndef _BOOT_ZIPREAD_H_
#define _BOOT_ZIPREAD_H_

#include "bootenv.h"

/* Mount a zip blob: locate the EOCD (scanning backward, so a trailing
 * archive comment is tolerated) and the central directory.  Returns 0 on
 * success, negative on a malformed / non-zip blob. */
int zip_mount(const void *blob, UINT32 size);

/* Number of central-directory entries after a successful zip_mount. */
int zip_count(void);

/* Describe entry `i` (0-based).  `name` points at a static NUL-terminated
 * buffer valid until the next zip_entry call; `data` points at the member's
 * raw data in the mounted blob (the stored bytes for STORED, the raw DEFLATE
 * stream for method 8); `comp_size` is that data's length; `size` is the
 * uncompressed length; `method` is the compression method (0 = STORED, 8 =
 * DEFLATE).  Returns 0 on success, -1 on a bad index / malformed entry. */
int zip_entry(int i, const char **name, const void **data,
              UINT32 *comp_size, UINT32 *size, UINT16 *method);

#endif
