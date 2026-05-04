-- pkg/ntfs/boot.lua -- NTFS boot sector encoder.
--
-- Reference: NT 3.5 source -- NTFS.H's PACKED_BOOT_SECTOR (the on-disk
-- struct ntfs.sys reads at mount time) and UNTFS.HXX's NtfsBootCode
-- blob (the legacy-BIOS bootstrap).
--
-- We don't ship the bootstrap code -- it's only relevant for legacy
-- BIOS boot, and our system volume is mounted post-UEFI-handoff via
-- ntfs.sys.  The bootstrap area is zero-filled; only the struct
-- fields that ntfs.sys validates need real values.
--
-- Layout from NTFS.H:537 (sizeof = 0x200, single sector):
--   0x000  Jump[3]                                   3 B
--   0x003  Oem[8]                                    8 B  "NTFS    "
--   0x00B  PackedBpb (PACKED_BIOS_PARAMETER_BLOCK)  25 B
--   0x024  Unused[4]                                 4 B
--   0x028  NumberSectors                             8 B  total partition sectors
--   0x030  MftStartLcn                               8 B  cluster of $MFT start
--   0x038  Mft2StartLcn                              8 B  cluster of $MFTMirr
--   0x040  ClustersPerFileRecordSegment              4 B  see encoding note
--   0x044  DefaultClustersPerIndexAllocationBuffer   4 B  see encoding note
--   0x048  SerialNumber                              8 B  volume serial
--   0x050  Checksum                                  4 B  XOR of bytes 0..0x4F
--   0x054  BootStrap[428]                          428 B  bootstrap code (0)
--   0x1FE  signature                                 2 B  0x55, 0xAA
--
-- ClustersPerFileRecordSegment encoding (NTFS clever-int):
--   if positive: literal cluster count per FRS
--   if negative: -log2(bytes per FRS) -- so MFT records can be smaller
--                than a cluster on volumes with large clusters
-- The standard MFT record size is 1024 bytes.  On a 4 KB cluster
-- volume, ClustersPerFRS=1 wouldn't work (cluster=4 KB > MFT=1 KB),
-- so we encode -10 (meaning 2^10 = 1024 bytes per FRS).
--
-- Same encoding for ClustersPerIndexAllocationBuffer (default
-- index buffer is 4 KB).

local ffi = require('ffi')
local bit = require('bit')

local M = {}

M.SECTOR_SIZE        = 512
M.MFT_RECORD_SIZE    = 1024
M.INDEX_BUFFER_SIZE  = 4096
M.BYTES_IN_BOOT_AREA = 0x2000   -- 8 KB; matches UNTFS.HXX:84

-- Encode a "clever int" used by ClustersPer{FRS,IndexBuffer}: positive
-- = clusters, negative = -log2(bytes).  Returns a signed int32 to be
-- written little-endian.
local function encode_cluster_or_log2(cluster_size_bytes, target_size_bytes)
    if target_size_bytes >= cluster_size_bytes then
        -- Fits cleanly in N clusters.
        return target_size_bytes / cluster_size_bytes
    else
        -- Smaller than a cluster: encode as negative log2.
        local log2 = 0
        local v = target_size_bytes
        while v > 1 do
            v = bit.rshift(v, 1)
            log2 = log2 + 1
        end
        return -log2     -- e.g. 1024 → -10
    end
end

-- Encode a single PACKED_BOOT_SECTOR (512 bytes).  All multi-byte
-- fields little-endian.  Returns the buffer as a Lua string.
function M.encode(opts)
    local sector_size      = opts.sector_size      or 512
    local sectors_per_clus = opts.sectors_per_clus or 8     -- 4 KB cluster
    local total_sectors    = opts.total_sectors    -- required (LONGLONG)
    local mft_lcn          = opts.mft_lcn          -- required (LONGLONG)
    local mft_mirr_lcn     = opts.mft_mirr_lcn     -- required (LONGLONG)
    local serial_number    = opts.serial_number    or 0     -- LONGLONG
    local sectors_per_trk  = opts.sectors_per_trk  or 63
    local heads            = opts.heads            or 255
    local hidden_sectors   = opts.hidden_sectors   or 0     -- partition LBA on disk
    local media            = opts.media            or 0xF8

    assert(total_sectors,  'boot.encode: total_sectors required')
    assert(mft_lcn,        'boot.encode: mft_lcn required')
    assert(mft_mirr_lcn,   'boot.encode: mft_mirr_lcn required')

    local buf = ffi.new('uint8_t[?]', 512)

    -- 0x000  Jump[3] - "JMP rel; NOP" pattern; bytes are arbitrary
    --        without bootstrap code, but keeping the standard form.
    buf[0] = 0xEB
    buf[1] = 0x52   -- skip past BPB
    buf[2] = 0x90   -- NOP

    -- 0x003  Oem[8] = "NTFS    " (4 spaces).  ntfs.sys checks this on
    --        every mount probe -- the heart of our recognizer.
    local oem = "NTFS    "
    for i = 0, 7 do buf[3 + i] = oem:byte(i + 1) end

    -- 0x00B  PACKED_BIOS_PARAMETER_BLOCK (25 bytes).  Most NTFS-
    --        relevant fields are just BytesPerSector + SectorsPerCluster
    --        + Media + a few geometry hints.  All FAT-specific fields
    --        (RootEntries, SectorsPerFat, etc.) are zero.
    --
    --        offset (within BPB) field:
    --          0  BytesPerSector[2]      (LE u16)
    --          2  SectorsPerCluster[1]   (u8)
    --          3  ReservedSectors[2]     (zero)
    --          5  Fats[1]                (zero)
    --          6  RootEntries[2]         (zero)
    --          8  Sectors[2]             (zero -- 16-bit sector count, NTFS uses 64-bit later)
    --         10  Media[1]
    --         11  SectorsPerFat[2]       (zero)
    --         13  SectorsPerTrack[2]
    --         15  Heads[2]
    --         17  HiddenSectors[4]
    --         21  LargeSectors[4]        (zero -- NTFS uses NumberSectors at 0x028)
    --
    local bpb = 0x0B
    -- BytesPerSector (LE u16)
    buf[bpb + 0] = bit.band(sector_size, 0xFF)
    buf[bpb + 1] = bit.band(bit.rshift(sector_size, 8), 0xFF)
    -- SectorsPerCluster
    buf[bpb + 2] = sectors_per_clus
    -- Media descriptor at offset 10 (0xF8 = fixed disk)
    buf[bpb + 10] = media
    -- SectorsPerTrack at offset 13
    buf[bpb + 13] = bit.band(sectors_per_trk, 0xFF)
    buf[bpb + 14] = bit.band(bit.rshift(sectors_per_trk, 8), 0xFF)
    -- Heads at offset 15
    buf[bpb + 15] = bit.band(heads, 0xFF)
    buf[bpb + 16] = bit.band(bit.rshift(heads, 8), 0xFF)
    -- HiddenSectors at offset 17 (4 bytes LE)
    for i = 0, 3 do
        buf[bpb + 17 + i] = bit.band(bit.rshift(hidden_sectors, 8 * i), 0xFF)
    end
    -- LargeSectors at offset 21 stays zero.

    -- 0x024  Unused[4] -- already zero from ffi.new.

    -- 0x028  NumberSectors (LONGLONG, 8 bytes LE).
    ffi.cast('uint64_t*', buf + 0x28)[0] = ffi.cast('uint64_t', total_sectors)

    -- 0x030  MftStartLcn (LONGLONG, 8 bytes LE).
    ffi.cast('uint64_t*', buf + 0x30)[0] = ffi.cast('uint64_t', mft_lcn)

    -- 0x038  Mft2StartLcn (LONGLONG, 8 bytes LE).
    ffi.cast('uint64_t*', buf + 0x38)[0] = ffi.cast('uint64_t', mft_mirr_lcn)

    -- 0x040  ClustersPerFileRecordSegment (signed int32 LE).
    --        Standard MFT record = 1024 bytes.  Encode as clever-int
    --        relative to cluster size.
    local cluster_size = sector_size * sectors_per_clus
    local cpfrs = encode_cluster_or_log2(cluster_size, M.MFT_RECORD_SIZE)
    ffi.cast('int32_t*', buf + 0x40)[0] = cpfrs

    -- 0x044  DefaultClustersPerIndexAllocationBuffer (signed int32 LE).
    --        Standard index buffer = 4096 bytes.
    local cpiab = encode_cluster_or_log2(cluster_size, M.INDEX_BUFFER_SIZE)
    ffi.cast('int32_t*', buf + 0x44)[0] = cpiab

    -- 0x048  SerialNumber (LONGLONG, 8 bytes LE).
    ffi.cast('uint64_t*', buf + 0x48)[0] = ffi.cast('uint64_t', serial_number)

    -- 0x054..0x1FD  BootStrap[428] -- zero-filled (UEFI boot, no
    --                                legacy BIOS bootstrap needed).

    -- 0x1FE  Boot signature 0xAA55.
    buf[0x1FE] = 0x55
    buf[0x1FF] = 0xAA

    -- 0x050  Checksum (4 bytes LE).  XOR of every DWORD from 0x000
    --        through 0x04F (inclusive of NumberSectors, MftStartLcn,
    --        etc., but NOT including the checksum itself or the
    --        bootstrap area).  ntfs.sys's NtfsIsBootSectorNtfs
    --        comments mention the check is currently disabled, but we
    --        write the correct value anyway for completeness.
    local checksum = 0
    for i = 0, 0x4C, 4 do
        local v = ffi.cast('uint32_t*', buf + i)[0]
        checksum = bit.bxor(checksum, tonumber(v))
    end
    ffi.cast('uint32_t*', buf + 0x50)[0] = checksum

    return ffi.string(buf, 512)
end

return M
