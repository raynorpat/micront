-- nt.fs.drive — disk image composer.
--
-- Takes a list of volume builders with placement options and stitches
-- them onto a disk image with a partition table.  Volume builders
-- emit partition bytes only; this module owns the disk-level
-- concerns (sector 0, partition table, ARC checksum, write).
--
-- Today's only supported partition table format is MBR; GPT will
-- land as a peer encoder.  Dispatch is via the `table=` arg on
-- drive.new{}.
--
-- Usage:
--     local fs = require('nt.fs')
--     local vol = fs.fat16.new{ size_mb = 511, ... }
--     vol:add_file(...)
--     local d = fs.drive.new{ table='mbr', signature=0x4E544653 }
--     d:add(vol, { active=true, gap_before_lba=2048 })
--     local stats = d:build(platform, "/path/to/esp.img")

local ffi = require('ffi')
local mbr = require('nt.fs.mbr')

local M = {}

local SECTOR_SIZE     = 512
local DEFAULT_GAP_LBA = 2048   -- 1 MB pre-partition gap (alignment)

-- ----------------------------------------------------------------
-- Drive — public API.
-- ----------------------------------------------------------------

local Drive = {}
Drive.__index = Drive

-- opts:
--   table     = 'mbr'                 (only mbr today; gpt later)
--   signature = 32-bit disk signature
function M.new(opts)
    opts = opts or {}
    local table_format = opts.table or 'mbr'
    if table_format ~= 'mbr' then
        error("nt.fs.drive: unsupported partition table '"
              .. tostring(table_format) .. "'", 2)
    end
    return setmetatable({
        table_format = table_format,
        signature    = opts.signature or 0,
        slots        = {},
    }, Drive)
end

-- Add a volume to the next free slot.  Slot opts:
--   active         = true / false  (only one should be active in MBR)
--   gap_before_lba = sectors to skip before this volume.  Default
--                    DEFAULT_GAP_LBA (2048) for slot 1 if absent;
--                    0 for subsequent slots.
--   type_code      = override the partition type byte returned by
--                    volume:build().  Useful when the same volume
--                    builder serves multiple roles (e.g. FAT16 as
--                    type 0x06 system or 0xEF UEFI ESP).
function Drive:add(volume, slot_opts)
    slot_opts = slot_opts or {}
    self.slots[#self.slots + 1] = {
        volume         = volume,
        active         = slot_opts.active and true or false,
        gap_before_lba = slot_opts.gap_before_lba,
        type_code      = slot_opts.type_code,
    }
end

-- ----------------------------------------------------------------
-- Build the disk image and write to out_path via platform.
-- ----------------------------------------------------------------

function Drive:build(platform, out_path)
    if not platform then
        error("Drive:build: pass platform module as 1st arg", 2)
    end

    -- ---- Layout pass: assign LBAs to each slot ----
    local cursor_lba = 0
    local placed = {}
    for i, slot in ipairs(self.slots) do
        local sz_bytes = slot.volume:size_bytes()
        if sz_bytes % SECTOR_SIZE ~= 0 then
            error("nt.fs.drive: slot " .. i
                  .. " size not sector-aligned: " .. sz_bytes, 2)
        end
        local sectors = sz_bytes / SECTOR_SIZE
        local gap = slot.gap_before_lba
        if gap == nil then
            gap = (i == 1) and DEFAULT_GAP_LBA or 0
        end
        cursor_lba = cursor_lba + gap
        placed[i] = {
            volume         = slot.volume,
            active         = slot.active,
            start_lba      = cursor_lba,
            sectors        = sectors,
            type_override  = slot.type_code,
        }
        cursor_lba = cursor_lba + sectors
    end

    local total_sectors = cursor_lba
    local total_bytes   = total_sectors * SECTOR_SIZE

    -- ---- Allocate the image buffer ----
    local img = ffi.new('uint8_t[?]', total_bytes)

    -- ---- Render each volume into its slot ----
    for _, p in ipairs(placed) do
        local out = p.volume:build(platform, {
            start_lba   = p.start_lba,
            sector_size = SECTOR_SIZE,
        })
        if #out.bytes ~= p.sectors * SECTOR_SIZE then
            error("nt.fs.drive: volume bytes ("
                  .. #out.bytes .. ") != slot size ("
                  .. (p.sectors * SECTOR_SIZE) .. ")", 2)
        end
        ffi.copy(img + p.start_lba * SECTOR_SIZE, out.bytes, #out.bytes)
        p.type_code = p.type_override or out.type_code
        p.label     = out.label
        p.stats     = out.stats
    end

    -- ---- Encode + write the partition table at sector 0 ----
    local table_partitions = {}
    for i, p in ipairs(placed) do
        table_partitions[i] = {
            active    = p.active,
            type_code = p.type_code,
            start_lba = p.start_lba,
            sectors   = p.sectors,
        }
    end
    local table_bytes = mbr.encode{
        signature  = self.signature,
        partitions = table_partitions,
    }
    ffi.copy(img, table_bytes, #table_bytes)

    -- ---- ARC checksum (MBR-only): sum of 128 DWORDs of sector 0,
    -- ---- two's-complement so (stored + sum) ≡ 0 mod 2^32.
    local mbr_sum = ffi.cast('uint32_t', 0)
    for i = 0, 127 do
        mbr_sum = mbr_sum + ffi.cast('uint32_t*', img + i * 4)[0]
    end
    local arc_checksum = tonumber(ffi.cast('uint32_t', -mbr_sum))

    -- ---- Write ----
    platform.write_file(out_path, ffi.string(img, total_bytes))

    local result_partitions = {}
    for i, p in ipairs(placed) do
        result_partitions[i] = {
            lba       = p.start_lba,
            sectors   = p.sectors,
            type_code = p.type_code,
            label     = p.label,
            stats     = p.stats,
        }
    end
    return {
        size_mb      = math.floor(total_bytes / (1024 * 1024)),
        signature    = self.signature,
        mbr_checksum = arc_checksum,
        partitions   = result_partitions,
    }
end

M.SECTOR_SIZE     = SECTOR_SIZE
M.DEFAULT_GAP_LBA = DEFAULT_GAP_LBA

return M
