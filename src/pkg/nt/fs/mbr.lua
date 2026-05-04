-- nt.fs.mbr — MBR partition-table encoder.
--
-- Pure encoder — no I/O, no global state.  Call encode(layout) and
-- get a 512-byte string back for sector 0 of the disk image.  The
-- composer (nt.fs.drive) calls this and stitches it into the wider
-- image; volume builders never see the MBR.
--
-- Layout shape:
--   {
--     signature  = 0x4E544653,        -- 32-bit disk signature at 0x1B8
--     partitions = {                  -- up to 4 entries, in slot order
--       { active=true, type_code=0x06, start_lba=2048, sectors=N }, ...
--     }
--   }
--
-- CHS bytes are left zero — LBA-only path (matches the previous
-- inline encoders in ntosbe/disk.lua and pkg/ntfs/init.lua).

local ffi = require('ffi')

local M = {}

local SECTOR_SIZE     = 512
local MAX_PARTITIONS  = 4

function M.encode(layout)
    local parts = layout.partitions or {}
    if #parts > MAX_PARTITIONS then
        error("MBR holds at most 4 partitions", 2)
    end
    local sec = ffi.new('uint8_t[?]', SECTOR_SIZE)
    -- Disk signature at 0x1B8 (LE u32).
    ffi.cast('uint32_t*', sec + 0x1B8)[0] = layout.signature or 0
    -- Up to 4 partition entries, 16 bytes each, starting at 0x1BE.
    for i, p in ipairs(parts) do
        local off = 0x1BE + (i - 1) * 16
        sec[off + 0] = p.active and 0x80 or 0x00
        sec[off + 4] = p.type_code or 0
        ffi.cast('uint32_t*', sec + off + 8)[0]  = p.start_lba or 0
        ffi.cast('uint32_t*', sec + off + 12)[0] = p.sectors or 0
    end
    -- Boot signature 0x55AA at 0x1FE.
    sec[0x1FE] = 0x55
    sec[0x1FF] = 0xAA
    return ffi.string(sec, SECTOR_SIZE)
end

M.SECTOR_SIZE    = SECTOR_SIZE
M.MAX_PARTITIONS = MAX_PARTITIONS

return M
