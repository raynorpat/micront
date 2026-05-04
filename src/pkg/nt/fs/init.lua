-- nt.fs — filesystem and disk-image format library.
--
-- Lua-side mirror of NT's filesystem subsystem.  Volume builders
-- (fat16, ntfs) emit partition bytes only; the drive composer
-- assembles them onto a disk image with a partition table (mbr now,
-- gpt later).  hive is a peer format library: registry-hive bytes —
-- file content, not a volume — but a binary format we know how to
-- write, so it lives alongside its filesystem peers.
--
-- Layout:
--   drive.lua   disk image composer (partitions + table format)
--   mbr.lua     MBR partition-table encoder
--   fat16.lua   FAT16 volume builder
--   ntfs/       NTFS 1.1 volume builder (subdir; multi-file)
--   hive.lua    NT 3.5 SYSTEM-hive serializer
--
-- New volumes plug in by exposing the volume interface (size_bytes,
-- mkdir, add_file, add_bytes, build) and being added to M.

local M = {}

M.hive  = require('nt.fs.hive')
M.mbr   = require('nt.fs.mbr')
M.drive = require('nt.fs.drive')
M.fat16 = require('nt.fs.fat16')
M.ntfs  = require('nt.fs.ntfs')

return M
