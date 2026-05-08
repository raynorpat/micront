-- pkg/ntfs/attrs.lua -- per-attribute encoders + the static $AttrDef
-- table + identity $UpCase generator.
--
-- Attribute layout per NTFS.H:701 (ATTRIBUTE_RECORD_HEADER, all
-- quad-word aligned):
--
--   0x000  TypeCode             4 B   $STANDARD_INFORMATION (0x10), etc.
--   0x004  RecordLength         4 B   total bytes (header + content)
--   0x008  FormCode             1 B   0=resident, 1=non-resident
--   0x009  NameLength           1 B   characters (WCHARs)
--   0x00A  NameOffset           2 B   from start of attribute record
--   0x00C  Flags                2 B   ATTRIBUTE_xxx flags
--   0x00E  Instance             2 B   per-record instance number
--
-- Resident form (FormCode=0):
--   0x010  ValueLength          4 B
--   0x014  ValueOffset          2 B
--   0x016  ResidentFlags        1 B
--   0x017  Reserved             1 B
--   0x018  [name (NameLength*2)]
--   ...    [value]
--
-- Non-resident form (FormCode=1):
--   0x010  LowestVcn            8 B
--   0x018  HighestVcn           8 B
--   0x020  MappingPairsOffset   2 B
--   0x022  CompressionUnit      1 B
--   0x023  Reserved[5]          5 B
--   0x028  AllocatedLength      8 B   (only when LowestVcn==0)
--   0x030  FileSize             8 B   (only when LowestVcn==0)
--   0x038  ValidDataLength      8 B   (only when LowestVcn==0)
--   0x040  [name]
--   ...    [mapping pairs blob]

local ffi = require('ffi')
local bit = require('bit')

local M = {}

-- ----------------------------------------------------------------
-- Type codes (NTFS.H:422-439).
-- ----------------------------------------------------------------
M.TYPE_STANDARD_INFORMATION = 0x10
M.TYPE_ATTRIBUTE_LIST       = 0x20
M.TYPE_FILE_NAME            = 0x30
M.TYPE_VOLUME_VERSION       = 0x40
M.TYPE_SECURITY_DESCRIPTOR  = 0x50
M.TYPE_VOLUME_NAME          = 0x60
M.TYPE_VOLUME_INFORMATION   = 0x70
M.TYPE_DATA                 = 0x80
M.TYPE_INDEX_ROOT           = 0x90
M.TYPE_INDEX_ALLOCATION     = 0xA0
M.TYPE_BITMAP               = 0xB0
M.TYPE_SYMBOLIC_LINK        = 0xC0
M.TYPE_EA_INFORMATION       = 0xD0
M.TYPE_EA                   = 0xE0
M.TYPE_END                  = 0xFFFFFFFF

-- AttrDef flags (NTFS.H:1858-1899).
M.ATTRDEF_INDEXABLE          = 0x00000002
M.ATTRDEF_DUPLICATES_ALLOWED = 0x00000004
M.ATTRDEF_MAY_NOT_BE_NULL    = 0x00000008
M.ATTRDEF_MUST_BE_INDEXED    = 0x00000010
M.ATTRDEF_MUST_BE_NAMED      = 0x00000020
M.ATTRDEF_MUST_BE_RESIDENT   = 0x00000040
M.ATTRDEF_LOG_NONRESIDENT    = 0x00000080

-- File attribute (DOS-style) bits used by $STANDARD_INFORMATION /
-- $FILE_NAME's FileAttributes field.
M.FILE_ATTRIBUTE_READONLY   = 0x0001
M.FILE_ATTRIBUTE_HIDDEN     = 0x0002
M.FILE_ATTRIBUTE_SYSTEM     = 0x0004
M.FILE_ATTRIBUTE_DIRECTORY  = 0x0010
M.FILE_ATTRIBUTE_ARCHIVE    = 0x0020

-- NTFS-internal flag stored in the SAME FileAttributes field; set on
-- directories so NTFS's IsDirectory() macro (which checks ONLY this bit,
-- not FILE_ATTRIBUTE_DIRECTORY) recognises them.  NT 3.5 NTFS code:
--   #define IsDirectory(D) (FlagOn((D)->FileAttributes, DUP_FILE_NAME_INDEX_PRESENT))
-- Without this bit, NtfsCheckValidAttributeAccess returns
-- STATUS_NOT_A_DIRECTORY when the kernel opens a directory by name.
M.DUP_FILE_NAME_INDEX_PRESENT = 0x10000000

-- Convenience: the bits a directory's FileAttributes should carry.
M.DIRECTORY_ATTRIBUTES = bit.bor(M.FILE_ATTRIBUTE_DIRECTORY,
                                 M.DUP_FILE_NAME_INDEX_PRESENT)

-- $FILE_NAME flags (NTFS.H namespace).
M.FILE_NAME_NTFS  = 0x01
M.FILE_NAME_DOS   = 0x02
M.FILE_NAME_BOTH  = bit.bor(M.FILE_NAME_NTFS, M.FILE_NAME_DOS)

-- COLLATION_RULE (NTFS.H, near INDEX_ROOT).
M.COLLATION_BINARY    = 0
M.COLLATION_FILE_NAME = 1

-- INDEX_ENTRY flags.
M.INDEX_ENTRY_NODE    = 0x0001
M.INDEX_ENTRY_END     = 0x0002

local function quad_align(n)
    return bit.band(n + 7, bit.bnot(7))
end

-- Convert ASCII to UTF-16-LE.  NTFS uses little-endian throughout.
local function utf16le(s)
    local out = {}
    for i = 1, #s do
        out[#out + 1] = s:sub(i, i)
        out[#out + 1] = '\0'
    end
    return table.concat(out)
end

M.utf16le = utf16le

-- ----------------------------------------------------------------
-- Encode a resident attribute.  Returns the attribute record as a
-- Lua string, quad-aligned size.
--
-- opts = {
--   type_code  -- M.TYPE_*
--   name       -- optional Lua string (will be UTF-16'd); default unnamed
--   value      -- raw bytes (Lua string)
--   flags      -- attribute flags (default 0)
--   instance   -- attribute instance (default 0)
-- }
-- ----------------------------------------------------------------
function M.resident(opts)
    local name      = opts.name or ''
    local name_wstr = utf16le(name)
    local name_len  = #name             -- WCHARs (= chars for ASCII names)
    local value     = opts.value or ''
    local flags     = opts.flags or 0
    local instance  = opts.instance or 0

    -- Header is 24 B, then optional name, then value.
    local header_size = 0x18                                        -- 24 B
    local name_off    = header_size                                  -- right after header
    local value_off   = quad_align(header_size + #name_wstr)
    local total       = quad_align(value_off + #value)

    local buf = ffi.new('uint8_t[?]', total)
    ffi.cast('uint32_t*', buf + 0x00)[0] = opts.type_code
    ffi.cast('uint32_t*', buf + 0x04)[0] = total            -- RecordLength
    buf[0x08] = 0                                            -- FormCode = resident
    buf[0x09] = name_len                                     -- NameLength (WCHARs)
    ffi.cast('uint16_t*', buf + 0x0A)[0] = (name_len > 0) and name_off or 0
    ffi.cast('uint16_t*', buf + 0x0C)[0] = flags
    ffi.cast('uint16_t*', buf + 0x0E)[0] = instance
    -- Resident-form fields:
    ffi.cast('uint32_t*', buf + 0x10)[0] = #value            -- ValueLength
    ffi.cast('uint16_t*', buf + 0x14)[0] = value_off         -- ValueOffset
    buf[0x16] = 0                                            -- ResidentFlags
    buf[0x17] = 0                                            -- Reserved

    if #name_wstr > 0 then
        ffi.copy(buf + name_off, name_wstr, #name_wstr)
    end
    if #value > 0 then
        ffi.copy(buf + value_off, value, #value)
    end
    return ffi.string(buf, total)
end

-- ----------------------------------------------------------------
-- Encode a non-resident attribute with a single-extent (one mapping
-- pair) data run.  Sufficient for $MFT / $Boot / $UpCase / etc. where
-- everything lives in one contiguous range of clusters.
--
-- opts = {
--   type_code
--   name             optional
--   start_lcn        first cluster (number)
--   cluster_count    contiguous clusters
--   allocated_size   bytes (typically cluster_count * cluster_size)
--   data_size        actual file size in bytes
--   valid_data_size  initialized data length (default = data_size)
--   flags            default 0
--   instance         default 0
-- }
-- ----------------------------------------------------------------
local function encode_mapping_pairs_single(start_lcn, cluster_count)
    -- A mapping-pair is: header byte (high nibble = LCN delta byte
    -- count, low nibble = run length byte count) + length bytes (LE)
    -- + LCN delta bytes (signed LE, two's complement).  Terminated
    -- by a single 0x00 byte.
    --
    -- Compute the minimum bytes needed for cluster_count and
    -- start_lcn (signed).
    local function bytes_for_unsigned(n)
        if n == 0 then return 1 end
        local b = 0
        while n > 0 do
            b = b + 1
            n = math.floor(n / 256)
        end
        return b
    end
    local function bytes_for_signed(n)
        -- Need enough bytes to hold n in two's complement.  Add a
        -- sign byte if MSB of unsigned encoding is set.
        local u = n
        if u < 0 then u = -n - 1 end
        local b = bytes_for_unsigned(u)
        -- If high bit of the high byte is set, need an extra byte to
        -- avoid sign ambiguity.
        local high = math.floor(u / 256 ^ (b - 1))
        if high >= 0x80 then b = b + 1 end
        return b
    end

    -- ntfs-3g and the NT 3.5 driver (FsRtl/Cc/NtfsAddDataAttribute path)
    -- both decode mapping-pairs run-length as a SIGNED multi-byte LE
    -- integer.  If we encode `cluster_count = 140` in a single byte
    -- (0x8C), it reads as -116 → "negative run length" → ntfs-3g
    -- treats the file as having no data and ntfscat returns nothing.
    -- Use bytes_for_signed so values ≥ 128 spill to 2 bytes (0x8C, 0x00)
    -- and stay unambiguously positive.  Costs at most 1 extra byte
    -- per extent; correctness is non-negotiable.
    local len_bytes = bytes_for_signed(cluster_count)
    local lcn_bytes = bytes_for_signed(start_lcn)

    local out = {}
    -- Header byte.
    out[#out + 1] = string.char(bit.bor(bit.lshift(lcn_bytes, 4), len_bytes))
    -- Length (signed-positive LE — high byte's MSB stays 0).
    local n = cluster_count
    for _ = 1, len_bytes do
        out[#out + 1] = string.char(bit.band(n, 0xFF))
        n = math.floor(n / 256)
    end
    -- LCN delta (signed LE, two's-complement).
    n = start_lcn
    if n < 0 then n = n + (256 ^ lcn_bytes) end
    for _ = 1, lcn_bytes do
        out[#out + 1] = string.char(bit.band(n, 0xFF))
        n = math.floor(n / 256)
    end
    -- Terminator.
    out[#out + 1] = '\0'
    return table.concat(out)
end

M.encode_mapping_pairs_single = encode_mapping_pairs_single

function M.nonresident_single_extent(opts)
    local name      = opts.name or ''
    local name_wstr = utf16le(name)
    local name_len  = #name
    local flags     = opts.flags or 0
    local instance  = opts.instance or 0
    local pairs_blob = encode_mapping_pairs_single(opts.start_lcn,
                                                   opts.cluster_count)

    local header_size = 0x40                                         -- 64 B for non-resident with LowestVcn=0
    local name_off    = header_size
    local pairs_off   = quad_align(header_size + #name_wstr)
    local total       = quad_align(pairs_off + #pairs_blob)

    local buf = ffi.new('uint8_t[?]', total)
    ffi.cast('uint32_t*', buf + 0x00)[0] = opts.type_code
    ffi.cast('uint32_t*', buf + 0x04)[0] = total
    buf[0x08] = 1                                                   -- FormCode = non-resident
    buf[0x09] = name_len
    ffi.cast('uint16_t*', buf + 0x0A)[0] = (name_len > 0) and name_off or 0
    ffi.cast('uint16_t*', buf + 0x0C)[0] = flags
    ffi.cast('uint16_t*', buf + 0x0E)[0] = instance
    -- Non-resident-form fields:
    ffi.cast('uint64_t*', buf + 0x10)[0] = ffi.cast('uint64_t', 0)            -- LowestVcn
    ffi.cast('uint64_t*', buf + 0x18)[0] = ffi.cast('uint64_t', opts.cluster_count - 1)  -- HighestVcn
    ffi.cast('uint16_t*', buf + 0x20)[0] = pairs_off                           -- MappingPairsOffset
    buf[0x22] = 0                                                              -- CompressionUnit
    -- Reserved[5] zero
    ffi.cast('uint64_t*', buf + 0x28)[0] = ffi.cast('uint64_t', opts.allocated_size)
    ffi.cast('uint64_t*', buf + 0x30)[0] = ffi.cast('uint64_t', opts.data_size)
    ffi.cast('uint64_t*', buf + 0x38)[0] = ffi.cast('uint64_t',
                                                    opts.valid_data_size or opts.data_size)

    if #name_wstr > 0 then
        ffi.copy(buf + name_off, name_wstr, #name_wstr)
    end
    ffi.copy(buf + pairs_off, pairs_blob, #pairs_blob)
    return ffi.string(buf, total)
end

-- ----------------------------------------------------------------
-- $STANDARD_INFORMATION value.  48 bytes for NTFS 1.x.
--   0x00 CreationTime         8
--   0x08 LastModificationTime 8
--   0x10 LastChangeTime       8
--   0x18 LastAccessTime       8
--   0x20 FileAttributes       4
--   0x24 MaximumVersions      4
--   0x28 VersionNumber        4
--   0x2C ClassId              4
-- ----------------------------------------------------------------
function M.std_info_value(opts)
    local time_ft = opts.time_filetime or 0
    local file_attrs = opts.file_attributes or 0

    local buf = ffi.new('uint8_t[?]', 48)
    ffi.cast('uint64_t*', buf + 0x00)[0] = ffi.cast('uint64_t', time_ft)
    ffi.cast('uint64_t*', buf + 0x08)[0] = ffi.cast('uint64_t', time_ft)
    ffi.cast('uint64_t*', buf + 0x10)[0] = ffi.cast('uint64_t', time_ft)
    ffi.cast('uint64_t*', buf + 0x18)[0] = ffi.cast('uint64_t', time_ft)
    ffi.cast('uint32_t*', buf + 0x20)[0] = file_attrs
    -- MaximumVersions, VersionNumber, ClassId all zero.
    return ffi.string(buf, 48)
end

-- ----------------------------------------------------------------
-- $FILE_NAME value.  Variable length: 0x42 (66 B) header + name.
--   0x00 ParentDirectory      8 (FILE_REFERENCE)
--   0x08 CreationTime         8
--   0x10 LastModificationTime 8
--   0x18 LastChangeTime       8
--   0x20 LastAccessTime       8
--   0x28 AllocatedLength      8
--   0x30 FileSize             8
--   0x38 FileAttributes       4
--   0x3C ExtendedAttributes   4
--   0x40 FileNameLength       1 (in WCHARs)
--   0x41 Flags                1 (FILE_NAME_NTFS / DOS / etc.)
--   0x42 FileName             variable (UTF-16 LE)
-- ----------------------------------------------------------------
function M.file_name_value(opts)
    local name_wstr = utf16le(opts.name)
    local name_len  = #opts.name
    local time_ft   = opts.time_filetime or 0
    local total     = 0x42 + #name_wstr

    local buf = ffi.new('uint8_t[?]', total)
    ffi.cast('uint64_t*', buf + 0x00)[0] = ffi.cast('uint64_t', opts.parent_ref or 0)
    ffi.cast('uint64_t*', buf + 0x08)[0] = ffi.cast('uint64_t', time_ft)
    ffi.cast('uint64_t*', buf + 0x10)[0] = ffi.cast('uint64_t', time_ft)
    ffi.cast('uint64_t*', buf + 0x18)[0] = ffi.cast('uint64_t', time_ft)
    ffi.cast('uint64_t*', buf + 0x20)[0] = ffi.cast('uint64_t', time_ft)
    ffi.cast('uint64_t*', buf + 0x28)[0] = ffi.cast('uint64_t', opts.allocated_size or 0)
    ffi.cast('uint64_t*', buf + 0x30)[0] = ffi.cast('uint64_t', opts.file_size or 0)
    ffi.cast('uint32_t*', buf + 0x38)[0] = opts.file_attributes or 0
    ffi.cast('uint32_t*', buf + 0x3C)[0] = 0
    buf[0x40] = name_len
    buf[0x41] = opts.namespace_flags or M.FILE_NAME_BOTH
    ffi.copy(buf + 0x42, name_wstr, #name_wstr)
    return ffi.string(buf, total)
end

-- ----------------------------------------------------------------
-- $VOLUME_INFORMATION value (12 bytes).
--
-- The "sizeof = 0x004" in NTFS.H's struct comment is a misleading
-- holdover -- the actual struct has a LARGE_INTEGER Reserved at
-- offset 0 (8 bytes), making the total 12.  Both the kernel reader
-- (FSCTRL.C:1019 dereferences VolumeInformation->MajorVersion at
-- the post-Reserved offset) and the UNTFS userland struct
-- (UNTFS.HXX:702) reflect this -- the C struct definition wasn't
-- updated, but the on-disk format is 12 bytes.
--
-- Layout:
--   0x00 Reserved      8  (zero)
--   0x08 MajorVersion  1
--   0x09 MinorVersion  1
--   0x0A VolumeFlags   2
-- ----------------------------------------------------------------
function M.volume_info_value(major, minor, flags)
    local buf = ffi.new('uint8_t[?]', 12)
    -- Reserved (8 B) zero from ffi.new.
    buf[0x08] = major
    buf[0x09] = minor
    ffi.cast('uint16_t*', buf + 0x0A)[0] = flags or 0
    return ffi.string(buf, 12)
end

-- ----------------------------------------------------------------
-- INDEX_ENTRY for a $FILE_NAME-keyed index (i.e. an entry in a
-- directory listing).  Layout per NTFS.H:1639:
--
--   0x00  FileReference (8)         points at the indexed file's MFT record
--   0x08  Length (2)                total entry length, quad-aligned
--   0x0A  AttributeLength (2)       length of the indexed FILE_NAME value
--   0x0C  Flags (2)                 INDEX_ENTRY_NODE / INDEX_ENTRY_END
--   0x0E  Reserved (2)              0
--   0x10  [FILE_NAME value]         the indexed attribute (variable)
--   ...   padding to quad align
--   <end> [VCN (8)] -- only if INDEX_ENTRY_NODE; absent for leaf entries
-- ----------------------------------------------------------------
function M.index_entry_filename(file_ref_lo, file_ref_hi_seq,
                                file_name_value)
    local attr_len = #file_name_value
    local total    = quad_align(0x10 + attr_len)

    local buf = ffi.new('uint8_t[?]', total)
    -- FileReference (8 B, LE): low 6 bytes = file number, top 2 = seq.
    ffi.cast('uint64_t*', buf + 0x00)[0] =
        ffi.cast('uint64_t', file_ref_lo) +
        ffi.cast('uint64_t', file_ref_hi_seq) * 2 ^ 48
    ffi.cast('uint16_t*', buf + 0x08)[0] = total
    ffi.cast('uint16_t*', buf + 0x0A)[0] = attr_len
    ffi.cast('uint16_t*', buf + 0x0C)[0] = 0          -- not END, not NODE
    -- Reserved zero.
    ffi.copy(buf + 0x10, file_name_value, attr_len)
    return ffi.string(buf, total)
end

-- ----------------------------------------------------------------
-- $INDEX_ROOT for a $FILE_NAME-keyed index.  Caller passes the
-- already-encoded INDEX_ENTRYs (sorted per COLLATION_FILE_NAME if
-- the directory has more than one); this routine appends the END
-- terminator and wraps in INDEX_ROOT + INDEX_HEADER.
--
-- Pass entries={} for an empty directory (just the terminator).
--
-- Layout:
--   0x00  INDEX_ROOT     (16 B)
--   0x10  INDEX_HEADER   (16 B)  -- at offset 0x10 in the value
--   0x20+ INDEX_ENTRYs   (variable)
--   ...   END entry      (16 B, terminator)
-- ----------------------------------------------------------------
function M.index_root_filename(entries,
                               bytes_per_index_buffer,
                               clusters_per_index_buffer)
    -- Build the entries blob + END terminator.
    local entries_blob = table.concat(entries)
    local end_entry = ffi.new('uint8_t[?]', 16)
    ffi.cast('uint16_t*', end_entry + 0x08)[0] = 0x10        -- Length 16
    ffi.cast('uint16_t*', end_entry + 0x0A)[0] = 0           -- AttrLength
    ffi.cast('uint16_t*', end_entry + 0x0C)[0] = M.INDEX_ENTRY_END
    local end_blob = ffi.string(end_entry, 16)

    local entries_total = #entries_blob + #end_blob

    local total = 16 + 16 + entries_total     -- INDEX_ROOT + INDEX_HEADER + entries
    local buf = ffi.new('uint8_t[?]', total)

    -- INDEX_ROOT (16 B):
    ffi.cast('uint32_t*', buf + 0x00)[0] = M.TYPE_FILE_NAME
    ffi.cast('uint32_t*', buf + 0x04)[0] = M.COLLATION_FILE_NAME
    ffi.cast('uint32_t*', buf + 0x08)[0] = bytes_per_index_buffer
    buf[0x0C] = clusters_per_index_buffer
    -- Reserved[3] zero.

    -- INDEX_HEADER (16 B at offset 0x10):
    -- Offsets are relative to the start of INDEX_HEADER.
    ffi.cast('uint32_t*', buf + 0x10 + 0x00)[0] = 0x10            -- FirstIndexEntry
    ffi.cast('uint32_t*', buf + 0x10 + 0x04)[0] = 0x10 + entries_total  -- FirstFreeByte
    ffi.cast('uint32_t*', buf + 0x10 + 0x08)[0] = 0x10 + entries_total  -- BytesAvailable
    buf[0x10 + 0x0C] = 0                                          -- Flags

    -- Entries + END terminator.
    if #entries_blob > 0 then
        ffi.copy(buf + 0x20, entries_blob, #entries_blob)
    end
    ffi.copy(buf + 0x20 + #entries_blob, end_blob, #end_blob)

    return ffi.string(buf, total)
end

-- Backward-compat shim used by Phase 1 callers that built an empty
-- root directory.  New code should call index_root_filename({}, ...).
function M.empty_index_root_filename(bytes_per_index_buffer,
                                     clusters_per_index_buffer)
    return M.index_root_filename({}, bytes_per_index_buffer,
                                 clusters_per_index_buffer)
end

-- ----------------------------------------------------------------
-- Static $AttrDef table (UNTFS/SRC/ATTRDEF.CXX:48-160).
-- 14 entries × 160 bytes = 2240 bytes.
-- Each entry: Name[64 WCHARs], TypeCode (4), DisplayRule (4),
-- CollationRule (4), Flags (4), MinLen (8), MaxLen (8) = 160 B.
-- ----------------------------------------------------------------
local function attrdef_entry(name, type_code, flags, min_len, max_len)
    local buf = ffi.new('uint8_t[?]', 160)
    -- AttributeName (128 B WCHARs, zero-padded).
    local wname = utf16le(name)
    ffi.copy(buf, wname, math.min(#wname, 128))
    -- TypeCode (4 B).
    ffi.cast('uint32_t*', buf + 0x80)[0] = type_code
    -- DisplayRule (4 B) = 0.
    -- CollationRule (4 B) = 0.
    -- Flags (4 B).
    ffi.cast('uint32_t*', buf + 0x8C)[0] = flags
    -- MinimumLength (8 B).
    ffi.cast('uint64_t*', buf + 0x90)[0] = ffi.cast('uint64_t', min_len)
    -- MaximumLength (8 B).
    ffi.cast('uint64_t*', buf + 0x98)[0] = ffi.cast('uint64_t', max_len)
    return ffi.string(buf, 160)
end

-- ULONGLONG MAX (used for "any size" in attr defs).
local MAX64 = 0xFFFFFFFFFFFFFFFFULL
-- ULONG MAX, packed as a LONGLONG.  ATTRDEF.CXX uses {MAXULONG,MAXULONG}
-- for the 8-byte field, which in UNTFS represents two 32-bit halves
-- both 0xFFFFFFFF -- yielding 0xFFFFFFFFFFFFFFFF as LE u64.
function M.attrdef_table()
    local entries = {
        attrdef_entry('$STANDARD_INFORMATION', M.TYPE_STANDARD_INFORMATION,
                      M.ATTRDEF_MUST_BE_RESIDENT, 48, 48),
        attrdef_entry('$ATTRIBUTE_LIST',       M.TYPE_ATTRIBUTE_LIST,
                      M.ATTRDEF_LOG_NONRESIDENT, 0, MAX64),
        attrdef_entry('$FILE_NAME',            M.TYPE_FILE_NAME,
                      bit.bor(M.ATTRDEF_MUST_BE_RESIDENT,
                              M.ATTRDEF_INDEXABLE),
                      68, 68 + 255 * 2),
        attrdef_entry('$VOLUME_VERSION',       M.TYPE_VOLUME_VERSION,
                      M.ATTRDEF_MUST_BE_RESIDENT, 8, 8),
        attrdef_entry('$SECURITY_DESCRIPTOR',  M.TYPE_SECURITY_DESCRIPTOR,
                      M.ATTRDEF_LOG_NONRESIDENT, 0, MAX64),
        attrdef_entry('$VOLUME_NAME',          M.TYPE_VOLUME_NAME,
                      M.ATTRDEF_MUST_BE_RESIDENT, 2, 256),
        attrdef_entry('$VOLUME_INFORMATION',   M.TYPE_VOLUME_INFORMATION,
                      M.ATTRDEF_MUST_BE_RESIDENT, 12, 12),
        attrdef_entry('$DATA',                 M.TYPE_DATA,
                      0, 0, MAX64),
        attrdef_entry('$INDEX_ROOT',           M.TYPE_INDEX_ROOT,
                      M.ATTRDEF_MUST_BE_RESIDENT, 0, MAX64),
        attrdef_entry('$INDEX_ALLOCATION',     M.TYPE_INDEX_ALLOCATION,
                      M.ATTRDEF_LOG_NONRESIDENT, 0, MAX64),
        attrdef_entry('$BITMAP',               M.TYPE_BITMAP,
                      M.ATTRDEF_LOG_NONRESIDENT, 0, MAX64),
        attrdef_entry('$SYMBOLIC_LINK',        M.TYPE_SYMBOLIC_LINK,
                      M.ATTRDEF_LOG_NONRESIDENT, 0, MAX64),
        attrdef_entry('$EA_INFORMATION',       M.TYPE_EA_INFORMATION,
                      M.ATTRDEF_MUST_BE_RESIDENT, 4, 4),
        attrdef_entry('$EA',                   M.TYPE_EA,
                      0, 0, 0x10000),
    }
    return table.concat(entries)
end

-- ----------------------------------------------------------------
-- Default $UpCase table: 65,536 WCHARs.
--
-- Mostly identity (data[i] = i), with ASCII 'a'..'z' (0x61..0x7A)
-- mapped to 'A'..'Z' (0x41..0x5A).  Why the partial fold rather than
-- pure identity?  ntfs-3g enforces a minimal sanity check at mount
-- time (libntfs-3g/volume.c:1124-1133): for every codepoint in 0x20..0x7E,
-- if k is in 'a'..'z' then upcase[k] must equal k-0x20 (the uppercase
-- ASCII letter), otherwise upcase[k] must equal k.  Pure-identity
-- tables fail this and ntfs-3g rejects the volume as "Corrupted file
-- $UpCase".
--
-- ntfs.sys (NT 3.5 kernel-side) doesn't validate UpCase contents at
-- all -- it just reads the table.  So this minimal-fold table works
-- for both: ntfs.sys gets a usable case-fold for ASCII filenames,
-- ntfs-3g passes its sanity check and mounts.
--
-- Non-ASCII upper-casing (Latin-1 supplement, Greek, Cyrillic, etc.)
-- is left as identity for now.  Real NT 3.5 FORMAT calls
-- RtlUpcaseUnicodeString on the full 64K range to populate Latin/
-- Greek/Cyrillic too, but ntfs-3g doesn't verify those, and our
-- system file names are all ASCII.  Phase 2 work if needed.
--
-- Returns the table as a Lua string of exactly 131,072 bytes
-- (LE uint16 entries).
-- ----------------------------------------------------------------
function M.identity_upcase()
    local buf = ffi.new('uint16_t[?]', 65536)
    for i = 0, 65535 do
        buf[i] = i
    end
    -- ASCII 'a' (0x61) .. 'z' (0x7A) -> 'A' (0x41) .. 'Z' (0x5A).
    for i = 0x61, 0x7A do
        buf[i] = i - 0x20
    end
    return ffi.string(buf, 65536 * 2)
end

-- ----------------------------------------------------------------
-- Build a self-relative SECURITY_DESCRIPTOR with an *inheritable*
-- allow-all-to-Everyone DACL.  NT 3.5's NtfsLoadSecurityDescriptor
-- raises STATUS_FILE_CORRUPT_ERROR if a file's MFT record lacks a
-- $SECURITY_DESCRIPTOR attribute, so every file we author needs one.
--
-- Why not a NULL DACL (SE_DACL_PRESENT + Dacl=0)?  A NULL DACL itself
-- grants all access on direct check, but has no ACEs to inherit.  When
-- NtCreateFile cuts a new file, NtfsAssignSecurity → SeAssignSecurity
-- calls SepInheritAcl(parent->Dacl) — on a NULL parent DACL that
-- returns STATUS_NO_INHERITANCE, falling to the token's default DACL.
-- Our boot SYSTEM token's default DACL doesn't include World, so
-- newly-created files end up with a DACL that denies our SID.  Result:
-- write succeeds, subsequent open fails with STATUS_ACCESS_DENIED.
-- An explicit ACE with OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE
-- propagates via SepInheritAcl to every child file and directory.
--
-- Layout (72 bytes total):
--   SECURITY_DESCRIPTOR_RELATIVE (20 B):
--     0x00 Revision  (1) = 1
--     0x01 Sbz1      (1) = 0
--     0x02 Control   (2) = SE_DACL_PRESENT | SE_SELF_RELATIVE = 0x8004
--     0x04 Owner     (4) = 0x14 (Owner SID right after header)
--     0x08 Group     (4) = 0x20 (Group SID after Owner)
--     0x0C Sacl      (4) = 0
--     0x10 Dacl      (4) = 0x2C (DACL after Group)
--   Owner SID  0x14..0x1F : S-1-1-0 (World, 12 B)
--   Group SID  0x20..0x2B : S-1-1-0 (World, 12 B)
--   ACL header 0x2C..0x33 (8 B):
--     0x2C AclRevision (1) = ACL_REVISION (2)
--     0x2D Sbz1        (1) = 0
--     0x2E AclSize     (2) = 28 (header + one 20-byte ACE)
--     0x30 AceCount    (2) = 1
--     0x32 Sbz2        (2) = 0
--   ACCESS_ALLOWED_ACE 0x34..0x47 (20 B):
--     0x34 AceType  (1) = 0 (ACCESS_ALLOWED_ACE_TYPE)
--     0x35 AceFlags (1) = OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE = 0x03
--     0x36 AceSize  (2) = 20
--     0x38 Mask     (4) = FILE_ALL_ACCESS = 0x1F01FF
--                         (STANDARD_RIGHTS_ALL | SYNCHRONIZE | every
--                          FILE_* specific right.  We use the post-
--                          mapped specific mask rather than
--                          GENERIC_ALL — SeAccessCheck compares the
--                          desired access in specific bits against the
--                          ACE in specific bits, and the generic-mask
--                          translation only happens reliably for
--                          freshly-assigned DACLs, not for ones loaded
--                          off disk.)
--     0x3C World SID    : revision=1, subcount=1, IdAuth=World, SubAuth0=0
-- ----------------------------------------------------------------
function M.world_security_descriptor()
    local SIZE = 72
    local buf  = ffi.new('uint8_t[?]', SIZE)
    -- Header.
    buf[0x00] = 1
    buf[0x01] = 0
    ffi.cast('uint16_t*', buf + 0x02)[0] = 0x8004    -- DACL_PRESENT|SELF_RELATIVE
    ffi.cast('uint32_t*', buf + 0x04)[0] = 0x14      -- Owner offset
    ffi.cast('uint32_t*', buf + 0x08)[0] = 0x20      -- Group offset
    ffi.cast('uint32_t*', buf + 0x0C)[0] = 0         -- Sacl offset
    ffi.cast('uint32_t*', buf + 0x10)[0] = 0x2C      -- Dacl offset
    -- Owner SID (World, S-1-1-0).
    buf[0x14] = 1; buf[0x15] = 1
    buf[0x16] = 0; buf[0x17] = 0; buf[0x18] = 0
    buf[0x19] = 0; buf[0x1A] = 0; buf[0x1B] = 1
    ffi.cast('uint32_t*', buf + 0x1C)[0] = 0
    -- Group SID (same).
    buf[0x20] = 1; buf[0x21] = 1
    buf[0x22] = 0; buf[0x23] = 0; buf[0x24] = 0
    buf[0x25] = 0; buf[0x26] = 0; buf[0x27] = 1
    ffi.cast('uint32_t*', buf + 0x28)[0] = 0
    -- ACL header.
    buf[0x2C] = 2                                    -- AclRevision = ACL_REVISION
    buf[0x2D] = 0
    ffi.cast('uint16_t*', buf + 0x2E)[0] = 28        -- AclSize (8 + 20)
    ffi.cast('uint16_t*', buf + 0x30)[0] = 1         -- AceCount
    ffi.cast('uint16_t*', buf + 0x32)[0] = 0         -- Sbz2
    -- ACCESS_ALLOWED_ACE: GENERIC_ALL to World, inherited by files+dirs.
    buf[0x34] = 0                                    -- AceType
    buf[0x35] = 0x03                                 -- OBJECT|CONTAINER inherit
    ffi.cast('uint16_t*', buf + 0x36)[0] = 20        -- AceSize
    ffi.cast('uint32_t*', buf + 0x38)[0] = 0x001F01FF -- FILE_ALL_ACCESS
    buf[0x3C] = 1; buf[0x3D] = 1                     -- World SID revision/subcount
    buf[0x3E] = 0; buf[0x3F] = 0; buf[0x40] = 0
    buf[0x41] = 0; buf[0x42] = 0; buf[0x43] = 1
    ffi.cast('uint32_t*', buf + 0x44)[0] = 0         -- SubAuth0
    return ffi.string(buf, SIZE)
end

return M
