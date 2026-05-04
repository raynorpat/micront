-- pkg/ntfs/mft.lua -- MFT record (FILE_RECORD_SEGMENT_HEADER) + Update
-- Sequence Array (USA) encoder.
--
-- An MFT record is a 1024-byte (default) container that holds one
-- file's worth of attributes.  Layout per NTFS.H:562-657:
--
--   0x000  MULTI_SECTOR_HEADER (8 B)
--          .Signature[4]                "FILE"
--          .UpdateSequenceArrayOffset   2 B  (offset within record)
--          .UpdateSequenceArraySize     2 B  (USA entry count, not bytes)
--   0x008  Lsn                          8 B  log file sequence number
--   0x010  SequenceNumber               2 B  per-file seq, incremented on free
--   0x012  ReferenceCount               2 B  hard-link count from $FILE_NAME indices
--   0x014  FirstAttributeOffset         2 B
--   0x016  Flags                        2 B  IN_USE=1, DIRECTORY=2
--   0x018  FirstFreeByte                4 B  end of populated content
--   0x01C  BytesAvailable               4 B  record size
--   0x020  BaseFileRecordSegment        8 B  zero for base record
--   0x028  NextAttributeInstance        2 B  for $ATTRIBUTE_LIST refs
--   0x02A  UpdateArrayForCreateOnly     2*N B  USA template
--   ...    attribute records, quad-aligned
--   ...    free space (zero-filled)
--   <end>
--
-- ============================================================
-- Update Sequence Array (USA) -- the multi-sector tear protection
-- ============================================================
-- Every NTFS multi-sector struct (MFT records, INDX buffers, $LogFile
-- restart pages) protects against torn writes via a USA:
--
--   1. Record divided into N sectors (default: 1024 / 512 = 2 sectors).
--   2. USA contains (N + 1) USHORTs: USA[0] = chosen sequence number,
--      USA[1..N] = the *real* bytes that go in each sector's last 2 B.
--   3. On write: caller picks a seq number (typically increments per
--      write).  Saves each sector's last 2 bytes to USA[i+1].
--      Replaces those last 2 bytes with USA[0] (seq number).
--   4. On read: kernel verifies each sector's last 2 B == USA[0].  If
--      mismatch, the write was torn (only some sectors landed) and
--      the structure is corrupt.  Then it restores the real bytes
--      from USA[1..N] before processing.
--
-- For FORMAT-time generation we just choose seq = 1 (newly created)
-- and apply the protocol once; runtime updates increment the seq.
--
-- USA size: SEQUENCE_NUMBER_STRIDE = 512 (LFS.H:73), so:
--   usa_entries = (record_size / 512) + 1
--   usa_bytes   = usa_entries * 2
-- For 1024-byte records: 3 entries = 6 bytes.

local ffi = require('ffi')
local bit = require('bit')

local M = {}

M.SECTOR_SIZE     = 512    -- SEQUENCE_NUMBER_STRIDE in LFS.H:73
M.MFT_RECORD_SIZE = 1024

M.SIGNATURE_FILE = 'FILE'  -- magic at byte 0
M.SIGNATURE_INDX = 'INDX'  -- INDEX_ALLOCATION buffers
M.SIGNATURE_RSTR = 'RSTR'  -- $LogFile restart pages

-- FILE_xxx flags (NTFS.H:663-664).
M.FLAG_IN_USE          = 0x0001
M.FLAG_DIRECTORY       = 0x0002

-- Header layout offsets (referenced in encode below).
M.HDR_OFFSET = {
    SIGNATURE        = 0x000,   -- 4 bytes
    USA_OFFSET       = 0x004,   -- 2 bytes
    USA_SIZE         = 0x006,   -- 2 bytes (entry count)
    LSN              = 0x008,   -- 8 bytes
    SEQUENCE_NUMBER  = 0x010,   -- 2 bytes
    REFERENCE_COUNT  = 0x012,   -- 2 bytes
    FIRST_ATTR_OFF   = 0x014,   -- 2 bytes
    FLAGS            = 0x016,   -- 2 bytes
    FIRST_FREE_BYTE  = 0x018,   -- 4 bytes
    BYTES_AVAILABLE  = 0x01C,   -- 4 bytes
    BASE_FILE_REF    = 0x020,   -- 8 bytes
    NEXT_INSTANCE    = 0x028,   -- 2 bytes
    USA_ARRAY        = 0x02A,   -- variable
}

-- ----------------------------------------------------------------
-- Quad-align a byte offset / size.
-- ----------------------------------------------------------------
local function quad_align(n)
    return bit.band(n + 7, bit.bnot(7))
end

M.quad_align = quad_align

-- ----------------------------------------------------------------
-- USA dimensions for a given record size.
-- ----------------------------------------------------------------
function M.usa_entries(record_size)
    return (record_size / M.SECTOR_SIZE) + 1
end

function M.usa_bytes(record_size)
    return M.usa_entries(record_size) * 2
end

-- After USA, the first attribute starts on the next quad-word
-- boundary.
function M.first_attr_offset(record_size)
    return quad_align(M.HDR_OFFSET.USA_ARRAY + M.usa_bytes(record_size))
end

-- ----------------------------------------------------------------
-- Apply the USA protocol to an in-memory record buffer.
--
-- buf:        ffi uint8_t[?] of size record_size
-- record_size in bytes (must be multiple of 512)
-- seq:        the sequence number to imprint (USHORT, nonzero)
--
-- Walks the USA in the buffer's header, saves each sector's tail
-- bytes into the USA, and replaces them with `seq`.  Idempotent at
-- the bit level only when called once -- repeated calls would save
-- the previous seq into USA[1..N] which is wrong.
-- ----------------------------------------------------------------
function M.apply_usa(buf, record_size, seq)
    local usa_off = ffi.cast('uint16_t*', buf + M.HDR_OFFSET.USA_OFFSET)[0]
    local usa_n   = ffi.cast('uint16_t*', buf + M.HDR_OFFSET.USA_SIZE)[0]
    assert(usa_n == M.usa_entries(record_size),
           string.format('apply_usa: USA size mismatch (got %d, expected %d)',
                         usa_n, M.usa_entries(record_size)))

    -- USA[0] = sequence number.
    ffi.cast('uint16_t*', buf + usa_off)[0] = seq

    -- For each sector (1..N), save tail and replace with seq.
    for i = 0, (record_size / M.SECTOR_SIZE) - 1 do
        local tail_off = (i + 1) * M.SECTOR_SIZE - 2
        -- Save the original last 2 bytes to USA[i+1].
        local original = ffi.cast('uint16_t*', buf + tail_off)[0]
        ffi.cast('uint16_t*', buf + usa_off + 2 * (i + 1))[0] = original
        -- Replace with seq.
        ffi.cast('uint16_t*', buf + tail_off)[0] = seq
    end
end

-- ----------------------------------------------------------------
-- Construct a fresh MFT record buffer.
--
-- opts = {
--   record_size      (default M.MFT_RECORD_SIZE = 1024)
--   sequence_number  (per-file seq, default 1; for system files we
--                    typically use file_number, with file 0 = 1)
--   reference_count  (default 1)
--   in_use           (default true)
--   is_directory     (default false)
--   base_file_ref    (default 0 for base record; otherwise an 8-byte
--                    FILE_REFERENCE pointing at the base segment)
--   next_instance    (default 0)
--   usa_seq          (USA tear-protection seq, default 1)
-- }
--
-- Returns:
--   record  -- table with:
--     buf            (ffi.new uint8_t[?], record_size)
--     record_size
--     usa_seq        (used by finalize())
--     append(attr_bytes)  -- copies attribute record into record at
--                            current write offset, quad-aligned, updates
--                            FirstFreeByte
--     finalize()     -- writes the $END terminator (0xFFFFFFFF) and
--                      applies USA, returns the encoded Lua string
-- ----------------------------------------------------------------
function M.new_record(opts)
    opts = opts or {}
    local record_size     = opts.record_size or M.MFT_RECORD_SIZE
    local seq_num         = opts.sequence_number or 1
    local ref_count       = opts.reference_count or 1
    local in_use          = (opts.in_use ~= false)
    local is_directory    = opts.is_directory or false
    local base_file_ref   = opts.base_file_ref or 0
    local next_instance   = opts.next_instance or 0
    local usa_seq         = opts.usa_seq or 1

    assert(record_size % M.SECTOR_SIZE == 0,
           'record_size must be a multiple of 512')

    local flags = 0
    if in_use       then flags = bit.bor(flags, M.FLAG_IN_USE)    end
    if is_directory then flags = bit.bor(flags, M.FLAG_DIRECTORY) end

    local first_attr = M.first_attr_offset(record_size)

    local buf = ffi.new('uint8_t[?]', record_size)

    -- Signature "FILE".
    buf[0] = 0x46  -- 'F'
    buf[1] = 0x49  -- 'I'
    buf[2] = 0x4C  -- 'L'
    buf[3] = 0x45  -- 'E'

    -- USA offset + size.
    ffi.cast('uint16_t*', buf + M.HDR_OFFSET.USA_OFFSET)[0] = M.HDR_OFFSET.USA_ARRAY
    ffi.cast('uint16_t*', buf + M.HDR_OFFSET.USA_SIZE)[0]   = M.usa_entries(record_size)

    -- Lsn = 0 (no log activity for fresh records).
    -- (already zero from ffi.new)

    -- Per-file fields.
    ffi.cast('uint16_t*', buf + M.HDR_OFFSET.SEQUENCE_NUMBER)[0] = seq_num
    ffi.cast('uint16_t*', buf + M.HDR_OFFSET.REFERENCE_COUNT)[0] = ref_count
    ffi.cast('uint16_t*', buf + M.HDR_OFFSET.FIRST_ATTR_OFF)[0]  = first_attr
    ffi.cast('uint16_t*', buf + M.HDR_OFFSET.FLAGS)[0]           = flags

    -- FirstFreeByte starts pointing at the first attribute slot;
    -- updated by append() as attributes are added.  Will be advanced
    -- past the $END terminator in finalize().
    ffi.cast('uint32_t*', buf + M.HDR_OFFSET.FIRST_FREE_BYTE)[0] = first_attr
    ffi.cast('uint32_t*', buf + M.HDR_OFFSET.BYTES_AVAILABLE)[0] = record_size

    ffi.cast('uint64_t*', buf + M.HDR_OFFSET.BASE_FILE_REF)[0] =
        ffi.cast('uint64_t', base_file_ref)
    ffi.cast('uint16_t*', buf + M.HDR_OFFSET.NEXT_INSTANCE)[0]  = next_instance

    local rec = {
        buf         = buf,
        record_size = record_size,
        usa_seq     = usa_seq,
        write_off   = first_attr,
    }

    function rec:append(attr_bytes)
        local n = #attr_bytes
        assert(self.write_off + n <= self.record_size - M.usa_bytes(self.record_size) - 4,
               string.format('attribute too large for record (%d at off %d, record %d)',
                             n, self.write_off, self.record_size))
        ffi.copy(self.buf + self.write_off, attr_bytes, n)
        self.write_off = quad_align(self.write_off + n)
        ffi.cast('uint32_t*', self.buf + M.HDR_OFFSET.FIRST_FREE_BYTE)[0] = self.write_off
    end

    function rec:finalize()
        -- Write $END terminator (TypeCode 0xFFFFFFFF) at the next slot.
        ffi.cast('uint32_t*', self.buf + self.write_off)[0] = 0xFFFFFFFF
        -- $END is just a 4-byte type code; advance free pointer past it.
        ffi.cast('uint32_t*', self.buf + M.HDR_OFFSET.FIRST_FREE_BYTE)[0] =
            self.write_off + 8   -- spec: advance to next quad after $END
        -- Apply USA tear-protection.
        M.apply_usa(self.buf, self.record_size, self.usa_seq)
        return ffi.string(self.buf, self.record_size)
    end

    return rec
end

return M
