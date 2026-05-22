-- ntosbe.zip — minimal STORED-only ZIP writer (host-side, pure Lua).
--
-- Used at disk-compose time to pack a Lua package tree into a single
-- `name.zip` that the on-target package loader reads back (see the
-- zip searcher in src/cr/preamble.lua).  STORED (no compression) only:
-- the Lua sources are small and the disk image compresses at its own
-- layer, so an inflate implementation buys nothing.  The archives are
-- still valid PKZIP — `unzip -t` validates them — because we write a
-- real CRC-32 per member.
--
-- LuaJIT is Lua 5.1 ABI: no string.pack, so byte packing is done by
-- hand (little-endian, the ZIP byte order).
--
-- API:
--   zip.crc32(s)            -> number          CRC-32/ISO-HDLC of a string
--   zip.build(entries)      -> string          the .zip file bytes
--   zip.write(path, entries)                   build + write to a host file
-- where entries = { { name = "nt/dll/cm.lua", data = "<bytes>" }, ... }.
-- `name` uses forward slashes (ZIP convention); the loader maps module
-- a.b.c to member a/b/c.lua.

local bit = require('bit')

local M = {}

-- ------------------------------------------------------------------
-- CRC-32 (polynomial 0xEDB88320, the reflected ZIP/zlib variant).
-- Table built once at module load.
-- ------------------------------------------------------------------
local crc_table = {}
do
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if bit.band(c, 1) ~= 0 then
                c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
            else
                c = bit.rshift(c, 1)
            end
        end
        crc_table[i] = c
    end
end

function M.crc32(s)
    local crc = 0xFFFFFFFF
    for i = 1, #s do
        local byte = string.byte(s, i)
        crc = bit.bxor(bit.rshift(crc, 8),
                       crc_table[bit.band(bit.bxor(crc, byte), 0xFF)])
    end
    -- bit.bxor with 0xFFFFFFFF yields a signed int32 in LuaJIT; coerce
    -- to an unsigned 0..2^32-1 number for the byte-packers below.
    crc = bit.bxor(crc, 0xFFFFFFFF)
    return crc % 0x100000000
end

-- ------------------------------------------------------------------
-- Little-endian byte packers.
-- ------------------------------------------------------------------
local function le16(n)
    n = n % 0x10000
    return string.char(n % 256, math.floor(n / 256) % 256)
end

local function le32(n)
    n = n % 0x100000000
    return string.char(n % 256,
                       math.floor(n / 256)     % 256,
                       math.floor(n / 65536)   % 256,
                       math.floor(n / 16777216) % 256)
end

-- DOS date/time stamp — fixed at 1980-01-01 00:00:00 for reproducible
-- archives.  DOS date = (year-1980)<<9 | month<<5 | day = 0|1<<5|1.
local DOS_TIME = 0x0000
local DOS_DATE = 0x0021

-- ------------------------------------------------------------------
-- Archive assembly.
-- ------------------------------------------------------------------
function M.build(entries)
    local locals  = {}   -- local header + data, in order
    local central = {}    -- central directory records
    local offset  = 0     -- running offset of the next local header

    for _, e in ipairs(entries) do
        local name = e.name
        local data = e.data or ""
        local crc  = M.crc32(data)
        local n    = #data

        -- Local file header (signature 0x04034b50).
        local lh = table.concat {
            le32(0x04034b50),
            le16(20),           -- version needed to extract (2.0)
            le16(0),            -- general-purpose bit flag
            le16(0),            -- compression method: 0 = STORED
            le16(DOS_TIME),
            le16(DOS_DATE),
            le32(crc),
            le32(n),            -- compressed size  (== uncompressed for STORED)
            le32(n),            -- uncompressed size
            le16(#name),        -- file name length
            le16(0),            -- extra field length
            name,
            data,
        }
        locals[#locals + 1] = lh

        -- Central directory file header (signature 0x02014b50).
        central[#central + 1] = table.concat {
            le32(0x02014b50),
            le16(20),           -- version made by
            le16(20),           -- version needed to extract
            le16(0),            -- gp bit flag
            le16(0),            -- compression method
            le16(DOS_TIME),
            le16(DOS_DATE),
            le32(crc),
            le32(n),
            le32(n),
            le16(#name),        -- file name length
            le16(0),            -- extra field length
            le16(0),            -- file comment length
            le16(0),            -- disk number start
            le16(0),            -- internal file attributes
            le32(0),            -- external file attributes
            le32(offset),       -- relative offset of local header
            name,
        }

        offset = offset + #lh
    end

    local local_blob   = table.concat(locals)
    local central_blob = table.concat(central)

    -- End of central directory record (signature 0x06054b50).
    local eocd = table.concat {
        le32(0x06054b50),
        le16(0),                -- number of this disk
        le16(0),                -- disk with central directory
        le16(#entries),         -- entries on this disk
        le16(#entries),         -- total entries
        le32(#central_blob),    -- size of central directory
        le32(#local_blob),      -- offset of central directory
        le16(0),                -- comment length
    }

    return local_blob .. central_blob .. eocd
end

function M.write(path, entries)
    local f = assert(io.open(path, "wb"))
    f:write(M.build(entries))
    f:close()
end

return M
